// wake_orchestrator.dart — runs Natural Wake and Gradual Wake for one wake
// occurrence, and keeps the native band alarm at T armed throughout.
//
// One call, [WakeOrchestrator.tick], is the whole contract. The caller (the
// 30 s keep-alive tick in AppState, or a headless wake source through
// [WakeOrchestrator.tickThroughGate]) hands it the plan for the armed alarm
// and it:
//   1. verifies the fixed native alarm at T is armed, re-arming it if the
//      phone lost track (reboot, restart). This happens in EVERY
//      configuration, including "neither".
//   2. Natural: feeds the causal stager (off the UI isolate) and, once the
//      sleep so far (when known) is at least 45 min, fires an early haptic (then repeats it, see below) when the sleeper is NOT in light or
//      deep sleep (estimated REM or awake, held `runSec >= 120`) inside
//      [T-N, T), or when the user is actively using the app and the band moved
//      with it — otherwise records why it abstained.
//   3. Gradual: sends the next due step of its own cadence from T-G. It never
//      reads the stager and is not borrowed from Natural's window.
//   4. persists its run state (so an app death, restart or reboot resumes
//      instead of re-firing) and appends decision-trace rows.
//
// SAFETY, stated once. Nothing in this file disarms, moves or shortens the
// native alarm at T. The ONLY call that can cancel it is [acknowledge] with
// `cancelNative: true`, which is an explicit user acknowledgement. If that
// cancel fails, throws or hangs, the fallback is verified and re-armed. An
// early haptic, a failed haptic, a skipped tick and an abstention all leave T
// exactly as it was.
//
// Natural repeats. Once Natural has fired, its plan is replayed back to back
// (see [WakeOrchestrator._naturalRepeat]) until the wearer acknowledges, double
// taps the band, T is reached, or the orchestrator is disposed. The loop is
// detached from the tick and holds no lock; it only writes early haptics and
// trace rows, so it can never touch the native alarm at T.
//
// Latches. `_ticking` coalesces overlapping ticks and is cleared in `finally`;
// `_repeating` (one entry per wake occurrence) is cleared in the loop's
// `finally`.
// Every call into the environment (samples, observer, haptic, band alarm) is
// bounded by [opTimeout]; a timeout is recorded and the tick moves on.

import 'dart:async';
import 'dart:convert';

import '../notify/buzz_sequence.dart';
import '../state/control_operations.dart' show ExpectedSleepSchedule;
import '../sync/headless_gate.dart';
import 'natural_wake.dart';
import 'wake_settings.dart';

/// [HeadlessSyncGate] owner for background wake ticks.
const String kWakeGateOwner = 'wake_tick';

/// A tick later than this after the previous one means the app was suspended
/// or disconnected in between; recorded so the trace can say so.
const Duration kWakeTickGap = Duration(minutes: 5);

/// Ticks outside [earliest timeline part - this, T + [kWakeClosingGrace]] do
/// nothing and touch no store: the keep-alive calls every 30 s all night.
const Duration kWakeActiveMargin = Duration(minutes: 10);

/// How long after T a tick may still write the closing summary.
const Duration kWakeClosingGrace = Duration(minutes: 2);

/// A Gradual step the OS ran later than this after its due time is skipped,
/// not played late (a stale buzz is worse than a missed one; T still fires).
const Duration kGradualStepGrace = Duration(seconds: 90);

// ── environment seams ───────────────────────────────────────────────────────

/// Samples as plain columns, absolute epoch ms:
///   hr [tsMs, bpm]  accel [tsMs, x, y, z]  rr [tsMs, rrMs]
class WakeSamples {
  const WakeSamples({required this.hr, required this.accel, required this.rr});
  const WakeSamples.empty()
      : hr = const [],
        accel = const [],
        rr = const [];
  final List<List<double>> hr;
  final List<List<double>> accel;
  final List<List<double>> rr;
}

class FallbackStatus {
  const FallbackStatus({required this.armedForWake, required this.confirmed});

  /// The band holds an alarm for exactly this wake time.
  final bool armedForWake;

  /// The band confirmed the arm (event 56).
  final bool confirmed;
}

enum WakeHapticKind { natural, gradual }

class WakeHapticRequest {
  const WakeHapticRequest({
    required this.kind,
    required this.eventId,
    required this.wakeAt,
    required this.sourceTime,
    this.stepIndex,
    this.sequence,
    this.gradualPattern,
    this.repeat = false,
  });
  final WakeHapticKind kind;

  /// A replay of the Natural plan after the first delivery. Band only: the
  /// phone was told once, by the first one.
  final bool repeat;

  /// Stable per occurrence (and per step), so the dispatcher's durable ledger
  /// refuses a duplicate after a restart.
  final String eventId;
  final DateTime wakeAt;
  final DateTime sourceTime;
  final int? stepIndex;
  final BuzzSequence? sequence;

  /// The gradual pattern the step belongs to (null for Natural).
  final GradualPattern? gradualPattern;
}

class WakeHapticResult {
  const WakeHapticResult({
    this.delivered = const [],
    this.suppressionReason,
    this.error,
  });
  final List<String> delivered;
  final String? suppressionReason;
  final String? error;
  bool get ok => delivered.isNotEmpty;
}

abstract interface class WakeEnv {
  /// Live phone-to-band link.
  bool get connected;

  /// Instants of a touch in the FOREGROUND app, oldest first. Empty when the
  /// app was not in use (backgrounded, locked): then only the stager decides.
  List<DateTime> get recentInteractions;

  /// When the band last reported HAPTICS_TERMINATED with cause
  /// `user_double_tap` (the wearer dismissing a running buzz), on the phone's
  /// clock; null when it never has this session. Natural's repeat stops on one
  /// that is not older than the repeat's own start.
  DateTime? get lastBandDoubleTapAt;

