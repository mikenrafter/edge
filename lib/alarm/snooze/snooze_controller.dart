// snooze_controller.dart — the dismiss window, the pending snooze and the
// app-driven re-alarm loop. Everything is injected; nothing here can reach the
// band's native alarm (no arm, no disable: AGENTS 3.15, and arming is taxing).
//
// Pinned by test/alarm_snooze/snooze_controller_test.dart.
//
// Behaviour:
//   [onAlarmStopped]  the native wake alarm stopped. error: log only. Probe
//                     [confirmedWake] (a probe that throws reads "not
//                     confirmed": the wearer is woken, never assumed up);
//                     confirmed: nothing more. userDoubleTap with
//                     requiredTaps == 1: dismissed at once. userDoubleTap
//                     otherwise opens the window (the stopping tap is #1).
//                     expired: snooze at once.
//   [onBandDoubleTap] a band double tap while [consumesDoubleTaps]. The n-th
//                     tap dismisses early: alarm_acknowledged evidence + the
//                     alarm.dismiss.confirm slot. A tap within
//                     [kStopTapDedupe] after a native stop is that stop's own
//                     tap echoed as a gesture event, not tap #2.
//   snooze            plays alarm.snooze.confirm, persists
//                     SnoozeState(count, now + minutes), publishes [status].
//   [tick]            the 30 s keep-alive: closes a window that ended, checks
//                     [confirmedWake] (confirmed during a snooze cancels it and
//                     plays alarm.snooze.cancelled), and plays a due re-alarm.
//                     A one-shot timer from [scheduler] does the same on time
//                     while the process is alive; tick is the backstop.
//   re-alarm          plays alarm.snooze.realarm with
//                     SnoozeSchedule(cap).reAlarmNotes(count); listening window
//                     from the pattern's start until [settings.window] after it
//                     finished. n taps dismiss; fewer snoozes again (count+1,
//                     now + minutes). A failed delivery does not count: the
//                     re-alarm stays due and is retried next tick. Past the cap
//                     it keeps going every interval, unescalated, until
//                     dismissed or a wake is confirmed.
//   [resume]          reads the store after a restart; a re-alarm however late
//                     still plays (it is an alarm).
//   [dispose]         cancels every timer; nothing runs or plays afterwards,
//                     including a probe or delivery that finishes late.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../gestures/pattern_transcript.dart';
import '../../haptics/builtin_patterns.dart';
import '../../wake/wake_confirmation.dart';
import 'alarm_stop_policy.dart';
import 'snooze_schedule.dart';
import 'snooze_settings.dart';

/// Plays haptic slot [slotKey] through the shared band queue. The re-alarm
/// carries its notes (they grow per snooze); the fixed slots play their stored
/// or default pattern. True when the band took it.
typedef SnoozeHapticPlay = Future<bool> Function(
  String slotKey, {
  List<PatternEntry>? notes,
});

typedef SnoozeEvidence = Future<void> Function(
    WakeEvidenceKind kind, DateTime at);

abstract interface class SnoozeTimer {
  void cancel();
}

/// A one-shot timer; the default is dart:async's.
typedef SnoozeScheduler = SnoozeTimer Function(
    Duration after, void Function() fire);

class _RealTimer implements SnoozeTimer {
  _RealTimer(Duration after, void Function() fire)
      : _t = Timer(after, fire);
  final Timer _t;
  @override
  void cancel() => _t.cancel();
}

SnoozeTimer defaultSnoozeScheduler(Duration after, void Function() fire) =>
    _RealTimer(after, fire);

/// A band double tap within this long after a native stop is that stop's own
/// tap echoed as a gesture event, and does not count as another.
const Duration kStopTapDedupe = Duration(milliseconds: 750);

enum SnoozePhase { idle, window, snoozed, reAlarming }

class SnoozeStatus {
  const SnoozeStatus(this.phase, {this.until, this.snoozeCount = 0});
  static const SnoozeStatus idle = SnoozeStatus(SnoozePhase.idle);

  final SnoozePhase phase;

  /// While snoozed: when the re-alarm is due.
  final DateTime? until;

  /// Snoozes set so far in this chain.
  final int snoozeCount;

