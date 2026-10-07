// breath_gesture.dart — the "Breathing exercise" gesture action.
//
// A band gesture starts a guided breathing session that runs on the band with
// the phone screen off, and the same gesture ends it. Nothing in the app drove
// phase cues without the CalmBreathing screen's ticker; [BreathPacer] is that
// screen-free driver: at every phase boundary of the slot's pattern it calls
// the session host's `buzzBreathPhase`, at the end `buzzSessionComplete`, then
// ends and banks the session through the host's `stopBreathingSession` (the
// existing >= 60 s rule applies).
//
// A breathing session is NOT a gesture: its cues are the normal breath cues
// (they skip when the band is busy). The gesture budget exemption covers only
// the gesture's own start.

import 'dart:async';

import '../stress/breath_phases.dart';
import 'gesture_settings.dart';

/// What the pacer needs from the breathing session: implemented by
/// `BreathingController`, and by a fake in the pacer's tests.
abstract interface class BreathPacerHost {
  bool get breathingActive;

  /// See `BreathingController.pacedByBand`.
  bool get pacedByBand;
  set pacedByBand(bool v);

  Future<void> startBreathingSession({BreathPattern? pattern, Duration? target});
  Future<void> stopBreathingSession();
  void buzzBreathPhase(BreathPhaseKind kind);
  void buzzSessionComplete();
}

/// Schedules [callback] once after [after]. Defaults to `Timer.new`.
typedef PacerTimer = Timer Function(Duration after, void Function() callback);

/// Drives one breathing session's cues without a screen.
///
/// Time is the injected clock: one timer waits for the next phase boundary (or
/// the end), and each wake-up reads the elapsed time, so a late wake-up cues
/// the phase it is in now rather than replaying the ones it slept through.
class BreathPacer {
  /// [now] and [timer] are injectable so a test owns time: [now] is read for
  /// elapsed time, [timer] is the ONLY way the pacer waits.
  BreathPacer(this.host, {DateTime Function()? now, PacerTimer? timer})
      : _now = now ?? DateTime.now,
        _timer = timer ?? Timer.new;

  final BreathPacerHost host;
  final DateTime Function() _now;
  final PacerTimer _timer;

  Timer? _wake;
  bool _running = false;
  bool _starting = false;

  /// Bumped by every way out, so a start still awaiting the host when one
  /// happens does not arm afterwards.
  int _generation = 0;
  late DateTime _startedAt;
  late Duration _total;
  List<({Duration at, BreathPhaseKind kind})> _cues = const [];
  int _next = 0;

  /// True from a successful [start] until the pacer ends (completion, [stop],
  /// [onDisconnect] or [dispose]).
  bool get running => _running;

  /// Start the host's session with [pattern] and [duration] as its target, set
  /// `host.pacedByBand`, and pace it. Completes once pacing is armed, not when
  /// the session ends. Throws (flag cleared) when the host throws or did not
  /// start a session, e.g. no band: the gesture is then reported as failed.
  Future<void> start(
      {required BreathPattern pattern, required Duration duration}) async {
    if (_running || _starting) return;
    _starting = true;
    final generation = _generation;
    host.pacedByBand = true;
    var armed = false;
    try {
      await host.startBreathingSession(pattern: pattern, target: duration);
      if (!host.breathingActive) {
        throw StateError('The breathing session did not start '
            '(is the band connected?)');
      }
      if (generation != _generation) return; // disposed or stopped meanwhile
      _total = duration;
      _cues = _boundaries(pattern, duration);
      _next = 0;
      _startedAt = _now();
      _running = true;
      armed = true;
      _tick();
    } finally {
      _starting = false;
      if (!armed) host.pacedByBand = false;
    }
  }

  /// End early: no further cue, no completion cue, `pacedByBand` cleared, the
  /// session banked (once) through the host. No-op when not running.
  Future<void> stop() async {
    if (!_running) return;
    _clear();
    await host.stopBreathingSession();
  }

  /// The band link dropped: end the pacing like [stop].
  Future<void> onDisconnect() => stop();

  /// Teardown: cancel the timer and clear the flag, with no cue. Does not end
  /// the host's session (same as `BreathingController.dispose`).
  void dispose() => _clear();

  // Every way out. Idempotent.
  void _clear() {
    _generation++;
    _wake?.cancel();
    _wake = null;
    _running = false;
    host.pacedByBand = false;
  }

  void _tick() {
    _wake = null;
    if (!_running) return;
    // Someone else (the screen, the Live Activity) ended the session.
    if (!host.breathingActive) return _clear();
    final elapsed = _now().difference(_startedAt);
    if (elapsed >= _total) {
      try {
        host.buzzSessionComplete();
      } catch (_) {/* a cue that cannot play must not keep the session open */}
      _clear();
      host.stopBreathingSession().catchError((_) {});
      return;
    }
    // The latest boundary that has passed is the phase to cue now.
    var due = -1;
    while (_next < _cues.length && _cues[_next].at <= elapsed) {
      due = _next++;
    }
    if (due >= 0) {
      try {
        host.buzzBreathPhase(_cues[due].kind);
      } catch (_) {/* best-effort, like the screen's cue */}
    }
    final nextAt = _next < _cues.length ? _cues[_next].at : _total;
    _wake = _timer(nextAt - elapsed, _tick);
  }

  /// Where each phase of [pattern] begins within [length], the first at 0.
  static List<({Duration at, BreathPhaseKind kind})> _boundaries(
      BreathPattern pattern, Duration length) {
    final out = <({Duration at, BreathPhaseKind kind})>[];
    var at = Duration.zero;
    while (at < length) {
      for (final p in pattern.phases) {
        if (at >= length) break;
        out.add((at: at, kind: p.kind));
        at += Duration(microseconds: (p.seconds * 1e6).round());
      }
    }
    return out;
  }
}

/// The gesture's toggle: reads the slot's own pattern and length from
/// [settings]; if no session is running starts one through [pacer], otherwise
/// ends it (a session started by ANY path, the screen included).
class BreathGesture {
  BreathGesture(
      {required this.settings, required this.pacer, required this.host});

  final GestureSettings settings;
  final BreathPacer pacer;
  final BreathPacerHost host;

  Future<void> onSlot(String slot) async {
    if (pacer.running) return pacer.stop();
    if (host.breathingActive) return host.stopBreathingSession();
    await pacer.start(
      pattern: kBreathPatternsByKey[settings.breathePatternFor(slot)]!,
      duration: Duration(minutes: settings.breatheMinutesFor(slot)),
    );
  }
}
