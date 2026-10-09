// The derive orchestration seam, moved out of AppState with no
// behaviour change. It owns: the scheduler that decides WHEN a pass runs, the
// pass itself (`afterDrain`) and the post-derive work around it, the RecalcState
// notifier and its owner bookkeeping, the per-day publish coalescer, the
// artifact warmer hand-off, the calculation policy, the revision notifier that
// screens re-read on, and the perf readouts.
//
// It does not own the DerivationEngine (AppState also uses it for imports,
// re-analysis and sleep edits) nor the work a pass triggers that belongs to
// other concerns (steps, health export, recovery-ready push, disk reclaim);
// those arrive as callbacks. It holds no reference to AppState.
import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../compute/calc_power_policy.dart';
import '../compute/derivation_engine.dart';
import '../compute/derive_outcome.dart';
import '../compute/derive_scheduler.dart';
import '../compute/periodic_calculation_policy.dart';
import '../compute/profile.dart';
import '../data/db.dart';
import '../data/bundle_store.dart';
import '../data/local_repository.dart';
import '../data/local_repository_impl.dart';
import '../telemetry/health_uploader.dart';
import '../telemetry/telemetry_service.dart';
import '../wake/wake_stores.dart';
import '../widget/widget_service.dart';
import 'artifact_warmer.dart';
import 'power_source.dart';
import 'publish_gate.dart';
import 'recalc_state.dart';
import 'revision_coalescer.dart';

/// The two engine calls [DeriveCoordinator.afterDrain] makes, as test seams (see
/// `AppState.debugDeriveRun` / `debugRescanRecent`).
typedef DeriveRunHook = Future<int> Function({
  required bool heavy,
  required bool changedOnly,
  void Function(int total)? onScope,
  void Function(List<String> days)? onScopeDays,
  void Function(String day, int index, int total)? onDayDone,
  void Function(bool active)? onCrossDay,
});
typedef RescanHook = Future<int> Function({
  void Function(List<String> days)? onScopeDays,
  void Function(String day, int index, int total)? onDayDone,
});

class DeriveCoordinator {
  DeriveCoordinator({
    required DerivationEngine Function() engine,
    required Profile Function() profile,
    required void Function(String line) log,
    required void Function() notify,
    required bool Function() isDisposed,
    required LocalRepository? Function() repo,
    required bool Function() warmHeld,
    required Future<void> Function() refreshPhoneStepsToday,
    required Future<void> Function() maybeNotifyRecoveryReady,
    required Future<int> Function() runHealthExport,
    required bool Function() healthSyncEnabled,
    required bool Function() telemetryConsent,
    required bool Function() healthShareConsent,
    required Future<void> Function() maybeReclaimDiskSpace,
    PeriodicCalculationPolicy? calculationPolicy,
    PublishGate? publishGate,
  })  : _engine = engine,
        _profileOf = profile,
        _log = log,
        _notify = notify,
        _hostDisposed = isDisposed,
        _repo = repo,
        _warmHeld = warmHeld,
        _refreshPhoneStepsToday = refreshPhoneStepsToday,
        _maybeNotifyRecoveryReady = maybeNotifyRecoveryReady,
        _runHealthExport = runHealthExport,
        _healthSyncEnabled = healthSyncEnabled,
        _telemetryConsent = telemetryConsent,
        _healthShareConsent = healthShareConsent,
        _maybeReclaimDiskSpace = maybeReclaimDiskSpace,
        _policyOverride = calculationPolicy,
        _publishGateOverride = publishGate;

  // The engine is resolved on use: AppState builds it lazily (it reads the
  // `_background` flag both of its constructors have set by then).
  final DerivationEngine Function() _engine;
  DerivationEngine get _derive => _engine();

  final Profile Function() _profileOf;
  Profile get _profile => _profileOf();

  final void Function(String line) _log;
  final void Function() _notify;
  final bool Function() _hostDisposed;
  final LocalRepository? Function() _repo;
  final bool Function() _warmHeld;
  final Future<void> Function() _refreshPhoneStepsToday;
  final Future<void> Function() _maybeNotifyRecoveryReady;
  final Future<int> Function() _runHealthExport;
  final bool Function() _healthSyncEnabled;
  final bool Function() _telemetryConsent;
  final bool Function() _healthShareConsent;
  final Future<void> Function() _maybeReclaimDiskSpace;
  final PeriodicCalculationPolicy? _policyOverride;
  final PublishGate? _publishGateOverride;