  @override
  bool operator ==(Object other) =>
      other is SnoozeStatus &&
      other.phase == phase &&
      other.until == until &&
      other.snoozeCount == snoozeCount;

  @override
  int get hashCode => Object.hash(phase, until, snoozeCount);
}

/// One open listening period for double taps: the dismiss window after a
/// native stop, or the re-alarm.
class _Listen {
  _Listen(this.cause, this.start, this.window);
  final AlarmStopCause cause;
  final DateTime start;
  final Duration window;
  final List<DateTime> taps = [];

  /// Re-alarm only: when its delivery finished (the window runs from there).
  DateTime? deliveredAt;

  bool get reAlarm => cause == AlarmStopCause.reAlarm;
}

class SnoozeController {
  SnoozeController({
    required this.now,
    required this.play,
    required this.confirmedWake,
    required this.recordEvidence,
    required this.store,
    required this.settings,
    this.scheduler = defaultSnoozeScheduler,
    this.log,
  });

  final DateTime Function() now;
  final SnoozeHapticPlay play;

  /// The double wake confirmation exists for the current sleep block.
  final Future<bool> Function() confirmedWake;
  final SnoozeEvidence recordEvidence;
  final SnoozeStore store;
  final SnoozeSettings Function() settings;
  final SnoozeScheduler scheduler;
  final void Function(String line)? log;

  final ValueNotifier<SnoozeStatus> _status =
      ValueNotifier<SnoozeStatus>(SnoozeStatus.idle);

  _Listen? _listen;
  SnoozeState? _state;
  SnoozeTimer? _windowTimer;
  SnoozeTimer? _snoozeTimer;
  bool _disposed = false;

  // Every transition bumps this; an await that resumes under another value
  // finds its work superseded (dismissed, cancelled, disposed) and stops. It is
  // the only guard: no flag is ever held across an await, so nothing can stay
  // set after a failure.
  int _gen = 0;

  bool _alive(int g) => !_disposed && g == _gen;

  void _log(String line) => log?.call('[snooze] $line');

  /// What Home shows. Not idle while a window, a snooze or a re-alarm is live.
  ValueListenable<SnoozeStatus> get status => _status;

  /// A band double tap belongs to the dismiss window or the re-alarm right
  /// now, so the wearer's gesture actions must not run for it.
  bool get consumesDoubleTaps => !_disposed && _listen != null;

  // ── helpers that never throw ───────────────────────────────────────────────

  Future<bool> _probe() async {
    try {
      return await confirmedWake();
    } catch (e) {
      // Not knowing is not a confirmation: the wearer is woken.
      _log('confirmed-wake probe failed ($e); treating as not confirmed.');
      return false;
    }
  }

  Future<bool> _play(String slot, {List<PatternEntry>? notes}) async {
    try {
      return await play(slot, notes: notes);
    } catch (e) {
      _log('playing $slot failed: $e');
      return false;
    }
  }

  Future<void> _save(SnoozeState? s) async {
    try {
      await store.saveState(s);
    } catch (e) {
      _log('saving the snooze state failed: $e');
    }
  }

  Future<void> _evidence(DateTime at) async {
    try {
      await recordEvidence(WakeEvidenceKind.alarmAcknowledged, at);
    } catch (e) {
      _log('noting the acknowledgement failed: $e');
    }
  }

  void _cancelTimers() {
    _windowTimer?.cancel();
    _windowTimer = null;
    _snoozeTimer?.cancel();
    _snoozeTimer = null;
  }

  void _fire(Future<void> Function() f) {
    f().catchError((Object e) => _log('timer work failed: $e'));
  }

  AlarmStopPolicy _policy(_Listen l) {
    // A re-alarm listens from its start; until its delivery finishes the
    // window cannot end.
    final Duration w;
    if (l.reAlarm) {
      final done = l.deliveredAt;
      w = done == null
          ? now().difference(l.start) + const Duration(days: 1)
          : done.difference(l.start) + l.window;
    } else {
      w = l.window;
    }
    return AlarmStopPolicy(requiredTaps: settings().requiredTaps, window: w);
  }

