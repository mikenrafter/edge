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
//
// RED PHASE: every method below throws. Nothing is implemented yet.

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
class BreathPacer {
  /// [now] and [timer] are injectable so a test owns time: [now] is read for
  /// elapsed time, [timer] is the ONLY way the pacer waits.
  BreathPacer(this.host, {DateTime Function()? now, PacerTimer? timer});

  final BreathPacerHost host;

  /// True from a successful [start] until the pacer ends (completion, [stop],
  /// [onDisconnect] or [dispose]).
  bool get running => throw UnimplementedError('BreathPacer.running');

  /// Start the host's session with [pattern] and [duration] as its target, set
  /// `host.pacedByBand`, and pace it. Completes once pacing is armed, not when
  /// the session ends. If the host did not start a session (no band), nothing
  /// is armed and `pacedByBand` is left clear. Throws nothing the caller must
  /// clean up after: the flag is cleared in `finally`.
  Future<void> start({required BreathPattern pattern, required Duration duration}) =>
      throw UnimplementedError('BreathPacer.start');

  /// End early: no further cue, no completion cue, `pacedByBand` cleared, the
  /// session banked (once) through the host. No-op when not running.
  Future<void> stop() => throw UnimplementedError('BreathPacer.stop');

  /// The band link dropped: end the pacing like [stop] (cue-less, banked per
  /// the host's rules, flag cleared).
  Future<void> onDisconnect() => throw UnimplementedError('BreathPacer.onDisconnect');

  /// Teardown: cancel the timer and clear the flag, with no cue. Does not end
  /// the host's session (same as `BreathingController.dispose`).
  void dispose() => throw UnimplementedError('BreathPacer.dispose');
}

/// The gesture's toggle: reads the slot's own pattern and length from
/// [settings]; if no session is running starts one through [pacer], otherwise
/// ends it (a session started by ANY path, the screen included).
class BreathGesture {
  BreathGesture({required this.settings, required this.pacer, required this.host});

  final GestureSettings settings;
  final BreathPacer pacer;
  final BreathPacerHost host;

  Future<void> onSlot(String slot) => throw UnimplementedError('BreathGesture.onSlot');
}