  /// P2.3 stub: the serialised publish loop every freshness write and revision
  /// bump goes through.
  PublishGate get publishGate =>
      _publishGateOverride ?? (throw UnimplementedError('P2.3 PublishGate'));

  /// P2.3 stub: request a publish and wait until the gate is idle.
  Future<void> publishNow() => throw UnimplementedError('P2.3 publishNow');

  // The host is gone, or this coordinator has been disposed (which, under
  // AppState, only ever happens after the host flag is set).
  bool _closed = false;
  bool get _disposed => _closed || _hostDisposed();

  /// What the scheduler runs for a job. The automatic LIGHT pass skips days
  /// whose input has not moved since they were last derived ([changedOnly]);
  /// heavy keeps the full sweep (finalize extras, force paths). Returns how the
  /// pass ended, which decides whether the job is deleted or retried.
  Future<DeriveOutcome> _runScheduled({required DeriveJobKind kind}) =>
      afterDrain(
        heavy: kind == DeriveJobKind.heavy,
        changedOnly: kind == DeriveJobKind.light,
        automatic: true,
      );

  /// Whether a light pass may reuse cached calculations: only while the
  /// phone is unplugged and the causal stager says the wearer is awake.
  late final PeriodicCalculationPolicy _calculationPolicy =
      _policyOverride ??
          PeriodicCalculationPolicy(
            phoneCharging: _phoneCharging,
            loadSamples: loadWakeSamples,
          );

  /// Null when the platform cannot say; the policy treats that as charging.
  static Future<bool?> _phoneCharging() async =>
      switch (await Battery().batteryState) {
        BatteryState.discharging => false,
        BatteryState.charging ||
        BatteryState.full ||
        BatteryState.connectedNotCharging => true,
        BatteryState.unknown => null,
      };

  /// The scheduler that decides when a pass runs. AppState feeds it the holds
  /// (offload, background, workout, manual sync) and the stored-data marks.
  late final DeriveScheduler scheduler = DeriveScheduler(
    run: _runScheduled,
    log: _log,
    onChanged: _schedulerChanged,
    // Measurement only: queue wait and hold reasons for DerivePerf.
    onQueued: () => _derive.perf.enqueued(),
    onWaiting: ({required settling}) {
      if (settling) _derive.perf.noteSettle();
      _derive.perf.noteHolds(scheduler.snapshot());
    },
  );

  void _schedulerChanged() {
    _notify();
    _retryHeldWarms();
  }

  // Screen requests that arrived under a hold wait in the warmer; a hold that
  // may just have ended (a scheduler edge, or the next foreground activity for
  // the live sessions the scheduler does not hear about) gives them their go.
  void _retryHeldWarms() {
    if (_disposed || _warmBlocked) return;
    final warmer = _artifactWarmer;
    if (warmer == null) return;
    unawaited(() async {
      if (await warmer.warmPending() && !_disposed) bumpInsights();
    }());
  }

  /// Bumped whenever stored insights change so listeners can re-query without a
  /// full ChangeNotifier repaint.
  final ValueNotifier<int> insightsRevision = ValueNotifier<int>(0);

  /// The days a running derive pass has not finished (and whether its
  /// cross-day step is running), for the "As of" labels. A notifier of its own,
  /// NOT notifyListeners: AppState ticks at ~1 Hz with live HR and the label
  /// must not ride that.
  final ValueNotifier<RecalcState> _recalc =
      ValueNotifier<RecalcState>(RecalcState.idle);
  ValueListenable<RecalcState> get recalc => _recalc;

  /// Which pass owns [_recalc]. A pass only clears what it set, so a refused
  /// pass (engine busy) returning early cannot wipe a running rescan's days.
  int _recalcSeq = 0;
  int _recalcOwner = 0;

  void _setRecalc(RecalcState s) {
    if (_disposed) return;
    _recalc.value = s;
  }

  void _recalcScope(int owner, List<String> days) {
    if (days.isEmpty) return;
    _recalcOwner = owner;
    _setRecalc(RecalcState(days: {...days}, passStartedAt: DateTime.now()));
  }