  void _publish() {
    final l = _listen, st = _state;
    if (l != null && !l.reAlarm) {
      _status.value = SnoozeStatus(SnoozePhase.window,
          snoozeCount: st?.count ?? 0);
    } else if (l != null) {
      _status.value = SnoozeStatus(SnoozePhase.reAlarming,
          until: st?.reAlarmAt, snoozeCount: st?.count ?? 0);
    } else if (st != null) {
      _status.value = SnoozeStatus(SnoozePhase.snoozed,
          until: st.reAlarmAt, snoozeCount: st.count);
    } else {
      _status.value = SnoozeStatus.idle;
    }
  }

  // ── the native alarm stopped ──────────────────────────────────────────────

  /// The native wake alarm stopped for [cause], at [at] (default now).
  Future<void> onAlarmStopped(AlarmStopCause cause, {DateTime? at}) async {
    if (_disposed) return;
    if (cause == AlarmStopCause.error || cause == AlarmStopCause.reAlarm) {
      _log('the alarm stopped with an error; no snooze.');
      return;
    }
    final t = at ?? now();
    // A new stop supersedes whatever was pending.
    final g = ++_gen;
    _cancelTimers();
    _listen = null;
    final hadState = _state != null;
    _state = null;
    if (hadState) await _save(null);
    if (!_alive(g)) return;
    final window = settings().window;
    if (cause == AlarmStopCause.userDoubleTap) {
      // Open before the probe so taps are consumed from the first moment.
      _listen = _Listen(cause, t, window);
      _publish();
    }
    final confirmed = await _probe();
    if (!_alive(g)) return;
    final l = _listen;
    final d = AlarmStopPolicy(
            requiredTaps: settings().requiredTaps, window: window)
        .decide(
      cause: cause,
      stoppedAt: t,
      taps: l?.taps ?? const [],
      confirmedWake: confirmed,
      now: now(),
    );
    await _apply(d, l, t, g);
    if (_alive(g) && _listen == l && l != null && _windowTimer == null) {
      final left = t.add(window).difference(now());
      _windowTimer = scheduler(left.isNegative ? Duration.zero : left,
          () => _fire(() => _evaluate(l)));
    }
  }

  // ── taps ──────────────────────────────────────────────────────────────────

  /// A band double tap (gesture event 14) at [at]; only meaningful while
  /// [consumesDoubleTaps].
  Future<void> onBandDoubleTap(DateTime at) async {
    final l = _listen;
    if (_disposed || l == null) return;
    if (!l.reAlarm) {
      final since = at.difference(l.start);
      if (!since.isNegative && since < kStopTapDedupe) {
        _log('double tap ${since.inMilliseconds} ms after the stop: that '
            'stop\'s own tap, not another.');
        return;
      }
    }
    l.taps.add(at);
    await _evaluate(l);
  }

  // ── deciding ──────────────────────────────────────────────────────────────

  Future<void> _evaluate(_Listen l) async {
    if (_listen != l) return;
    final g = _gen;
    final confirmed = await _probe();
    if (!_alive(g) || _listen != l) return;
    final d = _policy(l).decide(
      cause: l.cause,
      stoppedAt: l.start,
      taps: l.taps,
      confirmedWake: confirmed,
      now: now(),
    );
    await _apply(d, l, l.taps.isEmpty ? now() : l.taps.last, g);
  }

  Future<void> _apply(
      AlarmStopDecision d, _Listen? l, DateTime at, int g) async {
    switch (d) {
      case AlarmStopDecision.pending:
        return;
      case AlarmStopDecision.error:
        return;
      case AlarmStopDecision.dismissed:
        await _dismiss(at);
      case AlarmStopDecision.snooze:
        await _setSnooze();
      case AlarmStopDecision.confirmedAwake:
        if (l != null && l.reAlarm) {
          await _cancelSnooze();
        } else {
          // Already up: nothing to buzz, nothing to snooze.
          _gen++;
          _cancelTimers();
          _listen = null;
          _publish();
          if (_state != null) {
            _state = null;
            await _save(null);
          }
        }
    }
  }

