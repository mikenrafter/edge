// Fakes for the Breathing exercise gesture's tests: a clock and timer factory
// the test owns ([FakeTime]), and a session host that records what the
// screen-free [BreathPacer] asks of it ([FakeBreathHost]).
//
// [FakeTime.advance] moves the clock to each due timer in order and fires it,
// letting async work started by the callback settle before the next one, so a
// pacer that schedules only through [FakeTime.timer] and reads only
// [FakeTime.now] runs a whole session in zero real time.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart' show pumpEventQueue;
import 'package:openstrap_edge/gestures/breath_gesture.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';

class _FakeTimer implements Timer {
  _FakeTimer(this.clock, this.at, this.callback, this.seq);
  final FakeTime clock;
  final DateTime at;
  final void Function() callback;
  final int seq;
  bool _active = true;

  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

class FakeTime {
  FakeTime([DateTime? start])
      : start = start ?? DateTime.utc(2026, 10, 7, 9),
        now = start ?? DateTime.utc(2026, 10, 7, 9);

  /// Time zero for [elapsedSec].
  final DateTime start;
  DateTime now;
  final _timers = <_FakeTimer>[];
  int _seq = 0;

  /// The `now` the pacer / controller read.
  DateTime read() => now;

  /// The timer factory the pacer schedules through.
  Timer timer(Duration after, void Function() callback) {
    final t = _FakeTimer(this, now.add(after), callback, _seq++);
    _timers.add(t);
    return t;
  }

  /// Timers scheduled and not yet fired or cancelled.
  int get pending => _timers.where((t) => t.isActive).length;

  /// Seconds since [start], for cue times.
  double get elapsedSec =>
      now.difference(start).inMicroseconds / Duration.microsecondsPerSecond;

  /// Move time forward by [d], firing every timer that falls due on the way.
  Future<void> advance(Duration d) async {
    final end = now.add(d);
    await pumpEventQueue(times: 20);
    while (true) {
      final due = _timers.where((t) => t.isActive && !t.at.isAfter(end)).toList()
        ..sort((a, b) {
          final c = a.at.compareTo(b.at);
          return c != 0 ? c : a.seq.compareTo(b.seq);
        });
      if (due.isEmpty) break;
      final t = due.first;
      if (t.at.isAfter(now)) now = t.at;
      t._active = false;
      t.callback();
      await pumpEventQueue(times: 20);
    }
    now = end;
    await pumpEventQueue(times: 20);
  }
}

/// A [BreathPacerHost] that records every call. It does NOT clear
/// [pacedByBand] on stop: the pacer must clear its own flag.
class FakeBreathHost implements BreathPacerHost {
  FakeBreathHost(this.time, {this.connected = true});

  final FakeTime time;

  /// False: [startBreathingSession] leaves the session inactive (no band).
  bool connected;

  /// Set: [startBreathingSession] throws it.
  Object? startThrows;

  @override
  bool breathingActive = false;
  @override
  bool pacedByBand = false;

  BreathPattern? pattern;
  Duration? target;

  /// Every call in order: `start:<key>:<seconds>`, `phase:<kind>`,
  /// `complete`, `stop`.
  final events = <String>[];

  /// Each phase cue with the elapsed seconds (from the first advance) it
  /// arrived at.
  final cues = <({BreathPhaseKind kind, double at})>[];
  double? completeAt;

  int get starts => events.where((e) => e.startsWith('start:')).length;
  int get stops => events.where((e) => e == 'stop').length;
  int get completes => events.where((e) => e == 'complete').length;

  @override
  Future<void> startBreathingSession(
      {BreathPattern? pattern, Duration? target}) async {
    events.add('start:${pattern?.key}:${target?.inSeconds}');
    this.pattern = pattern;
    this.target = target;
    if (startThrows != null) throw startThrows!;
    if (!connected) return; // like the controller: refused, not thrown
    breathingActive = true;
  }

  @override
  Future<void> stopBreathingSession() async {
    if (!breathingActive) return; // like the controller
    breathingActive = false;
    events.add('stop');
  }

  @override
  void buzzBreathPhase(BreathPhaseKind kind) {
    events.add('phase:${kind.name}');
    cues.add((kind: kind, at: time.elapsedSec));
  }

  @override
  void buzzSessionComplete() {
    events.add('complete');
    completeAt = time.elapsedSec;
  }
}

/// The phase cues a session of [totalSec] over [pattern] must make, worked
/// out here from the pattern's phase lengths (not from `phaseAt`): one at
/// every phase boundary from 0 up to, but not including, the end.
List<({BreathPhaseKind kind, double at})> expectedCues(
    BreathPattern pattern, double totalSec) {
  final out = <({BreathPhaseKind kind, double at})>[];
  var t = 0.0;
  while (true) {
    for (final ph in pattern.phases) {
      if (t >= totalSec - 1e-6) return out;
      out.add((kind: ph.kind, at: t));
      t += ph.seconds;
    }
  }
}
