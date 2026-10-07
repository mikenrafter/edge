// Runs one sweep: drives the breathing cues, buffers live RR frames, and
// scores the blocks at the end.
//
// No AppState reference; everything arrives as a callback. Ephemeral: frames
// live in RAM only (AGENTS.md invariant 14). The only thing kept afterwards is
// the scored result, which the screen hands to the history store.
//
// Evidence:
//   Lehrer, Vaschillo & Vaschillo 2000, doi 10.1023/A:1009554825745
//   Shaffer & Meehan 2020, doi 10.3389/fnins.2020.570400
//
// RED-phase stub: every body throws until the implementation lands.
import 'package:flutter/foundation.dart';

import '../../stress/breath_phases.dart';
import 'resonance_analyzer.dart';
import 'resonance_sweep_plan.dart';

enum CueDelivery { delivered, skippedBusy, rejectedBudget, notConnected }

enum SweepState { idle, running, finished, stopped, failed }

class ResonanceSweepController extends ChangeNotifier {
  ResonanceSweepController({
    required this.plan,
    required this.isConnected,
    required this.deliverCue,
    required this.decodeBeats,
    required this.acquireStreams,
    required this.releaseStreams,
    this.stillFraction,
    this.now,
    this.hapticOnly = false,
  });

  final ResonanceSweepPlan plan;
  final bool Function() isConnected;
  final Future<CueDelivery> Function(BreathPhaseKind kind) deliverCue;

  /// Decodes and corrects one block's measure-window frames into beats.
  final Future<List<SweepBeat>> Function(List<({int atMs, String hex})> frames)
      decodeBeats;
  final Future<void> Function() acquireStreams;
  final void Function() releaseStreams;

  /// Share of [from]..[to] (session-relative) judged still; 1.0 when null.
  final double Function(Duration from, Duration to)? stillFraction;
  final DateTime Function()? now;
  final bool hapticOnly;

  SweepState get state => throw UnimplementedError();
  Duration get elapsed => throw UnimplementedError();
  SweepBlock? get currentBlock => throw UnimplementedError();
  SweepComparison? get result => throw UnimplementedError();
  String? get error => throw UnimplementedError();

  Future<void> start() => throw UnimplementedError();

  /// Driven by the UI or a test; reads the injected clock.
  void tick() => throw UnimplementedError();

  /// Buffers a frame (stamped with session-relative ms) while running only.
  void tapFrame(String hex) => throw UnimplementedError();

  /// User discomfort or leaving. Scores complete blocks only. Idempotent.
  Future<void> stop() => throw UnimplementedError();

  @override
  // ignore: must_call_super
  void dispose() => throw UnimplementedError();
}