  /// Ends everything: the wearer is dismissing the alarm.
  Future<void> _dismiss(DateTime at) async {
    final g = ++_gen;
    _cancelTimers();
    _listen = null;
    final hadState = _state != null;
    _state = null;
    _publish();
    if (hadState) await _save(null);
    await _evidence(at);
    if (!_alive(g)) return;
    await _play(kAlarmDismissConfirmKey);
  }

  /// A wake was confirmed while a snooze or re-alarm was pending.
  Future<void> _cancelSnooze() async {
    final g = ++_gen;
    _cancelTimers();
    _listen = null;
    _state = null;
    _publish();
    await _save(null);
    if (!_alive(g)) return;
    await _play(kAlarmSnoozeCancelledKey);
  }

  /// Sets the next snooze: count + 1, due in the setting's minutes.
  Future<void> _setSnooze() async {
    final g = ++_gen;
    _cancelTimers();
    _listen = null;
    final s = settings();
    final st = SnoozeState(
        count: (_state?.count ?? 0) + 1,
        reAlarmAt: now().add(s.snoozeFor));
    _state = st;
    _publish();
    _snoozeTimer = scheduler(s.snoozeFor, () => _fire(_snoozedStep));
    await _save(st);
    if (!_alive(g)) return;
    await _play(kAlarmSnoozeConfirmKey);
  }

  // ── the keep-alive, the snooze and the re-alarm ───────────────────────────

  /// The keep-alive tick (every ~30 s) and the backstop for the timers.
  Future<void> tick() async {
    if (_disposed) return;
    final l = _listen;
    if (l != null) {
      await _evaluate(l);
    } else if (_state != null) {
      await _snoozedStep();
    }
  }

  /// A pending snooze: cancelled by a confirmed wake, otherwise its re-alarm
  /// once due.
  Future<void> _snoozedStep() async {
    if (_disposed || _listen != null) return;
    final st = _state;
    if (st == null) return;
    final g = _gen;
    final confirmed = await _probe();
    if (!_alive(g) || _listen != null || _state != st) return;
    if (confirmed) {
      await _cancelSnooze();
      return;
    }
    if (now().isBefore(st.reAlarmAt)) return;
    await _startReAlarm(st);
  }

  Future<void> _startReAlarm(SnoozeState st) async {
    final g = ++_gen;
    _snoozeTimer?.cancel();
    _snoozeTimer = null;
    final s = settings();
    final l = _Listen(AlarmStopCause.reAlarm, now(), s.window);
    _listen = l;
    _publish();
    final notes = SnoozeSchedule(cap: s.cap).reAlarmNotes(st.count);
    final delivered = await _play(kAlarmReAlarmKey, notes: notes);
    if (!_alive(g)) return;
    if (!delivered) {
      // Not counted: still due, retried at the next tick.
      _listen = null;
      _publish();
      _log('re-alarm ${st.count} was not delivered; will retry.');
      return;
    }
    l.deliveredAt = now();
    _windowTimer = scheduler(s.window, () => _fire(() => _evaluate(l)));
    await _evaluate(l);
  }

  /// "I'm up": dismisses a window, a snooze or a re-alarm.
  Future<void> imUp() async {
    if (_disposed) return;
    if (_listen == null && _state == null) return;
    await _dismiss(now());
  }

  /// Load a persisted snooze after a restart.
  Future<void> resume() async {
    if (_disposed) return;
    final g = _gen;
    SnoozeState? st;
    try {
      st = await store.loadState();
    } catch (e) {
      _log('loading the snooze state failed: $e');
    }
    if (!_alive(g) || st == null || _listen != null || _state != null) return;
    _state = st;
    _publish();
    if (await _probe()) {
      if (!_alive(g) || _state != st) return;
      await _cancelSnooze();
      return;
    }
    if (!_alive(g) || _state != st) return;
    final left = st.reAlarmAt.difference(now());
    _snoozeTimer?.cancel();
    _snoozeTimer = scheduler(
        left.isNegative ? Duration.zero : left, () => _fire(_snoozedStep));
  }

  /// Cancels every timer. The persisted snooze stays, so the next launch
  /// resumes it. Nothing runs or plays afterwards.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _gen++;
    _cancelTimers();
    _listen = null;
  }
}
