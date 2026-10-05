// A DoubleTapRepeatSession rig for the 8AK red tests (the plain double-tap
// route): every cue and every step logged, a small virtual band behind the
// cues. Test-only. Build it INSIDE fakeAsync (it reads the virtual clock).
//
// ASSUMED NEW DoubleTapRepeatSession PARAMETERS
// (lib/gestures/double_tap_repeat.dart):
//   * `Future<bool> Function(String eventId)? startBuzz`: the start cue, once,
//     when the first double tap opens the window; id `<gesture id>:rep:start`.
//   * `Future<bool> Function(String eventId)? confirmBuzz`: the confirm cue,
//     once, when the gesture ENDS COUNTED (the window ran out, or the max was
//     reached), queued behind any follow-up; id `<gesture id>:rep:confirm`. Not
//     called when the session is stopped early (`dispose`).
//   * `buzz` stays the FOLLOW-UP cue, one per further double tap, ids
//     `<gesture id>:rep:<n>` as today.
//   * `Future<void> Function()? bandIdle`: completes once the band has
//     finished playing everything queued so far (delivered AND plan ended).
//     With it, the pause window is armed only after the cue of the tap that
//     (re)opens it has been delivered and `bandIdle` completed, never from
//     the tap time. Bounded by `cueTimeout` (default 15 s): a cue that never
//     ends or never answers does not freeze the gesture. Without it (every
//     existing caller) the window is armed at the tap, as today.
//   * `Duration cueTimeout`.
// A session without them is built with the old parameters only, so the test
// fails on what it asserts (the cues and the window times), not at
// construction.

import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:openstrap_edge/gestures/double_tap_repeat.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';

final DateTime kRepT0 = DateTime.utc(2026, 10, 4, 2, 6, 20);
final int kRepT0Sec = kRepT0.millisecondsSinceEpoch ~/ 1000;

/// A live double tap [sec] seconds into the gesture, reaching the phone 300 ms
/// after the band made it.
StrapEvent repTap({int sec = 0, Duration late = const Duration(milliseconds: 300)}) {
  final ts = kRepT0Sec + sec;
  return StrapEvent(
    eventId: 14,
    tsEpoch: ts,
    receivedAt:
        DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true).add(late),
    hex: '',
    deviceId: 'band',
  );
}

class AkRepeatRig {
  AkRepeatRig({
    this.max = 5,
    this.windowMs = 2500,
    this.deliverMs = 0,
    this.planMs = 0,
    this.useBandIdle = false,
    this.startOk = true,
    this.startThrows = false,
    this.cueTimeout,
    this.manualIdle = false,
    this.startHangs = false,
  }) : _origin = clock.now() {
    final named = <Symbol, dynamic>{
      #maxTaps: () => max,
      #window: () => Duration(milliseconds: windowMs),
      #buzz: (String id) => _cue('follow', id),
      #step: steps.add,
      #onFinished: (int count) => finished.add(count),
    };
    final extras = <Symbol, dynamic>{
      #startBuzz: (String id) => _cue('start', id),
      #confirmBuzz: (String id) => _cue('confirm', id),
      if (useBandIdle) #bandIdle: _bandIdle,
      if (cueTimeout != null) #cueTimeout: cueTimeout,
    };
    try {
      session = Function.apply(
          DoubleTapRepeatSession.new, const [], {...named, ...extras})
          as DoubleTapRepeatSession;
    } on NoSuchMethodError {
      session = Function.apply(DoubleTapRepeatSession.new, const [], named)
          as DoubleTapRepeatSession;
    }
  }

  final int max, windowMs, deliverMs, planMs;
  final bool useBandIdle, startOk, startThrows, manualIdle, startHangs;
  final Duration? cueTimeout;
  final DateTime _origin;
  late final DoubleTapRepeatSession session;

  /// (name, id, ms the cue was requested), in the order they were asked for.
  final cues = <(String, String, int)>[];
  final steps = <String>[];
  final finished = <int>[];
  int? result;

  List<String> get names => [for (final c in cues) c.$1];
  int get nowMs => clock.now().difference(_origin).inMilliseconds;

  // The band plays one cue at a time: a cue starts when the one before has
  // ended. It is WRITTEN (the future completes) [deliverMs] after it starts
  // and ENDS [planMs] after that.
  int _busyUntil = 0;
  final List<Completer<void>> _manual = [];

  Future<bool> _cue(String name, String id) async {
    cues.add((name, id, nowMs));
    final startAt = math.max(nowMs, _busyUntil);
    final delivered = startAt + deliverMs;
    _busyUntil = delivered + planMs;
    if (delivered > nowMs) {
      await Future<void>.delayed(Duration(milliseconds: delivered - nowMs));
    }
    if (name == 'start' && startThrows) throw StateError('no band');
    if (name == 'start' && startHangs) return Completer<bool>().future;
    return name == 'start' ? startOk : true;
  }

  Future<void> _bandIdle() {
    if (manualIdle) {
      final c = Completer<void>();
      _manual.add(c);
      return c.future;
    }
    final wait = _busyUntil - nowMs;
    return wait > 0
        ? Future<void>.delayed(Duration(milliseconds: wait))
        : Future<void>.value();
  }

  /// With [manualIdle]: the band is idle now (every waiting `bandIdle`
  /// completes).
  void bandBecameIdle() {
    for (final c in _manual) {
      if (!c.isCompleted) c.complete();
    }
    _manual.clear();
  }

  void begin(StrapEvent e) => session.begin(e).then((c) => result = c);
}