  /// Samples in [from, to), oldest first. May be empty.
  Future<WakeSamples> samples(DateTime from, DateTime to);

  Future<FallbackStatus> fallbackStatus(DateTime wakeAt);

  /// Arm (or re-arm) the native alarm at exactly [wakeAt] and report the
  /// result. Never arms any other time.
  Future<FallbackStatus> ensureFallbackArmed(DateTime wakeAt);

  /// Cancel the native alarm for [wakeAt]. Reached only from [acknowledge].
  Future<bool> cancelNativeAlarm(DateTime wakeAt);

  /// One live-only haptic through the AlertDispatcher.
  Future<WakeHapticResult> haptic(WakeHapticRequest request);
}

/// A [WakeEnv] assembled from callbacks, for AppState (which owns the BLE
/// engine, the alarm bookkeeping and the dispatcher this must reach).
class CallbackWakeEnv implements WakeEnv {
  CallbackWakeEnv({
    required bool Function() isConnected,
    required this.loadSamples,
    required this.status,
    required this.arm,
    required this.cancel,
    required this.sendHaptic,
    List<DateTime> Function()? interactions,
    DateTime? Function()? doubleTapAt,
  })  : _isConnected = isConnected,
        _interactions = interactions ?? (() => const []),
        _doubleTapAt = doubleTapAt ?? (() => null);

  final bool Function() _isConnected;
  final List<DateTime> Function() _interactions;
  final DateTime? Function() _doubleTapAt;
  final Future<WakeSamples> Function(DateTime from, DateTime to) loadSamples;
  final Future<FallbackStatus> Function(DateTime wakeAt) status;
  final Future<FallbackStatus> Function(DateTime wakeAt) arm;
  final Future<bool> Function(DateTime wakeAt) cancel;
  final Future<WakeHapticResult> Function(WakeHapticRequest r) sendHaptic;

  @override
  bool get connected => _isConnected();
  @override
  List<DateTime> get recentInteractions => _interactions();
  @override
  DateTime? get lastBandDoubleTapAt => _doubleTapAt();
  @override
  Future<WakeSamples> samples(DateTime from, DateTime to) => loadSamples(from, to);
  @override
  Future<FallbackStatus> fallbackStatus(DateTime wakeAt) => status(wakeAt);
  @override
  Future<FallbackStatus> ensureFallbackArmed(DateTime wakeAt) => arm(wakeAt);
  @override
  Future<bool> cancelNativeAlarm(DateTime wakeAt) => cancel(wakeAt);
  @override
  Future<WakeHapticResult> haptic(WakeHapticRequest r) => sendHaptic(r);
}

// ── plan / outcomes ─────────────────────────────────────────────────────────

class WakePlanInput {
  const WakePlanInput({
    required this.wakeAt,
    required this.naturalMinutes,
    required this.gradualMinutes,
    required this.gradualPattern,
    required this.gradualCadenceSec,
    this.expectedSchedule,
    this.sleepOnset,
    this.upgradePending = false,
  });

  /// T, the armed native alarm instant.
  final DateTime wakeAt;
  final int naturalMinutes;
  final int gradualMinutes;
  final GradualPattern gradualPattern;
  final int gradualCadenceSec;

  /// The saved expected sleep, one source of the sleep's onset.
  final ExpectedSleepSchedule? expectedSchedule;

  /// The night's detected sleep onset (see `sleep_onset.dart`), the other
  /// source. Only loaded when no schedule is saved.
  final DateTime? sleepOnset;

  /// The Smart Wake -> Natural Wake explanation has not been acknowledged:
  /// Natural stays inactive.
  final bool upgradePending;

  /// The same plan with the night's detected sleep onset.
  WakePlanInput withSleepOnset(DateTime? onset) => WakePlanInput(
        wakeAt: wakeAt,
        naturalMinutes: naturalMinutes,
        gradualMinutes: gradualMinutes,
        gradualPattern: gradualPattern,
        gradualCadenceSec: gradualCadenceSec,
        expectedSchedule: expectedSchedule,
        sleepOnset: onset,
        upgradePending: upgradePending,
      );

  int get wakeSec => wakeAt.millisecondsSinceEpoch ~/ 1000;
  WakeConfiguration get configuration => wakeConfigurationOf(
      naturalMinutes: naturalMinutes, gradualMinutes: gradualMinutes);
}

class WakeTickOutcome {
  const WakeTickOutcome({
    this.natural,
    this.naturalFired = false,
    this.gradualStepFired,
    this.coalesced = false,
    this.closed = false,
  });
  final NaturalReason? natural;
  final bool naturalFired;
  final int? gradualStepFired;

  /// Another tick was already running; this one did nothing.
  final bool coalesced;

  /// T has passed; the native alarm owns the wake now.
  final bool closed;
}

class WakeAckOutcome {
  const WakeAckOutcome({
    required this.nativeCancelRequested,
    required this.nativeCancelled,
    required this.fallbackArmed,
  });
  final bool nativeCancelRequested;
  final bool nativeCancelled;

  /// The native alarm at T is armed after this acknowledgement.
  final bool fallbackArmed;
}

// ── trace / state stores ────────────────────────────────────────────────────

/// One decision-trace row for a wake occurrence.
///
/// kinds: plan, fallback, natural, natural_haptic, natural_repeat (phase
/// start | result | stop, with the stop reason), gradual, gap, ack, skip,
/// error, closed.
class WakeTraceEntry {
  const WakeTraceEntry({
    required this.wakeEpochSec,
    required this.atMs,
    required this.kind,
    required this.data,
  });
  final int wakeEpochSec;
  final int atMs;
  final String kind;
  final Map<String, Object?> data;
}