  void _recalcDayDone(int owner, String day) {
    if (_recalcOwner != owner) return;
    final cur = _recalc.value;
    if (!cur.days.contains(day)) return;
    _setRecalc(cur.copyWith(days: {...cur.days}..remove(day)));
  }

  void _recalcCrossDay(int owner, bool active) {
    if (_recalcOwner != owner) return;
    _setRecalc(_recalc.value.copyWith(crossDay: active));
  }

  void _recalcClear(int owner) {
    if (_recalcOwner != owner) return;
    _recalcOwner = 0;
    final cut = _recalc.value;
    _setRecalc(RecalcState.idle);
    // A pass that ended with days still pending (failed, cancelled, refused)
    // writes nothing more for them, and the labels on screen wait for a reload
    // to drop: one more revision lets them. Not through the coalescer — this is
    // the end of the pass, and a trailing timer outliving it helps no one.
    if (!_disposed && (cut.days.isNotEmpty || cut.crossDay)) bumpInsights();
  }

  /// Say that the DURABLE data changed, so every screen reading it re-reads.
  /// See `AppState.bumpInsights`.
  void bumpInsights() {
    insightsRevision.value = insightsRevision.value + 1;
  }

  /// Each committed day publishes (freshness, then a revision bump) as it
  /// lands, at most once per 1500 ms with a trailing flush, so Home and Health
  /// fill in during a long pass instead of after it.
  late final RevisionCoalescer _dayPublisher = RevisionCoalescer(
    fire: _publishDay,
    nowMs: () => DateTime.now().millisecondsSinceEpoch,
  );

  void _publishDay() {
    unawaited(() async {
      try {
        await LocalDb.refreshComputeFreshness();
      } catch (e) {
        _log('[derive] freshness refresh failed: $e');
      }
      if (_disposed) return;
      LocalRepositoryImpl.invalidateBundleMemo();
      bumpInsights();
    }());
  }

  /// First usable render: revision bump -> the Home commit that consumed it.
  /// Null until a bump has been measured.
  int? lastHomeRenderMs;

  void recordHomeRender(int ms) {
    lastHomeRenderMs = ms;
    _log('[perf] home render $ms ms');
  }

  /// The last pass that computed a day, as [DerivePerf.summary] — null until
  /// one has. Read-only, for Settings > Developer.
  Map<String, Object?>? get lastPassPerf =>
      (_derive.snapshot()['last_pass_perf'] as Map?)?.cast<String, Object?>();

  // Test seams. They carry no @visibleForTesting here because AppState's own
  // delegates (which keep the annotation) forward to them; only tests and those
  // delegates may use them.

  /// The engine is not injectable, so a test replaces the two calls
  /// [afterDrain] makes on it.
  DeriveRunHook? debugDeriveRun;

  /// The source the artifact warmer uses (see [_warmer]). Null in production:
  /// the repository's own.
  ArtifactSource? debugArtifactSource;
  RescanHook? debugRescanRecent;
  Future<DeriveOutcome> debugRunScheduled({required DeriveJobKind kind}) =>
      _runScheduled(kind: kind);
  void debugSetRecalc(RecalcState s) => _setRecalc(s);
  Future<void> debugAfterDrain({bool heavy = false, bool changedOnly = false}) =>
      afterDrain(heavy: heavy, changedOnly: changedOnly);

  // The ONE background warmer of the slow screen artifacts. Built
  // when first needed, after a pass that computed days; never while a workout,
  // breathing session or ECG capture is live, while the band is offloading or
  // while this is a headless run.
  ArtifactWarmer? _artifactWarmer;

  ArtifactWarmer? get _warmer {
    final existing = _artifactWarmer;
    if (existing != null) return existing;
    final r = _repo();
    final source = debugArtifactSource ??
        (r is LocalRepositoryImpl ? RepoArtifactSource(r) : null);
    if (source == null) return null;
    return _artifactWarmer = ArtifactWarmer(
      source: source,
      hold: () => _warmBlocked,
      log: _log,
    );
  }

  // A live capture, the background or an offload: nothing is warmed.
  bool get _warmBlocked => _warmHeld() || scheduler.offloadActive;

