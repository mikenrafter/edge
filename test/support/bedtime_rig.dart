// Shared rig for the Bedtime breathing cues tests: a controller wired to
// scripted fakes and a hand-moved clock. No timers, no BLE, no isolate.
// Evidence for the feature: Tsai et al. 2015, doi:10.1111/psyp.12333.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/explore/bedtime/bedtime_pacing_policy.dart';
import 'package:openstrap_edge/explore/bedtime/bedtime_session_controller.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';
import 'package:openstrap_edge/wake/natural_wake.dart' show NaturalObservation;

import 'wake_fakes.dart' show TestClock;

final DateTime kBedtimeT0 = DateTime.utc(2026, 10, 7, 23, 0, 0);

/// The stager's answer for the [call]th observe (0-based): [stage] over epoch
/// [call], so each call names a new 30 s epoch.
NaturalObservation bedtimeObs(String stage, int call,
        {double evidenceAgeMs = 30000}) =>
    NaturalObservation(
      stage: stage,
      confidence: stage == 'absent' ? 0 : 0.5,
      evidenceAgeMs: evidenceAgeMs,
      abstention: stage == 'absent' ? 'warmup' : null,
      runSec: stage == 'absent' ? 0 : 600,
      epochStartMs: stage == 'absent'
          ? null
          : kBedtimeT0.millisecondsSinceEpoch + 30000.0 * call,
      note: null,
    );

class BedtimeRig {
  BedtimeRig({BedtimePlan? plan, this.script}) {
    controller = BedtimeSessionController(
      plan: plan ?? BedtimePlan(),
      isConnected: () => connected,
      deliverCue: _deliver,
      observe: _observe,
      acquireStreams: _acquire,
      releaseStreams: _release,
      now: clock.call,
    );
  }

  final TestClock clock = TestClock(kBedtimeT0);
  late final BedtimeSessionController controller;

  bool connected = true;

  // cues
  bool deliverResult = true;
  Object? deliverThrows;
  Completer<bool>? deliverHold;
  final List<(BreathPhaseKind, Duration)> cues = [];
  List<BreathPhaseKind> get kinds => [for (final c in cues) c.$1];

  // observe: [script] answers the [call]th observe (0-based) unless a hold or a
  // throw is set.
  NaturalObservation? Function(int call)? script;
  Object? observeThrows;
  Completer<NaturalObservation?>? observeHold;
  int observeCalls = 0;
  int _inFlight = 0;
  int maxInFlight = 0;
  final List<Duration> observeAt = [];

  // streams
  int acquires = 0;
  int releases = 0;
  Object? acquireThrows;
  Object? releaseThrows;

  Duration get _elapsed => clock.now.difference(kBedtimeT0);

  Future<bool> _deliver(BreathPhaseKind k) async {
    cues.add((k, _elapsed));
    final hold = deliverHold;
    if (hold != null) return hold.future;
    if (deliverThrows != null) throw deliverThrows!;
    return deliverResult;
  }

  Future<NaturalObservation?> _observe() async {
    final call = observeCalls++;
    observeAt.add(_elapsed);
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    try {
      final hold = observeHold;
      if (hold != null) return await hold.future;
      if (observeThrows != null) throw observeThrows!;
      return script?.call(call);
    } finally {
      _inFlight--;
    }
  }

  Future<void> _acquire() async {
    acquires++;
    if (acquireThrows != null) throw acquireThrows!;
  }

  void _release() {
    releases++;
    if (releaseThrows != null) throw releaseThrows!;
  }

  /// Move the clock to [sec] seconds after the start, tick, and let any
  /// background observation land.
  Future<void> at(num sec) async {
    clock.at(kBedtimeT0.add(Duration(milliseconds: (sec * 1000).round())));
    await controller.tick();
    await pumpEventQueue();
  }

  Future<void> start() async {
    await controller.start();
    await pumpEventQueue();
  }
}