abstract interface class WakeTraceStore {
  Future<void> append(WakeTraceEntry entry);
  Future<List<WakeTraceEntry>> forWake(int wakeEpochSec);
}

abstract interface class WakeStateStore {
  Future<Map<String, Object?>?> load();
  Future<void> save(Map<String, Object?> state);
}

/// Test doubles; production uses the DB-backed stores in wake_stores.dart.
class MemoryWakeStateStore implements WakeStateStore {
  Map<String, Object?>? value;
  @override
  Future<Map<String, Object?>?> load() async => value == null
      ? null
      : (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();
  @override
  Future<void> save(Map<String, Object?> state) async =>
      // A JSON round trip, as the real store does: unserialisable state fails
      // here, not on a user's phone.
      value = (jsonDecode(jsonEncode(state)) as Map).cast<String, Object?>();
}

class MemoryWakeTraceStore implements WakeTraceStore {
  final List<WakeTraceEntry> all = [];
  @override
  Future<void> append(WakeTraceEntry entry) async => all.add(WakeTraceEntry(
        wakeEpochSec: entry.wakeEpochSec,
        atMs: entry.atMs,
        kind: entry.kind,
        data: (jsonDecode(jsonEncode(entry.data)) as Map).cast<String, Object?>(),
      ));
  @override
  Future<List<WakeTraceEntry>> forWake(int wakeEpochSec) async =>
      [for (final e in all) if (e.wakeEpochSec == wakeEpochSec) e];
}

// ── persisted run state ─────────────────────────────────────────────────────

class _Run {
  _Run(this.wakeEpoch);
  final int wakeEpoch;
  Map<String, Object?>? stager;
  double? lastFedMs;
  bool naturalFired = false;
  int gradualNext = 0;
  int gradualFired = 0;
  bool acknowledged = false;
  bool closed = false;
  bool planLogged = false;
  int? lastTickMs;
  String? naturalSig;
  String? fallbackSig;

  /// Anything unreadable falls back to the default: the worst a corrupt state
  /// can do is cost a warm-up, never crash a wake.
  factory _Run.from(Map<String, Object?>? j, int wakeEpoch) {
    final r = _Run(wakeEpoch);
    if (j == null || j['wakeEpoch'] != wakeEpoch) return r;
    final stager = j['stager'];
    r.stager = stager is Map ? stager.cast<String, Object?>() : null;
    final fed = j['lastFedMs'];
    r.lastFedMs = fed is num && fed.isFinite ? fed.toDouble() : null;
    r.naturalFired = j['naturalFired'] == true;
    final next = j['gradualNext'];
    r.gradualNext = next is int && next >= 0 ? next : 0;
    final fired = j['gradualFired'];
    r.gradualFired = fired is int && fired >= 0 ? fired : 0;
    r.acknowledged = j['acknowledged'] == true;
    r.closed = j['closed'] == true;
    r.planLogged = j['planLogged'] == true;
    final tick = j['lastTickMs'];
    r.lastTickMs = tick is int ? tick : null;
    r.naturalSig = j['naturalSig'] as String?;
    r.fallbackSig = j['fallbackSig'] as String?;
    return r;
  }

  Map<String, Object?> toJson() => {
        'wakeEpoch': wakeEpoch,
        'stager': stager,
        'lastFedMs': lastFedMs,
        'naturalFired': naturalFired,
        'gradualNext': gradualNext,
        'gradualFired': gradualFired,
        'acknowledged': acknowledged,
        'closed': closed,
        'planLogged': planLogged,
        'lastTickMs': lastTickMs,
        'naturalSig': naturalSig,
        'fallbackSig': fallbackSig,
      };
}

// ── orchestrator ────────────────────────────────────────────────────────────

class WakeOrchestrator {
  WakeOrchestrator({
    required this.env,
    required this.stateStore,
    required this.traceStore,
    NaturalStageObserver? observer,
    DateTime Function()? now,
    this.opTimeout = const Duration(seconds: 30),
    this.onTraceChanged,
    this.onNaturalFired,
    this.repeatNatural = false,
    this.onNaturalRepeatChanged,
    this.repeatRetryWait = const Duration(seconds: 5),
    Future<void> Function(Duration)? repeatDelay,
  })  : observer = observer ?? const IsolateNaturalStageObserver(),
        _now = now ?? DateTime.now,
        _repeatDelay = repeatDelay ?? Future<void>.delayed;

  final WakeEnv env;
  final NaturalStageObserver observer;
  final WakeStateStore stateStore;
  final WakeTraceStore traceStore;
  final Duration opTimeout;
  final DateTime Function() _now;

  /// Replay the Natural plan after it fires, until a stop condition holds (see
  /// [_naturalRepeat]). Off by default so a fake environment that answers at
  /// once cannot spin; AppState turns it on.
  final bool repeatNatural;

  /// How long the repeat waits after a delivery that did not land (a dropped
  /// link, a rejected write) before it tries again. A delivery that landed is
  /// followed by the next at once: the shared band queue paces those.
  final Duration repeatRetryWait;
  final Future<void> Function(Duration) _repeatDelay;

  /// Called with true when a Natural repeat starts and false when the last one
  /// stops, for any reason: a screen offers "I'm up" while it is true. Never
  /// throws into the orchestrator.
  final void Function(bool running)? onNaturalRepeatChanged;

  void _repeatChanged(bool running) {
    try {
      onNaturalRepeatChanged?.call(running);
    } catch (_) {}
  }

  /// Called ONCE after a tick (or an acknowledgement) that appended trace rows,
  /// never per row, so a screen showing the trace can reload without a rebuild
  /// storm. Never throws into the orchestrator.
  final void Function()? onTraceChanged;

