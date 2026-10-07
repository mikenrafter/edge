// bedtime_session_controller.dart — runs one "Bedtime breathing cues" session.
//
// Bedtime breathing cues, with an optional stop when the band estimates sleep.
// Evidence: Tsai et al. 2015, doi:10.1111/psyp.12333 (see the policy file for
// what it does and does not support).
//
// No AppState reference: everything the session touches arrives as a callback.
// The stager is reached only through [observe] (the existing
// `NaturalStageObserver` behind it); this file never runs a stager of its own.
// PHASE 1 STUBS: bodies throw.

import 'package:flutter/foundation.dart';

import '../../stress/breath_phases.dart';
import '../../wake/natural_wake.dart' show NaturalObservation;
import 'bedtime_pacing_policy.dart';

enum BedtimeState { idle, running, ended }

class BedtimeSessionController extends ChangeNotifier {
  BedtimeSessionController({
    required BedtimePlan plan,
    required bool Function() isConnected,
    required Future<bool> Function(BreathPhaseKind) deliverCue,
    required Future<NaturalObservation?> Function() observe,
    required Future<void> Function() acquireStreams,
    required void Function() releaseStreams,
    DateTime Function()? now,
  })  : _plan = plan,
        _isConnected = isConnected,
        _deliverCue = deliverCue,
        _observe = observe,
        _acquireStreams = acquireStreams,
        _releaseStreams = releaseStreams,
        _now = now ?? DateTime.now;

  BedtimePlan _plan;
  final bool Function() _isConnected;
  final Future<bool> Function(BreathPhaseKind) _deliverCue;
  final Future<NaturalObservation?> Function() _observe;
  final Future<void> Function() _acquireStreams;
  final void Function() _releaseStreams;
  final DateTime Function() _now;

  BedtimeState _state = BedtimeState.idle;
  BedtimeStopReason? _stopReason;
  String _sleepEstimate = 'unavailable';
  int _cuesSent = 0;
  int _cuesMissed = 0;

  BedtimePlan get plan => _plan;
  BedtimeState get state => _state;
  BedtimeStopReason? get stopReason => _stopReason;
  String get sleepEstimate => _sleepEstimate;

  /// Cues that reached the band / that did not.
  int get cuesSent => _cuesSent;
  int get cuesMissed => _cuesMissed;

  /// Change the plan while idle; ignored once started.
  void setPlan(BedtimePlan plan) => throw UnimplementedError();

  /// Acquire the live streams and begin. Single use: a second call, or a call
  /// after the session ended, does nothing.
  Future<void> start() => throw UnimplementedError();

  /// One step of the session: end it if the policy says so, else deliver one
  /// cue at a phase boundary. Safe to call at any rate, and re-entrantly.
  Future<void> tick() => throw UnimplementedError();

  /// End the session as [BedtimeStopReason.userStopped]. Idempotent.
  Future<void> stop() => throw UnimplementedError();

  @override
  void dispose() => throw UnimplementedError();
}
