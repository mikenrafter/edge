// snooze_controller.dart — the dismiss window, the pending snooze and the
// app-driven re-alarm loop. Everything is injected; nothing here can reach the
// band's native alarm (no arm, no disable: AGENTS 3.15, and arming is taxing).
//
// Pinned by test/alarm_snooze/snooze_controller_test.dart and, for the safety
// round (Sol's review, 2026-10-07), snooze_safety_controller_test.dart. The
// principle throughout: an alarm that fails to wake the wearer is the worst
// outcome, so when in doubt the controller re-alarms.
//
// Safety rules added by that round:
//   * the dismiss window is PERSISTED the moment it opens (and with every tap),
//     so a restart cannot forget it: [resume] restores an open window, snoozes
//     from the ORIGINAL stop time when it expired while the app was dead, and
//     re-alarms at once when that snooze is already due;
//   * a stop is timed by its own [onAlarmStopped] `at` (the strap's stamp), not
//     by when it was heard: a snooze is due `at + minutes`, and a stop heard
//     late whose snooze is already due re-alarms now;
//   * a stop while anything is pending (a window, a snooze, a re-alarm) is
//     ignored: another termination never resets or postpones a snooze;
//   * the re-alarm listens only once the band has TAKEN its pattern (the play's
//     `onFirstWrite`), measures its window from the delivery's end, and a tap
//     heard before that never counts; a delivery that fails keeps the snooze
//     pending and is retried;
//   * [consumesDoubleTaps] is false once a window's deadline has passed, even
//     if its timer or probe has not run, so an overdue window stops stealing
//     gestures.
//
// Round 3 (Sol's second review, 2026-10-07):
//   * persisted state AGES OUT: a window or snooze whose native fire is older
//     than [kSnoozeMaxAge], or is not the alarm occurrence the app knows
//     ([knownFire]), is dropped on [resume] with a log line, never re-alarmed;
//     a running chain ends the same way ([kSnoozeMaxAge] after its fire);
//   * tap identities are persisted with the window, so the same event delivered
//     again after a restart is not counted twice;
//   * [endSilently] ends everything with no cue (Cancel-all, unpair, the switch
//     turned off).
//
// Round 4 (Sol's third review, 2026-10-07):
//   * a snooze that would fall due at or past fire + [kSnoozeMaxAge] is not set:
//     the chain ends silently (nothing is scheduled beyond the bound);
//   * a wake confirmed while a re-alarm waits in the band queue ends the chain
//     (the tick's probe runs then too);
//   * a persisted snooze due at or past fire + [kSnoozeMaxAge] is dropped on
//     resume;
//   * [onRestoredChainOver]: a resume that finds the persisted chain over tells
//     the caller, which drops the OS backstop the dead process left.
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
///
/// [onFirstWrite] is called once, when the band has ACCEPTED the first command
/// of the delivery: the wearer starts to feel it. A play that completes true
/// without having called it is taken as accepted when it returns.
typedef SnoozeHapticPlay = Future<bool> Function(
  String slotKey, {
  List<PatternEntry>? notes,
  void Function()? onFirstWrite,
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
  _Listen(this.cause, this.start, this.window,
      {Iterable<DateTime>? taps, Iterable<String>? tapIds}) {
    if (taps != null) this.taps.addAll(taps);
    if (tapIds != null) this.tapIds.addAll(tapIds);
  }
  final AlarmStopCause cause;

  /// A native stop: when the alarm stopped. A re-alarm: when the band took it.
  final DateTime start;
  final Duration window;
  final List<DateTime> taps = [];

  /// The identities of the taps counted so far (one event is one tap).
  final List<String> tapIds = [];

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
    this.knownFire,
    this.onRestoredChainOver,
  });

  final DateTime Function() now;
  final SnoozeHapticPlay play;

  /// The double wake confirmation exists for THIS alarm's sleep. The caller
  /// reads [fireAt] to know which alarm that is.
  final Future<bool> Function() confirmedWake;
  final SnoozeEvidence recordEvidence;
  final SnoozeStore store;
  final SnoozeSettings Function() settings;
  final SnoozeScheduler scheduler;
  final void Function(String line)? log;

  /// The native alarm occurrence the app currently knows (phone time), or null
  /// when it knows none. A persisted chain whose fire is a different
  /// occurrence is stale.
  final DateTime? Function()? knownFire;

  /// Called when [resume] found the persisted chain already over (answered by a
  /// wake confirmation, dismissed, or too old / another alarm's) and ended it
  /// without a status change: whatever the dead process left outside the
  /// store (the OS backstop notification) is the caller's to drop.
  final void Function()? onRestoredChainOver;

  final ValueNotifier<SnoozeStatus> _status =
      ValueNotifier<SnoozeStatus>(SnoozeStatus.idle);

  _Listen? _listen;
  SnoozeState? _state;
  SnoozeTimer? _windowTimer;
  SnoozeTimer? _snoozeTimer;
  bool _disposed = false;

  /// The native fire stamp of the chain in progress (null: none).
  DateTime? _fireAt;

  /// True while a native-window record sits in the store (only to skip a
  /// pointless clearing write).
  bool _windowStored = false;

  // Every transition bumps this; an await that resumes under another value
  // finds its work superseded (dismissed, cancelled, disposed) and stops. It is
  // the main guard: no flag is ever held across an await, so nothing can stay
  // set after a failure.
  int _gen = 0;

  /// The generation a re-alarm delivery is in flight under, so a tick does not
  /// start a second one. A transition (bumping [_gen]) makes it stale by
  /// itself; a failed delivery clears it.
  int? _startingGen;

  bool _alive(int g) => !_disposed && g == _gen;

  void _log(String line) => log?.call('[snooze] $line');

  /// What Home shows. Not idle while a window, a snooze or a re-alarm is live.
  ValueListenable<SnoozeStatus> get status => _status;

  /// The native alarm's fire stamp the current chain answers, or null.
  DateTime? get fireAt => _fireAt;

  /// A band double tap belongs to the dismiss window or the re-alarm right
  /// now, so the wearer's gesture actions must not run for it. False once the
  /// window's deadline has passed, whether or not its timer has run.
  bool get consumesDoubleTaps {
    final l = _listen;
    return !_disposed && l != null && !_overdue(l);
  }

  /// A window's deadline: [AlarmStopPolicy.window] after the stop, or after the
  /// re-alarm's delivery ended (still open while it is being delivered).
  bool _overdue(_Listen l) {
    if (l.reAlarm) {
      final d = l.deliveredAt;
      return d != null && now().isAfter(d.add(l.window));
    }
    return now().isAfter(l.start.add(l.window));
  }

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

  Future<bool> _play(String slot,
      {List<PatternEntry>? notes, void Function()? onFirstWrite}) async {
    try {
      return await play(slot, notes: notes, onFirstWrite: onFirstWrite);
    } catch (e) {
      _log('playing $slot failed: $e');
      return false;
    }
  }

  /// A cue (snooze set, dismissed, cancelled) is not waited for: the state has
  /// already changed, and a cue held back by the command budget (it is a plain
  /// job) must not stall the keep-alive tick or whatever called. A re-alarm is
  /// awaited ([_startReAlarm]): its result matters.
  void _cue(String slot) {
    unawaited(_play(slot));
  }

  Future<void> _save(SnoozeState? s) async {
    try {
      await store.saveState(s);
    } catch (e) {
      _log('saving the snooze state failed: $e');
    }
  }

  Future<void> _saveWindow(SnoozeWindow? w) async {
    try {
      await store.saveWindow(w);
    } catch (e) {
      _log('saving the dismiss window failed: $e');
    }
    _windowStored = w != null;
  }

  Future<void> _clearWindow() async {
    if (_windowStored) await _saveWindow(null);
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
    // A re-alarm listens from the first accepted write; until its delivery
    // finishes the window cannot end.
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

  /// The native wake alarm stopped for [cause], at [at] (the strap's own time
  /// of the stop; default now), answering the native fire stamped [fire].
  ///
  /// Ignored while a window, a snooze or a re-alarm is already pending: one
  /// stop starts a chain, and another termination (our own playback ending,
  /// a stray one) must never reset or postpone it.
  Future<void> onAlarmStopped(AlarmStopCause cause,
      {DateTime? at, DateTime? fire}) async {
    if (_disposed) return;
    if (cause == AlarmStopCause.error || cause == AlarmStopCause.reAlarm) {
      _log('the alarm stopped with an error; no snooze.');
      return;
    }
    if (_listen != null || _state != null || _startingGen == _gen) {
      _log('a stop while a window, a snooze or a re-alarm is pending: '
          'ignored, the pending one is never reset.');
      return;
    }
    final t = at ?? now();
    _fireAt = fire ?? t;
    final g = ++_gen;
    _cancelTimers();
    final window = settings().window;
    if (cause == AlarmStopCause.userDoubleTap) {
      // Open before the probe so taps are consumed from the first moment, and
      // persist it before anything can die: the native alarm is stopped, so
      // nothing but this window will ever wake the wearer again.
      _listen = _Listen(cause, t, window);
      _publish();
      await _saveWindow(SnoozeWindow(stoppedAt: t, fireAt: _fireAt));
      if (!_alive(g)) return;
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
    await _apply(d, l, at: t, anchor: t);
    if (_alive(g) && _listen == l && l != null && _windowTimer == null) {
      final left = t.add(window).difference(now());
      _windowTimer = scheduler(left.isNegative ? Duration.zero : left,
          () => _fire(() => _evaluate(l)));
    }
  }

  // ── taps ──────────────────────────────────────────────────────────────────

  /// A band double tap (gesture event 14) at [at], its own time; only
  /// meaningful while [consumesDoubleTaps]. A tap before the window opened, or
  /// after its deadline, never counts.
  ///
  /// [identity] is the event's own identity: the same one again is not another
  /// tap (also across a restart: it is persisted with the window).
  Future<void> onBandDoubleTap(DateTime tapAt, {String? identity}) async {
    final l = _listen;
    if (_disposed || l == null) return;
    // A strap clock a little ahead of the phone's cannot make a tap that has
    // just been heard lie in the future (the policy would not count it yet).
    final at = tapAt.isAfter(now()) ? now() : tapAt;
    if (_overdue(l)) {
      _log('double tap after the window ended: not counted.');
      return;
    }
    if (at.isBefore(l.start)) {
      _log('double tap before the window opened: not counted.');
      return;
    }
    if (!l.reAlarm) {
      final since = at.difference(l.start);
      if (since < kStopTapDedupe) {
        _log('double tap ${since.inMilliseconds} ms after the stop: that '
            'stop\'s own tap, not another.');
        return;
      }
    }
    if (identity != null) {
      if (l.tapIds.contains(identity)) {
        _log('the same double tap delivered again: counted once.');
        return;
      }
      l.tapIds.add(identity);
    }
    l.taps.add(at);
    if (!l.reAlarm) {
      await _saveWindow(SnoozeWindow(
          stoppedAt: l.start,
          fireAt: _fireAt,
          taps: l.taps,
          tapIds: l.tapIds));
    }
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
    await _apply(d, l,
        at: l.taps.isEmpty ? now() : l.taps.last,
        // A native window snoozes from the stop; a re-alarm that went
        // unanswered snoozes again from now.
        anchor: l.reAlarm ? now() : l.start);
  }

  Future<void> _apply(AlarmStopDecision d, _Listen? l,
      {required DateTime at, required DateTime anchor}) async {
    switch (d) {
      case AlarmStopDecision.pending:
        return;
      case AlarmStopDecision.error:
        return;
      case AlarmStopDecision.dismissed:
        await _dismiss(at);
      case AlarmStopDecision.snooze:
        await _setSnooze(anchor);
      case AlarmStopDecision.confirmedAwake:
        if (l != null && l.reAlarm) {
          await _cancelSnooze();
        } else {
          // Already up: nothing to buzz, nothing to snooze.
          _gen++;
          _cancelTimers();
          _listen = null;
          _fireAt = null;
          _publish();
          final had = _state != null;
          _state = null;
          if (had) await _save(null);
          await _clearWindow();
        }
    }
  }

  /// Ends everything: the wearer is dismissing the alarm.
  Future<void> _dismiss(DateTime at) async {
    final g = ++_gen;
    _cancelTimers();
    _listen = null;
    _fireAt = null;
    final hadState = _state != null;
    _state = null;
    _publish();
    if (hadState) await _save(null);
    await _clearWindow();
    await _evidence(at);
    if (!_alive(g)) return;
    _cue(kAlarmDismissConfirmKey);
  }

  /// A wake was confirmed while a snooze or re-alarm was pending.
  Future<void> _cancelSnooze() async {
    final g = ++_gen;
    _cancelTimers();
    _listen = null;
    _fireAt = null;
    _state = null;
    _publish();
    await _save(null);
    await _clearWindow();
    if (!_alive(g)) return;
    _cue(kAlarmSnoozeCancelledKey);
  }

  /// Sets the next snooze: count + 1, due [SnoozeSettings.snoozeFor] after
  /// [anchor] (the native stop's own time for the first one). Already due (a
  /// stop heard late, a restart long after): the re-alarm plays now instead.
  Future<void> _setSnooze(DateTime anchor) async {
    final g = ++_gen;
    _cancelTimers();
    _listen = null;
    final s = settings();
    final fire = _fireAt;
    if (fire != null &&
        !anchor.add(s.snoozeFor).isBefore(fire.add(kSnoozeMaxAge))) {
      // Nothing may be scheduled (a timer, a stored due time, an OS
      // notification) at or past the bound: the chain ends here.
      _log('the next snooze would fall due $kSnoozeMaxAge or more after the '
          'alarm fired: the chain ends.');
      await endSilently();
      return;
    }
    final st = SnoozeState(
        count: (_state?.count ?? 0) + 1,
        reAlarmAt: anchor.add(s.snoozeFor),
        fireAt: _fireAt);
    _state = st;
    _publish();
    final left = st.reAlarmAt.difference(now());
    final due = left <= Duration.zero;
    if (!due) _snoozeTimer = scheduler(left, () => _fire(_snoozedStep));
    await _save(st);
    await _clearWindow();
    if (!_alive(g)) return;
    if (due) {
      _log('the snooze is already due: re-alarming now.');
      await _startReAlarm(st);
      return;
    }
    _cue(kAlarmSnoozeConfirmKey);
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
    // A re-alarm already on its way (waiting in the band queue) is not started
    // twice, but a wake confirmed meanwhile still ends the chain: that bumps
    // the generation, and the queued re-alarm is dropped.
    final starting = _startingGen == _gen;
    final g = _gen;
    final confirmed = await _probe();
    if (!_alive(g) || _listen != null || _state != st) return;
    if (confirmed) {
      await _cancelSnooze();
      return;
    }
    if (starting || now().isBefore(st.reAlarmAt)) return;
    await _startReAlarm(st);
  }

  /// True once the chain's native fire is older than [kSnoozeMaxAge]: nothing
  /// has answered it for hours, and a re-alarm now would be a phantom.
  bool _chainExpired() {
    final f = _fireAt;
    return f != null && now().difference(f) > kSnoozeMaxAge;
  }

  Future<void> _startReAlarm(SnoozeState st) async {
    if (_chainExpired()) {
      _log('the chain is older than $kSnoozeMaxAge: ended, no re-alarm.');
      await endSilently();
      return;
    }
    final g = ++_gen;
    _startingGen = g;
    _snoozeTimer?.cancel();
    _snoozeTimer = null;
    _listen = null;
    final s = settings();
    _Listen? l;
    // Listening opens only when the band has taken the pattern: until then the
    // wearer has felt nothing, so no tap is a dismissal and no gesture is ours.
    void accepted() {
      if (!_alive(g) || l != null) return;
      final open = l = _Listen(AlarmStopCause.reAlarm, now(), s.window);
      _listen = open;
      _publish();
    }

    final notes = SnoozeSchedule(cap: s.cap).reAlarmNotes(st.count);
    final delivered =
        await _play(kAlarmReAlarmKey, notes: notes, onFirstWrite: accepted);
    if (!_alive(g)) return;
    if (!delivered) {
      // Not counted: still due, retried at the next tick.
      if (l != null && _listen == l) {
        _listen = null;
        _publish();
      }
      _startingGen = null;
      _log('re-alarm ${st.count} was not delivered; will retry.');
      return;
    }
    accepted();
    final done = l!;
    _startingGen = null;
    // The window runs from the delivery's end.
    done.deliveredAt = now();
    _windowTimer = scheduler(s.window, () => _fire(() => _evaluate(done)));
    await _evaluate(done);
  }

  /// Ends a window, a snooze or a re-alarm with no cue and no evidence (the
  /// wearer cancelled the alarm, unpaired, or switched snooze off): timers
  /// cancelled, the stored state and window cleared.
  Future<void> endSilently() async {
    if (_disposed) return;
    ++_gen;
    _cancelTimers();
    _listen = null;
    _startingGen = null;
    _fireAt = null;
    final had = _state != null;
    _state = null;
    _publish();
    if (had) await _save(null);
    await _clearWindow();
  }

  /// "I'm up": dismisses a window, a snooze or a re-alarm.
  Future<void> imUp() async {
    if (_disposed) return;
    if (_listen == null && _state == null) return;
    await _dismiss(now());
  }

  /// Load what was pending after a restart: a snooze, or a dismiss window that
  /// was open.
  Future<void> resume() async {
    if (_disposed) return;
    final g = _gen;
    SnoozeState? st;
    SnoozeWindow? w;
    try {
      st = await store.loadState();
      w = await store.loadWindow();
    } catch (e) {
      _log('loading the snooze state failed: $e');
    }
    if (!_alive(g) || _listen != null || _state != null) return;
    // What was persisted must still be this alarm's: a fire older than
    // [kSnoozeMaxAge], or not the occurrence the app knows, is dropped (cleared,
    // logged, never re-alarmed). A phantom alarm days later is the second worst
    // outcome after one that does not wake.
    final ref = st != null
        ? (st.fireAt ?? st.reAlarmAt)
        : (w != null ? (w.fireAt ?? w.stoppedAt) : null);
    final persistedFire = st != null ? st.fireAt : w?.fireAt;
    // A snooze due at or past the bound (an older build could write one) is
    // over, whatever the clock says now.
    final pastBound = st != null &&
        st.fireAt != null &&
        !st.reAlarmAt.isBefore(st.fireAt!.add(kSnoozeMaxAge));
    if (ref != null &&
        (_tooOld(ref) || pastBound || _notKnownFire(persistedFire))) {
      _log('dropped a stale ${st != null ? 'snooze' : 'dismiss window'} '
          '(fire ${(persistedFire ?? ref).toIso8601String()}): too old, or not '
          'the alarm known now.');
      if (st != null) await _save(null);
      if (w != null) {
        _windowStored = true;
        await _saveWindow(null);
      }
      _restoredChainOver();
      return;
    }
    if (st == null) {
      if (w != null) await _resumeWindow(w, g);
      return;
    }
    if (w != null) await _saveWindow(null); // the snooze is the later fact
    _state = st;
    _fireAt = st.fireAt;
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

  void _restoredChainOver() {
    try {
      onRestoredChainOver?.call();
    } catch (e) {
      _log('dropping what the dead process left failed: $e');
    }
  }

  bool _tooOld(DateTime ref) => now().difference(ref) > kSnoozeMaxAge;

  bool _notKnownFire(DateTime? persisted) {
    final known = knownFire?.call();
    return persisted != null &&
        known != null &&
        persisted.difference(known).abs() > kSnoozeFireMatch;
  }

  /// The dismiss window was open when the process died. The native alarm is
  /// already stopped, so this is the only thing left that can wake the wearer:
  /// restore it while it is open, count what was heard, and when it ended while
  /// we were dead decide as it would have (snooze from the ORIGINAL stop; if
  /// that is already due, re-alarm now).
  Future<void> _resumeWindow(SnoozeWindow w, int g) async {
    _fireAt = w.fireAt ?? w.stoppedAt;
    _windowStored = true;
    if (await _probe()) {
      if (!_alive(g)) return;
      _fireAt = null;
      await _saveWindow(null);
      _restoredChainOver();
      return;
    }
    if (!_alive(g) || _listen != null || _state != null) return;
    final window = settings().window;
    final d = AlarmStopPolicy(
            requiredTaps: settings().requiredTaps, window: window)
        .decide(
      cause: AlarmStopCause.userDoubleTap,
      stoppedAt: w.stoppedAt,
      taps: w.taps,
      confirmedWake: false,
      now: now(),
    );
    switch (d) {
      case AlarmStopDecision.dismissed:
        await _dismiss(w.taps.isEmpty ? now() : w.taps.last);
        _restoredChainOver();
      case AlarmStopDecision.snooze:
      case AlarmStopDecision.confirmedAwake:
      case AlarmStopDecision.error:
        await _setSnooze(w.stoppedAt);
      case AlarmStopDecision.pending:
        final l = _Listen(AlarmStopCause.userDoubleTap, w.stoppedAt, window,
            taps: w.taps, tapIds: w.tapIds);
        _listen = l;
        _publish();
        _windowTimer = scheduler(w.stoppedAt.add(window).difference(now()),
            () => _fire(() => _evaluate(l)));
    }
  }

  /// Cancels every timer. The persisted snooze and window stay, so the next
  /// launch resumes them. Nothing runs or plays afterwards.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _gen++;
    _cancelTimers();
    _listen = null;
  }
}