  /// Warms [key] on demand through the same warmer and queue as a pass, then
  /// says so if it stored something. Never throws; no warmer is a no-op. Under
  /// a hold the request waits for it to end (see [_retryHeldWarms]).
  Future<void> requestWarm(String key) async {
    final w = _warmer;
    if (w == null || _disposed) return;
    if (await w.warmKeys([key], keepIfHeld: true) && !_disposed) {
      bumpInsights();
    }
  }

  // ── the Calculations power mode ────────────────────────────────────────
  // The policy decides; this class owns the timers and the subscription. Only
  // AUTOMATIC work asks it (the scheduler's passes, the post-pass warm, idle and
  // plugged-in warming, the Eager sweep). A re-analyze, a manual sync, and a
  // screen's requestWarm never do. Every timer here is cancelled in [dispose].

  CalcPowerPolicy _policy = const CalcPowerPolicy(CalcPowerMode.balanced);
  CalcPowerPolicy get policy => _policy;

  /// A mode change lands at once, from the last power state seen.
  set policy(CalcPowerPolicy p) {
    _policy = p;
    if (_disposed) return;
    _derive.maxWorkers = p.maxWorkers;
    _applyPower();
  }

  /// Null in production: the battery one.
  PowerSource? debugPowerSource;

  BatteryPowerSource? _ownSource;
  StreamSubscription<PowerState>? _powerSub;
  // Calm until the first read: unplugged, no saver holds nothing back.
  PowerState _power = PowerState.unplugged;
  int _powerEvents = 0;

  Timer? _idleTimer;
  Timer? _sweepTimer;

  // The plug session (its chargingSince) the Eager sweep already ran for: at
  // most one per session. Cleared on unplug.
  DateTime? _sweptSince;

  // Whether plugged-in warming was allowed at the last look, so it fires on
  // the edge to allowed (a plug-in, the saver going off, a mode change), once.
  bool _plugWarmAllowed = false;

  // A held Eager sweep looks again after this. Skip, don't queue.
  static const Duration _sweepRetry = Duration(minutes: 1);

  /// Reads the power state once, follows its changes, applies the power hold,
  /// and arms the Eager sweep and the plugged-in warm. Idempotent.
  Future<void> attachPower() async {
    if (_disposed || _powerSub != null) return;
    final src = debugPowerSource ?? (_ownSource ??= BatteryPowerSource());
    _powerSub = src.changes.listen(
      _onPower,
      onError: (Object e) => _log('[power] state stream failed: $e'),
    );
    final seen = _powerEvents;
    try {
      final s = await src.read();
      // An edge that arrived while reading is newer than the read.
      if (_powerEvents == seen) _onPower(s);
    } catch (e) {
      _log('[power] read failed: $e');
    }
  }

  void _onPower(PowerState s) {
    if (_disposed) return;
    _powerEvents++;
    _power = s;
    if (!s.charging) _sweptSince = null;
    _applyPower();
  }

  void _applyPower() {
    if (_disposed) return;
    scheduler.setPowerHold(!_policy.mayDeriveAutomatically(_power));
    // The battery source polls the OS saver only while a flip would change a
    // decision.
    final src = debugPowerSource ?? _ownSource;
    if (src is BatteryPowerSource) src.watchSaver = _policy.saverMatters(_power);
    _armSweep();
    final warmNow = _policy.mayWarmWhilePlugged(_power);
    if (warmNow && !_plugWarmAllowed) unawaited(_warmAll());
    _plugWarmAllowed = warmNow;
  }