  /// Called once when a Natural early haptic was DELIVERED to the band
  /// (`WakeHapticResult.delivered` is not empty), with the tick's own time
  /// (foreground tick and headless gate alike); the wake-confirmation wiring
  /// hangs off it. A buzz that failed or that the environment held back (no
  /// alert transport, quiet hours, a stale event) woke nobody and is no
  /// evidence. Never throws into the orchestrator.
  final FutureOr<void> Function(DateTime at)? onNaturalFired;
  bool _traceDirty = false;

  void _signalTrace() {
    if (!_traceDirty) return;
    _traceDirty = false;
    try {
      onTraceChanged?.call();
    } catch (_) {}
  }

  bool _ticking = false;
  bool _disposed = false;

  /// Occurrences (wake epoch s) with a Natural repeat running: one loop each.
  final Set<int> _repeating = {};

  /// A Natural repeat is running (for any wake occurrence).
  bool get isNaturalRepeating => _repeating.isNotEmpty;

  /// The wearer dismissed the running repeat without a plan to acknowledge
  /// (the alarm was disarmed meanwhile): stops it like [acknowledge] would.
  /// Touches nothing else; the native alarm is not reachable from here.
  void dismissNaturalRepeat() => _ackedWakes.addAll(_repeating);

  /// A native alarm fired at [fireAt] (phone time): ends only the repeat of THE
  /// wake it belongs to, i.e. one whose wake time T has [fireAt] within
  /// [T - 1 min, T + 5 min]. A fire for another wake (a replayed one, an
  /// earlier alarm) leaves a newly configured wake's repeat alone. Returns
  /// whether a repeat was ended.
  bool dismissNaturalRepeatForFire(DateTime fireAt) {
    var ended = false;
    for (final sec in _repeating) {
      final t = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
      final d = fireAt.difference(t);
      if (d >= const Duration(minutes: -1) && d <= const Duration(minutes: 5)) {
        _ackedWakes.add(sec);
        ended = true;
      }
    }
    return ended;
  }

  /// Stops every Natural repeat at its next check. The native alarm and the
  /// persisted run state are left exactly as they are.
  void dispose() => _disposed = true;

  /// Wakes the user acknowledged during this process. [acknowledge] sets it
  /// FIRST, so a tick already in flight (holding a snapshot loaded before the
  /// acknowledgement) sees it right before any delivery and before it saves.
  final Set<int> _ackedWakes = {};