  /// Foreground activity: (re)starts the idle timer. When it fires and the
  /// policy allows it, the Home/Health artifacts are warmed.
  void noteActivity() {
    if (_disposed) return;
    _retryHeldWarms();
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_policy.mode == CalcPowerMode.maxBattery) return; // never warms idle
    _idleTimer = Timer(_policy.idleWarmDelay, () {
      _idleTimer = null;
      if (_disposed || !_policy.mayWarmIdle(_power)) return;
      unawaited(_warmAll());
    });
  }

  /// Warms every candidate artifact the repository knows of, through the one
  /// warmer (so its hold and per-key rules apply).
  Future<void> _warmAll() async {
    final w = _warmer;
    if (w == null || _disposed || _warmBlocked) return;
    try {
      final keys = await w.source.candidateKeys(const []);
      if (await w.warmKeys(keys) && !_disposed) bumpInsights();
    } catch (e) {
      _log('[warm] candidate keys failed: $e');
    }
  }

  // The Eager sweep timer runs for what is left of the plug delay, and is
  // re-armed on every power or mode change; the policy returns null (so nothing
  // is armed) unless Eager is on external power with a known start.
  void _armSweep() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    if (_disposed) return;
    final since = _power.chargingSince;
    if (since != null && since == _sweptSince) return;
    final left = _policy.untilEagerSweep(_power, clock.now());
    if (left != null) _sweepTimer = Timer(left, _sweepFire);
  }

  void _sweepFire() {
    _sweepTimer = null;
    if (_disposed) return;
    final left = _policy.untilEagerSweep(_power, clock.now());
    if (left == null) return; // unplugged, or no longer Eager
    final since = _power.chargingSince;
    if (since != null && since == _sweptSince) return; // this session is done
    if (left > Duration.zero) {
      _sweepTimer = Timer(left, _sweepFire);
      return;
    }
    if (_warmBlocked || scheduler.heldBesidesPower) {
      _sweepTimer = Timer(_sweepRetry, _sweepFire);
      return;
    }
    final chargingSince = _power.chargingSince;
    if (chargingSince != null && !_sweeping) unawaited(_sweep(chargingSince));
  }

  // A sweep is in flight. A power event meanwhile re-arms the timer; its fire
  // leaves the running sweep alone, which settles the session itself.
  bool _sweeping = false;

  // The existing full run, then the existing warm: no new compute path.
  Future<void> _sweep(DateTime chargingSince) async {
    _sweeping = true;
    final DeriveOutcome outcome;
    try {
      outcome = await afterDrain(heavy: true, changedOnly: false);
    } finally {
      _sweeping = false;
    }
    if (_disposed) return;
    if (_power.chargingSince != chargingSince) {
      _armSweep(); // a newer plug session may have waited on this sweep
      return;
    }
    // A refused pass (the engine was busy) or a failed one did not sweep: the
    // session stays open and this looks again. Transient per-day failures are
    // the scheduler's to retry.
    if (outcome.failed) {
      _sweepTimer ??= Timer(_sweepRetry, _sweepFire);
      return;
    }
    _sweptSince = chargingSince;
    await _warmAll();
  }

  /// Cancels everything this coordinator owns: the scheduler's timers, the
  /// warmer, the power subscription and timers, the trailing publish, and the
  /// two notifiers. Safe to call twice.
  void dispose() {
    if (_closed) return;
    _closed = true;
    _powerSub?.cancel();
    _powerSub = null;
    _ownSource?.dispose();
    _idleTimer?.cancel();
    _idleTimer = null;
    _sweepTimer?.cancel();
    _sweepTimer = null;
    scheduler.dispose();
    _artifactWarmer?.dispose();
    _dayPublisher.dispose();
    insightsRevision.dispose();
    _recalc.dispose();
  }

  /// Compute trigger: kick the DerivationEngine after data is persisted.
  /// [heavy]=false is the bounded light pass (TODAY when raw has reached today,
  /// else the latest pending day); [heavy]=true is the foreground finalize
  /// sweep. Best-effort + non-blocking — never throws into the BLE path.
  /// Refreshes the UI when results land so screens re-read the fresh derived rows.
  ///
  /// A manual sync runs this with [changedOnly]: the derive covers only days
  /// whose input changed since they were last derived ([onScope] hears how
  /// many, [onDay] hears each one finish), and a pass that found nothing to do
  /// returns before the post-derive work, none of which has anything new to act
  /// on. The automatic light pass (see [_runScheduled]) runs this way too.
  ///
  /// Returns how the DERIVE ended (never throws): a failure before the derive
  /// reported is `failed`; one in the post-derive work after it is only logged,
  /// since re-running the derive would not repair it.
  Future<DeriveOutcome> afterDrain({
    bool heavy = false,
    bool changedOnly = false,
    bool automatic = false,
    void Function(int total)? onScope,
    void Function(String day, int index, int total)? onDay,
  }) async {
    final mode = heavy ? 'heavy' : 'light';
    final recalcId = ++_recalcSeq;
    DeriveOutcome? outcome;
    // The days this pass reported done, in order: what the artifact warmer
    // re-signs once the pass has been published.
    final computedDays = <String>[];
    try {
      // Context for whatever crash/ANR report comes next — the derivation
      // engine's heavy per-day compute is isolate-offloaded, but the
      // assembly/UI-refresh wiring around it still runs on the main isolate,
      // so this is real signal if a freeze/ANR correlates with a derive pass.
      TelemetryService.instance.setContext('derive_mode', mode);
      TelemetryService.instance.setContext('derive_active', true);
      TelemetryService.instance.breadcrumb('derive: $mode start');
      // Refresh the UI after EACH day so Today/trends fill in as the sweep runs,
      // not only at the end (a multi-day backfill can be many days of work).
      var scopeTotal = -1;
      outcome = await TelemetryService.instance.traced<DeriveOutcome>('derive_$mode', () => _deriveRun(
        heavy: heavy,
        changedOnly: changedOnly,
        onScope: (total) {
          scopeTotal = total;
          onScope?.call(total);
        },
        onScopeDays: (days) => _recalcScope(recalcId, days),
        onCrossDay: (active) => _recalcCrossDay(recalcId, active),
        onDayDone: (day, index, total) async {
          // The day's row is committed: it is no longer "recalculating", and
          // Home / Health can re-read it now rather than after the pass.
          _recalcDayDone(recalcId, day);
          _dayPublisher.request();
          computedDays.add(day);
          onDay?.call(day, index, total);
          if (index == total || index == 1 || index % 3 == 0) {
            _notify();
          }
        },
      ));
      TelemetryService.instance.breadcrumb('derive: $mode done');
      if (changedOnly && scopeTotal == 0 && _derive.snapshot()['last_error'] == null) {
        _log('[derive] $mode: nothing changed since the last derive');
        // An automatic pass follows a drain that DID land rows, possibly a
        // workout window on a day that is already finalized (so not in scope).
        // The cheap session rescore still runs; screens only re-read if it
        // changed something.
        if (automatic) {
          unawaited(_refreshPhoneStepsToday());
          try {
            final fixed = await _repo()?.rescoreRecentSessions() ?? 0;
            if (fixed > 0) {
              _log('[derive] rescored $fixed session(s) from substrate');
              bumpInsights();
              _notify();
            }
          } catch (e) {
            _log('[derive] session rescore failed: $e');
          }
        }
        return outcome;
      }
      // A drain can bank band coverage and a day can have rolled over since the
      // last read — both change which source owns today's steps.
      unawaited(_refreshPhoneStepsToday());
      // The drain that triggered this pass may have landed the 1 Hz window of a
      // workout the app slept through, whose strain/calories were scored from
      // whatever few minutes the foreground tally saw (issue #206). Re-score
      // recent sessions against the substrate now that it is here, so the
      // workout LIST is corrected too and not just a detail screen someone
      // happens to open. Monotone and idempotent — see reconcileSessionScore.
      try {
        final fixed = await _repo()?.rescoreRecentSessions() ?? 0;
        if (fixed > 0) {
          _log('[derive] rescored $fixed session(s) from substrate');
        }
      } catch (e) {
        _log('[derive] session rescore failed: $e');
      }
      await LocalDb.refreshComputeFreshness();
      BundleStore.shared.invalidateAll();
      bumpInsights();
      _notify(); // screens re-fetch from the derived store
      // Warm the slow screen artifacts (journal insights, weekday effect, the
      // night's beats, workouts, circadian) in the background, AFTER the
      // publish: one serial warmer, off the UI isolate, never awaited here and
      // never throwing into the derive path. A pass that computed nothing has
      // nothing new to sign.
      if (outcome.computed >= 1 &&
          computedDays.isNotEmpty &&
          !_disposed &&
          _policy.mayWarmAfterPass(_power)) {
        unawaited(_warmer?.warmAfterPass(changedDays: computedDays));
      }
      // Same signal, for the surfaces that can't listen: home/lock-screen
      // widget, Watch mirror, Siri intents (WidgetService.refresh).
      unawaited(WidgetService.refresh(_repo()));
      // A heavy finalize is where a freshly-closed sleep window + recovery for a
      // new physiological day lands — fire the "recovery ready" push off it.
      if (heavy) {
        unawaited(_maybeNotifyRecoveryReady());
        // Baseline-dirty rescan: new data may have shifted the rolling baseline,
        // so refresh baseline-dependent scalars (readiness/illness/stress) on
        // recent FINALIZED days. Cheap when the baseline is unchanged (a single
        // signature read). Best-effort — never throws into the BLE path.
        unawaited(() async {
          final rescanId = ++_recalcSeq;
          try {
            final n = await _rescanRecent(
              onScopeDays: (days) => _recalcScope(rescanId, days),
              onDayDone: (day, index, total) {
                _recalcDayDone(rescanId, day);
                _dayPublisher.request();
              },
            );
            if (n > 0) {
              bumpInsights();
              _notify(); // screens re-read the refreshed scalars
            }
          } catch (e) {
            _log('[derive] rescan failed: $e');
          } finally {
            _recalcClear(rescanId);
          }
        }());
      }
      // Continuous health export: push freshly-derived days (incl. TODAY) to Apple
      // Health / Health Connect AS SOON as they're computed — runs on BOTH the
      // light (every drain) and heavy passes, not only on finalize. Idempotent
      // (delete-then-write), best-effort, never throws into the BLE/derive path.
      if (_healthSyncEnabled()) {
        unawaited(() async {
          try {
            final n = await _runHealthExport();
            if (n > 0) _log('[health] exported $n day(s)');
          } catch (e) {
            _log('[health] export failed: $e');
          }
        }());
      }
      // Companion (opt-in): flush any queued telemetry now that we're doing network
      // work anyway, and — on a heavy (finalize) pass — consider the once/day full
      // .db upload (itself gated on Wi-Fi + charging + >24h). Both best-effort.
      if (_telemetryConsent()) unawaited(TelemetryService.instance.flush());
      if (heavy && _healthShareConsent()) {
        unawaited(HealthUploader.instance.maybeUpload(consented: true));
      }
      if (heavy) unawaited(_maybeReclaimDiskSpace());
    } catch (e, st) {
      _log('[derive] post-drain failed: $e');
      // Was silently swallowed before — this is a real pipeline failure
      // (derive/health-export/etc.) that Firebase never saw. Non-fatal, not
      // fatal: the app keeps running, but this is worth knowing about.
      TelemetryService.instance.recordNonFatal(e, st, reason: 'post_drain_failed');
      outcome ??= DeriveOutcome(failed: true, error: '$e');
    } finally {
      // On every path (success, failure, cancel): a pass puts back
      // RecalcState.idle if it is the one that set the days.
      _recalcClear(recalcId);
      TelemetryService.instance.setContext('derive_active', false);
    }
    return outcome;
  }

  Future<DeriveOutcome> _deriveRun({
    required bool heavy,
    required bool changedOnly,
    void Function(int total)? onScope,
    void Function(List<String> days)? onScopeDays,
    void Function(String day, int index, int total)? onDayDone,
    void Function(bool active)? onCrossDay,
  }) async {
    final hook = debugDeriveRun;
    if (hook != null) {
      final n = await hook(
        heavy: heavy,
        changedOnly: changedOnly,
        onScope: onScope,
        onScopeDays: onScopeDays,
        onDayDone: onDayDone,
        onCrossDay: onCrossDay,
      );
      return DeriveOutcome(computed: n);
    }
    final calculationMode =
        await _calculationPolicy.select(heavy: heavy, forced: false);
    final n = await _derive.run(
      _profile,
      heavy: heavy,
      changedOnly: changedOnly,
      calculationMode: calculationMode,
      onScope: onScope,
      onScopeDays: onScopeDays,
      onDayDone: onDayDone,
      onCrossDay: onCrossDay,
    );
    // Read right after the run returns: the engine records how THIS call ended
    // (failed 'busy' when another pass held the lock).
    return _derive.lastOutcome ?? DeriveOutcome(computed: n);
  }

  Future<int> _rescanRecent({
    void Function(List<String> days)? onScopeDays,
    void Function(String day, int index, int total)? onDayDone,
  }) {
    final hook = debugRescanRecent;
    if (hook != null) return hook(onScopeDays: onScopeDays, onDayDone: onDayDone);
    return _derive.rescanRecent(_profile,
        onScopeDays: onScopeDays, onDayDone: onDayDone);
  }}