  /// Serialises every read-modify-write of the run state, so an
  /// acknowledgement and a tick's save can never overwrite each other.
  Future<void> _stateLock = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() body) {
    final done = Completer<T>();
    final prev = _stateLock;
    _stateLock = done.future.then((_) {}, onError: (_) {});
    prev.then((_) async {
      try {
        done.complete(await body());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// Folds the in-process acknowledgement into [run] and returns it.
  bool _acked(_Run run) {
    if (_ackedWakes.contains(run.wakeEpoch)) run.acknowledged = true;
    return run.acknowledged;
  }

  /// The last run state this instance wrote (or tried to). When the store fails
  /// to save or to load, this keeps the "already fired" flag and the Gradual
  /// cursor alive for the life of the process, so a database error cannot turn
  /// into a second early haptic. A restart loses it; the dispatcher's durable
  /// per-event ledger (stable event ids) is the guard across that boundary.
  Map<String, Object?>? _mem;

  /// The newest state exists only in [_mem] (the last save did not land).
  bool _memAhead = false;

  /// Run one tick. Coalesces with a tick already in flight. Never throws.
  ///
  /// [repeatBound] caps how long a Natural repeat started by this tick may run
  /// (counted from its start), on top of T; null is T only.
  Future<WakeTickOutcome> tick(
    WakePlanInput plan, {
    DateTime? scheduledFor,
    Duration? repeatBound,
  }) async {
    if (_ticking) return const WakeTickOutcome(coalesced: true);
    _ticking = true;
    try {
      return await _tick(plan, scheduledFor, repeatBound);
    } catch (e) {
      await _trace(plan.wakeSec, 'error', {'where': 'tick', 'error': '$e'});
      return const WakeTickOutcome();
    } finally {
      _ticking = false;
      _signalTrace();
    }
  }

  /// [tick] for a headless/background wake source: serialised through the
  /// process-wide [HeadlessSyncGate], SKIPPED (not queued) when another
  /// headless run holds it. Returns null on a skip, recorded in the trace.
  Future<WakeTickOutcome?> tickThroughGate(
    WakePlanInput plan, {
    DateTime? scheduledFor,
    String owner = kWakeGateOwner,
  }) async {
    // The Natural repeat outlives the tick (it is detached), so the headless
    // run's own hard ceiling bounds it too: a background isolate cannot loop
    // for ever, and iOS ends the task around then anyway. Past that, the
    // native alarm at T is the wake.
    final out = await HeadlessSyncGate.tryRun<WakeTickOutcome>(
        owner,
        () => tick(plan,
            scheduledFor: scheduledFor,
            repeatBound: HeadlessSyncGate.runCeiling));
    if (out == null) {
      await _trace(plan.wakeSec, 'skip',
          {'reason': 'headlessGateBusy', 'owner': owner});
      _signalTrace();
    }
    return out;
  }

  /// The user explicitly acknowledged this wake. Stops the remaining
  /// phone-driven steps. With [cancelNative] it also REQUESTS cancellation of
  /// the native alarm; if that fails, throws or hangs, the alarm at T is
  /// verified and re-armed. This is the only code path that can cancel T.
  Future<WakeAckOutcome> acknowledge(
    WakePlanInput plan, {
    bool cancelNative = false,
  }) async {
    _ackedWakes.add(plan.wakeSec); // before anything awaits: see [_ackedWakes]
    await _locked(() async {
      // Read-modify-write under the lock: whatever a tick saved first is kept.
      final run = _Run.from(await _loadState(), plan.wakeSec)..acknowledged = true;
      await _saveUnlocked(run);
    });
    bool? cancelled;
    var armed = false;
    if (cancelNative) {
      try {
        cancelled = await env.cancelNativeAlarm(plan.wakeAt).timeout(opTimeout);
      } catch (_) {
        cancelled = false;
      }
    }
    if (cancelled != true) {
      // Not cancelled (or never asked): T must still be armed. Confirm, and
      // re-arm when the state is unknown or gone.
      FallbackStatus? st;
      try {
        st = await env.fallbackStatus(plan.wakeAt).timeout(opTimeout);
      } catch (_) {}
      if (st == null || !st.armedForWake) {
        try {
          st = await env.ensureFallbackArmed(plan.wakeAt).timeout(opTimeout);
        } catch (_) {}
      }
      armed = st?.armedForWake ?? false;
    }
    await _trace(plan.wakeSec, 'ack', {
      'cancelNative': cancelNative,
      'cancelled': cancelled,
      'fallbackArmed': armed,
    });
    _signalTrace();
    return WakeAckOutcome(
      nativeCancelRequested: cancelNative,
      nativeCancelled: cancelled == true,
      fallbackArmed: armed,
    );
  }

  // ── tick body ─────────────────────────────────────────────────────────────

  Future<WakeTickOutcome> _tick(
      WakePlanInput plan, DateTime? scheduledFor, Duration? repeatBound) async {
    final now = _now();
    final sec = plan.wakeSec;
    if (!_inActiveSpan(plan, now)) return const WakeTickOutcome();
    final run = _Run.from(await _loadState(), sec);

    if (!now.isBefore(plan.wakeAt)) {
      // T has passed: the native alarm owns the wake. Leave one summary row.
      if (!run.closed) {
        run.closed = true;
        await _trace(sec, 'closed', {
          'naturalFired': run.naturalFired,
          'gradualSteps': run.gradualFired,
          'acknowledged': run.acknowledged,
        });
        await _save(run);
      }
      return const WakeTickOutcome(closed: true);
    }

    if (!run.planLogged) {
      run.planLogged = true;
      await _trace(sec, 'plan', {
        'configuration': plan.configuration.name,
        'naturalMinutes': plan.naturalMinutes,
        'gradualMinutes': plan.gradualMinutes,
        'gradualPattern': plan.gradualPattern.name,
        'gradualCadenceSec': plan.gradualCadenceSec,
        'upgradePending': plan.upgradePending,
        'wakeAtMs': plan.wakeAt.millisecondsSinceEpoch,
        'utcOffsetMin': plan.wakeAt.timeZoneOffset.inMinutes,
      });
    }
    final lastTick = run.lastTickMs;
    if (lastTick != null &&
        now.millisecondsSinceEpoch - lastTick > kWakeTickGap.inMilliseconds) {
      await _trace(sec, 'gap', {
        'sinceLastTickSec': (now.millisecondsSinceEpoch - lastTick) ~/ 1000,
      });
    }

    await _verifyFallback(plan, run);

    NaturalReason? naturalReason;
    var naturalFired = false;
    try {
      final r = await _natural(plan, run, now, scheduledFor, repeatBound);
      naturalReason = r.$1;
      naturalFired = r.$2;
    } catch (e) {
      await _trace(sec, 'error', {'where': 'natural', 'error': '$e'});
    }
    await _save(run);

    int? gradualFired;
    try {
      gradualFired = await _gradual(plan, run, now);
    } catch (e) {
      await _trace(sec, 'error', {'where': 'gradual', 'error': '$e'});
    }

    run.lastTickMs = now.millisecondsSinceEpoch;
    await _save(run);
    return WakeTickOutcome(
      natural: naturalReason,
      naturalFired: naturalFired,
      gradualStepFired: gradualFired,
    );
  }

  static bool _inActiveSpan(WakePlanInput plan, DateTime now) {
    final first = WakeTimeline.compute(
      wakeAt: plan.wakeAt,
      naturalMinutes: plan.naturalMinutes,
      gradualMinutes: plan.gradualMinutes,
    ).parts.first.at;
    return !now.isBefore(first.subtract(kWakeActiveMargin)) &&
        now.isBefore(plan.wakeAt.add(kWakeClosingGrace));
  }

  /// Step 1, every configuration: T is armed. Re-arm when it is not.
  Future<void> _verifyFallback(WakePlanInput plan, _Run run) async {
    FallbackStatus? st;
    var rearmed = false;
    try {
      st = await env.fallbackStatus(plan.wakeAt).timeout(opTimeout);
    } catch (e) {
      await _trace(plan.wakeSec, 'error', {'where': 'fallbackStatus', 'error': '$e'});
    }
    if (st != null && !st.armedForWake) {
      try {
        st = await env.ensureFallbackArmed(plan.wakeAt).timeout(opTimeout);
        rearmed = true;
      } catch (e) {
        await _trace(plan.wakeSec, 'error', {'where': 'ensureFallback', 'error': '$e'});
      }
    }
    final sig = '${st?.armedForWake}/${st?.confirmed}/$rearmed';
    if (sig != run.fallbackSig) {
      run.fallbackSig = sig;
      await _trace(plan.wakeSec, 'fallback', {
        'armed': st?.armedForWake,
        'confirmed': st?.confirmed,
        'rearmed': rearmed,
      });
    }
  }

  Future<(NaturalReason?, bool)> _natural(
    WakePlanInput plan,
    _Run run,
    DateTime now,
    DateTime? scheduledFor,
    Duration? repeatBound,
  ) async {
    final n = plan.naturalMinutes;
    final sec = plan.wakeSec;
    if (n <= 0) return (null, false);

    Future<void> log(NaturalReason reason, Map<String, Object?> extra,
        {bool force = false}) async {
      final sig = '${reason.name}|${extra['samples']}|${extra['stage']}|'
          '${extra['confidence'] is num ? ((extra['confidence'] as num) * 10).round() : ''}';
      if (!force && sig == run.naturalSig) return;
      run.naturalSig = sig;
      await _trace(sec, 'natural', {'reason': reason.name, ...extra});
    }

    if (plan.upgradePending) {
      await log(NaturalReason.upgradePending, const {});
      return (NaturalReason.upgradePending, false);
    }
    if (now.isBefore(plan.wakeAt.subtract(naturalCollectionLead(n)))) {
      return (NaturalReason.beforeWindow, false); // collection has not begun
    }
    // Sleep so far, when known: the detected onset or the saved schedule's onset
    // for this night. Unknown never blocks.
    final onset = _onsetFor(plan, now);
    if (NaturalWakePlanner.sleptLessThan(onset: onset, now: now)) {
      final d = NaturalWakePlanner.decide(
          _input(plan, run, now, null, Duration.zero, onset: onset));
      await log(d.reason, {'sleptMin': now.difference(onset!).inMinutes});
      return (d.reason, false);
    }
    if (run.acknowledged) return (NaturalReason.acknowledged, false);
    if (run.naturalFired) return (NaturalReason.alreadyFired, false);

    final lateness = scheduledFor == null
        ? Duration.zero
        : (now.isAfter(scheduledFor) ? now.difference(scheduledFor) : Duration.zero);

    // Feed the stager only while a link exists: without one nothing new is
    // arriving and the haptic could not be sent anyway.
    NaturalObservation? obs;
    var samplesFailed = false;
    if (env.connected) {
      final fromMs = run.lastFedMs ??
          plan.wakeAt.subtract(naturalCollectionLead(n)).millisecondsSinceEpoch.toDouble();
      final toMs = now.millisecondsSinceEpoch.toDouble();
      WakeSamples? samples;
      try {
        samples = await env
            .samples(DateTime.fromMillisecondsSinceEpoch(fromMs.round()), now)
            .timeout(opTimeout);
      } catch (e) {
        samplesFailed = true;
        await _trace(sec, 'error', {'where': 'samples', 'error': '$e'});
      }
      if (samples != null) {
        // Decoded history lands in chunks, so a read can come back empty and
        // the rows for that span arrive a moment later. The watermark is the
        // newest SAMPLE received, never the wall clock: an empty read leaves
        // it where it was, and the late rows are read on the next tick. Rows
        // at or before it (the loader reads whole seconds, so the boundary
        // second comes back again) were already fed and are dropped here.
        final mark = run.lastFedMs;
        List<List<double>> fresh(List<List<double>> rows) =>
            mark == null ? rows : [for (final r in rows) if (r[0] > mark) r];
        final hr = fresh(samples.hr);
        final accel = fresh(samples.accel);
        final rr = fresh(samples.rr);
        double? newest;
        for (final rows in [hr, accel, rr]) {
          for (final r in rows) {
            if (newest == null || r[0] > newest) newest = r[0];
          }
        }
        try {
          final result = await observer
              .observe(NaturalObserveRequest(
                nowMs: toMs,
                hr: hr,
                accel: accel,
                rr: rr,
                priorState: run.stager,
              ))
              .timeout(opTimeout * 2);
          obs = result.observation;
          run.stager = result.nextState;
          if (newest != null) run.lastFedMs = newest;
        } catch (e) {
          await _trace(sec, 'error', {'where': 'observer', 'error': '$e'});
        }
      }
    }

    // Awake because they are using the phone and the wrist moved with it.
    final userActive = await _userActive(sec, now);

    // "I'm up" may have landed while the samples and the observer were awaited.
    if (_acked(run)) return (NaturalReason.acknowledged, false);

    final decision = samplesFailed && !userActive
        ? const NaturalDecision(NaturalReason.samplesUnavailable)
        : NaturalWakePlanner.decide(_input(
            plan, run, now, obs, lateness, onset: onset,
            userActive: userActive));
    final detail = <String, Object?>{
      if (decision.viaUserActivity) 'basis': 'userActive',
      'samples': decision.samplesCurrent == null
          ? null
          : (decision.samplesCurrent! ? 'current' : 'stale'),
      'stage': obs?.stage,
      'confidence': obs?.confidence,
      'runSec': obs?.runSec,
      'evidenceAgeMs': obs?.evidenceAgeMs,
      'abstention': obs?.abstention,
      if (lateness > Duration.zero) 'latenessSec': lateness.inSeconds,
    };
    await log(decision.reason, detail, force: decision.fire);
    if (!decision.fire) return (decision.reason, false);

    // Marked fired and persisted BEFORE the write: a crash, a timeout or a
    // throw must not turn into a second buzz, and T still covers a haptic
    // that never landed.
    if (_acked(run)) return (NaturalReason.acknowledged, false);
    run.naturalFired = true;
    await _save(run);
    final eventId = 'wake:natural:$sec';
    await _trace(sec, 'natural_haptic', {
      'phase': 'request',
      'eventId': eventId,
      'stage': obs?.stage,
      'confidence': obs?.confidence,
      'runSec': obs?.runSec,
      if (decision.viaUserActivity) 'basis': 'userActive',
    });
    // A double tap during this first delivery already counts as a dismissal.
    final startedAt = _now();
    final sent = await _haptic(
      sec,
      'natural_haptic',
      WakeHapticRequest(
        kind: WakeHapticKind.natural,
        eventId: eventId,
        wakeAt: plan.wakeAt,
        sourceTime: now,
      ),
    );
    if (sent == null) return (NaturalReason.acknowledged, false);
    // Whatever the first delivery did (landed, failed, was held back), Natural
    // has fired: the repeat keeps going until a stop condition. It is started
    // only here, so a restart (run.naturalFired is persisted) never replays.
    if (repeatNatural) _startNaturalRepeat(plan, startedAt, repeatBound);
    // Only a buzz that reached the band is evidence that the wearer was woken.
    // One that failed (threw, timed out, no link) or that the environment held
    // back (`suppressionReason`: a band with no alert transport, a muted rule)
    // is still the early wake having fired, and is not re-sent, but it proves
    // nothing about the wearer. A failing hook never undoes the fire (it is
    // saved).
    if (sent.delivered.isNotEmpty) await _notifyNaturalFired(sec, now);
    return (NaturalReason.fire, true);
  }

  void _startNaturalRepeat(
      WakePlanInput plan, DateTime startedAt, Duration? bound) {
    final sec = plan.wakeSec;
    if (_disposed || !_repeating.add(sec)) return; // one loop per occurrence
    final deadline = bound == null ? null : _now().add(bound);
    _repeatChanged(true);
    unawaited(_naturalRepeat(plan, startedAt, deadline));
  }

  /// Why the repeat must stop now, or null to go on.
  String? _repeatStopReason(
      WakePlanInput plan, DateTime startedAt, DateTime? deadline) {
    if (_disposed) return 'disposed';
    if (_ackedWakes.contains(plan.wakeSec)) return 'acknowledged';
    final tap = env.lastBandDoubleTapAt;
    // A double tap from before this repeat started was about something else.
    if (tap != null && !tap.isBefore(startedAt)) return 'bandDoubleTap';
    final now = _now();
    if (!now.isBefore(plan.wakeAt)) return 'wakeTime';
    if (deadline != null && !now.isBefore(deadline)) return 'headlessBound';
    return null;
  }

  /// Replays the Natural plan as soon as the previous delivery finishes, until
  /// [_repeatStopReason]. Delivered through the same shared band queue as the
  /// first one (never as a gesture), so the queue paces it: a job waits, never
  /// drops. A delivery that does not land waits [repeatRetryWait] and goes on.
  /// Detached from the tick; takes no lock. Never throws. Writes only
  /// early haptics and trace rows: the native alarm at T is not reachable here.
  Future<void> _naturalRepeat(
      WakePlanInput plan, DateTime startedAt, DateTime? deadline) async {
    final sec = plan.wakeSec;
    var reason = 'error';
    var delivered = 0, notDelivered = 0;
    String? lastSig;
    try {
      await _trace(sec, 'natural_repeat', {
        'phase': 'start',
        'retryWaitSec': repeatRetryWait.inSeconds,
        if (deadline != null)
          'boundSec': deadline.difference(_now()).inSeconds,
      });
      _signalTrace();
      while (true) {
        final stop = _repeatStopReason(plan, startedAt, deadline);
        if (stop != null) {
          reason = stop;
          break;
        }
        final n = delivered + notDelivered + 1;
        final res = await _haptic(
          sec,
          'natural_repeat',
          WakeHapticRequest(
            kind: WakeHapticKind.natural,
            eventId: 'wake:natural:$sec:r$n',
            wakeAt: plan.wakeAt,
            sourceTime: _now(),
            repeat: true,
          ),
          traceResult: false,
        );
        if (res == null) {
          reason = 'acknowledged';
          break;
        }
        res.ok ? delivered++ : notDelivered++;
        // Rows on a change only: a band that is away for an hour must not
        // write a row every few seconds.
        final sig = '${res.ok}|${res.suppressionReason}|${res.error}';
        if (sig != lastSig) {
          lastSig = sig;
          await _trace(sec, 'natural_repeat', {
            'phase': 'result',
            'index': n,
            'result': res.ok ? 'sent' : 'notDelivered',
            'suppression': res.suppressionReason,
            'error': res.error,
          });
          _signalTrace();
        }
        if (!res.ok) await _repeatDelay(repeatRetryWait);
      }
    } catch (e) {
      reason = 'error';
      await _trace(sec, 'error', {'where': 'naturalRepeat', 'error': '$e'});
    } finally {
      _repeating.remove(sec);
      if (_repeating.isEmpty) _repeatChanged(false);
      await _trace(sec, 'natural_repeat', {
        'phase': 'stop',
        'reason': reason,
        'delivered': delivered,
        'notDelivered': notDelivered,
      });
      _signalTrace();
    }
  }

  Future<void> _notifyNaturalFired(int sec, DateTime at) async {
    final hook = onNaturalFired;
    if (hook == null) return;
    try {
      await Future<void>.sync(() => hook(at)).timeout(opTimeout);
    } catch (e) {
      await _trace(sec, 'error', {'where': 'naturalFiredHook', 'error': '$e'});
    }
  }

  /// Whether a recent foreground touch and band motion line up. Reads only the
  /// accel rows around each of the newest touches; no rows, no touches or any
  /// failure is simply false (never a guess).
  Future<bool> _userActive(int sec, DateTime now) async {
    try {
      final touches = [
        for (final t in env.recentInteractions)
          if (!t.isAfter(now) && now.difference(t) <= kUserInteractionFreshness) t
      ];
      if (touches.isEmpty) return false;
      final newest = touches.reversed.take(3).toList();
      final from = newest.last.subtract(kUserMotionHalfWindow);
      final to = newest.first.add(kUserMotionHalfWindow);
      final samples = await env
          .samples(from, to.isAfter(now) ? now : to)
          .timeout(opTimeout);
      return NaturalWakePlanner.userAwakeFromInteraction(
        now: now,
        interactions: newest,
        accel: samples.accel,
      );
    } catch (e) {
      await _trace(sec, 'error', {'where': 'userActive', 'error': '$e'});
      return false;
    }
  }

  NaturalDecisionInput _input(WakePlanInput plan, _Run run, DateTime now,
          NaturalObservation? obs, Duration lateness,
          {bool userActive = false, DateTime? onset}) =>
      NaturalDecisionInput(
        now: now,
        wakeAt: plan.wakeAt,
        windowMinutes: plan.naturalMinutes,
        observation: obs,
        connected: env.connected,
        alreadyFired: run.naturalFired,
        acknowledged: run.acknowledged,
        lateness: lateness,
        userActive: userActive,
        sleepOnset: onset,
      );

  DateTime? _onsetFor(WakePlanInput plan, DateTime now) =>
      plan.sleepOnset ??
      NaturalWakePlanner.scheduleOnsetAt(plan.expectedSchedule, now);

  Future<int?> _gradual(WakePlanInput plan, _Run run, DateTime now) async {
    if (plan.gradualMinutes <= 0 || _acked(run)) return null;
    final sec = plan.wakeSec;
    final steps = GradualWakeSchedule.steps(
      wakeAt: plan.wakeAt,
      windowMinutes: plan.gradualMinutes,
      cadenceSec: plan.gradualCadenceSec,
      pattern: plan.gradualPattern,
    );
    final due = [
      for (final s in steps)
        if (s.index >= run.gradualNext && !s.at.isAfter(now)) s
    ];
    if (due.isEmpty) return null;
    final latest = due.last;
    // Persist the cursor first, for the same reason as the Natural flag.
    run.gradualNext = latest.index + 1;
    await _save(run);
    for (final s in due.where((s) => s.index != latest.index)) {
      await _trace(sec, 'gradual', {'index': s.index, 'result': 'skippedLate'});
    }
    if (now.difference(latest.at) > kGradualStepGrace) {
      await _trace(sec, 'gradual', {'index': latest.index, 'result': 'skippedLate'});
      return null;
    }
    final attempted = await _haptic(
      sec,
      'gradual',
      WakeHapticRequest(
        kind: WakeHapticKind.gradual,
        eventId: 'wake:gradual:$sec:${latest.index}',
        wakeAt: plan.wakeAt,
        sourceTime: now,
        stepIndex: latest.index,
        sequence: latest.sequence,
        gradualPattern: plan.gradualPattern,
      ),
    );
    if (attempted == null) return null;
    run.gradualFired++;
    return latest.index;
  }

  /// Sends one haptic and returns what the band reported. Null (nothing sent)
  /// when the user acknowledged this wake: the check and the send are one
  /// synchronous step, so no awaited acknowledgement can slip between them.
  Future<WakeHapticResult?> _haptic(
      int sec, String kind, WakeHapticRequest req,
      {bool traceResult = true}) async {
    if (_ackedWakes.contains(sec)) {
      if (traceResult) {
        await _trace(
            sec, 'skip', {'reason': 'acknowledged', 'eventId': req.eventId});
      }
      return null;
    }
    WakeHapticResult res;
    try {
      res = await env.haptic(req).timeout(opTimeout);
    } catch (e) {
      res = WakeHapticResult(error: '$e');
    }
    if (!traceResult) return res;
    await _trace(sec, kind, {
      if (kind == 'natural_haptic') 'phase': 'result',
      if (req.stepIndex != null) 'index': req.stepIndex,
      'eventId': req.eventId,
      'result': res.ok ? 'sent' : 'notDelivered',
      'delivered': res.delivered,
      'suppression': res.suppressionReason,
      'error': res.error,
    });
    return res;
  }

  // ── persistence helpers (a store failure never breaks a wake) ─────────────

  Future<Map<String, Object?>?> _loadState() async {
    Map<String, Object?>? stored;
    var failed = false;
    try {
      stored = await stateStore.load().timeout(opTimeout);
    } catch (_) {
      failed = true;
    }
    final mem = _mem;
    if (mem != null && (failed || _memAhead)) {
      return (jsonDecode(jsonEncode(mem)) as Map).cast<String, Object?>();
    }
    return stored;
  }

  Future<void> _save(_Run run) => _locked(() => _saveUnlocked(run));

  Future<void> _saveUnlocked(_Run run) async {
    // A tick's snapshot may predate an acknowledgement: never write it back
    // as "not acknowledged".
    _acked(run);
    Map<String, Object?> json;
    try {
      // The same round trip a real store does.
      json = (jsonDecode(jsonEncode(run.toJson())) as Map).cast<String, Object?>();
    } catch (_) {
      // An unserialisable stager state (a corrupt observation) costs a warm-up,
      // never the fired flag or the Gradual cursor.
      run.stager = null;
      json = (jsonDecode(jsonEncode(run.toJson())) as Map).cast<String, Object?>();
    }
    _mem = json;
    try {
      await stateStore.save(json).timeout(opTimeout);
      _memAhead = false;
    } catch (_) {
      _memAhead = true;
    }
  }

  Future<void> _trace(int sec, String kind, Map<String, Object?> data) async {
    try {
      await traceStore
          .append(WakeTraceEntry(
            wakeEpochSec: sec,
            atMs: _now().millisecondsSinceEpoch,
            kind: kind,
            data: data,
          ))
          .timeout(opTimeout);
      _traceDirty = true;
    } catch (_) {}
  }
}
