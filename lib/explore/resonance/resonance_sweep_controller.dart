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
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../stress/breath_phases.dart';
import 'resonance_analyzer.dart';
import 'resonance_sweep_plan.dart';

enum CueDelivery { delivered, skippedBusy, rejectedBudget, notConnected }

enum SweepState { idle, running, finished, stopped, failed }

/// Converts parallel RR values, timestamps, and observation flags into beats.
///
/// All three lists describe the same samples. A mismatch is rejected rather
/// than padding a missing value or silently assigning it to another beat.
List<SweepBeat> sweepBeatsFromRr({
  required List<double> rrMs,
  required List<double> rrTsMs,
  required List<bool> observed,
}) {
  if (rrMs.length != rrTsMs.length || rrMs.length != observed.length) {
    throw ArgumentError('RR values, timestamps, and flags must have equal lengths.');
  }
  return [
    for (var index = 0; index < rrMs.length; index++)
      SweepBeat(
        tMs: rrTsMs[index].round(),
        rrMs: rrMs[index],
        observed: observed[index],
      ),
  ];
}

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

  /// Share of [from]..[to] (session-relative) judged still, or null for "no
  /// motion evidence for that span". With no callback at all, or a null
  /// answer, the block abstains ([BlockRejection.movementUnknown]): unknown is
  /// never counted as still.
  final double? Function(Duration from, Duration to)? stillFraction;
  final DateTime Function()? now;
  final bool hapticOnly;

  SweepState _state = SweepState.idle;
  Duration _elapsed = Duration.zero;
  SweepComparison? _result;
  String? _error;
  DateTime? _startedAt;
  bool _streamsHeld = false;
  bool _disposed = false;
  Future<void>? _terminalWork;
  final List<({int atMs, String hex})> _frames = [];
  final Set<int> _deliveredCueIndexes = {};
  final Map<int, int> _missedCuesByBlock = {};

  SweepState get state => _state;
  Duration get elapsed => _elapsed;
  SweepBlock? get currentBlock =>
      _state == SweepState.running ? plan.blockAt(_elapsed) : null;
  SweepComparison? get result => _result;

  /// Session-relative time right now on the clock the plan and [tapFrame] use
  /// (not the last [tick]); null unless the sweep is running. What a live
  /// sample source stamps its data with.
  Duration? get sessionTime =>
      _state == SweepState.running ? _elapsedAtNow() : null;
  String? get error => _error;

  Future<void> start() async {
    if (_state != SweepState.idle || _disposed) return;
    if (!isConnected()) {
      _fail('Connect your band first.');
      return;
    }
    // Ownership is claimed BEFORE the wait: the owner side marks the streams
    // held as the acquisition begins, so a dispose or failure during the wait
    // has to hand them back.
    _streamsHeld = true;
    try {
      await acquireStreams();
      if (_disposed) return; // already released by dispose()
      _startedAt = _clockNow();
      _elapsed = Duration.zero;
      _state = SweepState.running;
      _error = null;
      _result = null;
      _notify();
    } catch (exception) {
      if (_disposed) return;
      _fail(_errorText(exception));
    }
  }

  /// Driven by the UI or a test; reads the injected clock.
  void tick() {
    if (_state != SweepState.running) return;
    _elapsed = _elapsedAtNow();
    _queueDueCues();
    if (_elapsed >= plan.total) {
      _terminalWork ??= _complete(stoppedEarly: false);
    }
    _notify();
  }

  /// Buffers a frame (stamped with session-relative ms) while running only.
  void tapFrame(String hex) {
    if (_state != SweepState.running) return;
    final at = _elapsedAtNow();
    if (!plan.inMeasureWindow(at)) return;
    if (_frames.length == 20000) _frames.removeAt(0);
    _frames.add((atMs: at.inMilliseconds, hex: hex));
  }

  /// User discomfort or leaving. Scores complete blocks only. Idempotent.
  Future<void> stop() {
    if (_state != SweepState.running) return Future<void>.value();
    _elapsed = _elapsedAtNow();
    _terminalWork ??= _complete(stoppedEarly: true);
    return _terminalWork!;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _releaseStreamsOnce();
    super.dispose();
  }

  Future<void> _complete({required bool stoppedEarly}) async {
    try {
      final completed = plan.blocks
          .where((block) => block.end <= _elapsed)
          .toList(growable: false);
      final inputs = <BlockInput>[];
      for (final block in completed) {
        final frames = _frames
            .where((frame) =>
                frame.atMs >= block.settleEnd.inMilliseconds &&
                frame.atMs < block.end.inMilliseconds)
            .toList(growable: false);
        final beats = await decodeBeats(frames);
        inputs.add(BlockInput(
          block: block,
          beats: beats,
          stillFraction: stillFraction?.call(block.settleEnd, block.end),
          missedCues: _missedCuesByBlock[plan.blocks.indexOf(block)] ?? 0,
          hapticOnly: hapticOnly,
        ));
      }
      _result = compareBlocks(
        inputs,
        testedRates: plan.testedRates,
        stoppedEarly: stoppedEarly,
      );
      _state = stoppedEarly ? SweepState.stopped : SweepState.finished;
      _releaseStreamsOnce();
      _notify();
    } catch (exception) {
      _fail(_errorText(exception));
    }
  }

  DateTime _clockNow() => now?.call() ?? DateTime.now();

  Duration _elapsedAtNow() {
    final startedAt = _startedAt;
    if (startedAt == null) return Duration.zero;
    final value = _clockNow().difference(startedAt);
    return value.isNegative ? Duration.zero : value;
  }

  // Sends the cue for the phase running NOW and nothing older. A tick that
  // comes late (the UI ticker was starved) must not replay the phases it
  // slept through as a burst: they describe breaths that are over. Each such
  // skipped cue is a missed cue (it counts when it lay in a measure window),
  // and once the sweep is over no cue is sent at all.
  void _queueDueCues() {
    final due = <({int index, int blockIndex, Duration at, BreathPhaseKind kind})>[];
    var cueIndex = 0;
    for (var blockIndex = 0; blockIndex < plan.blocks.length; blockIndex++) {
      final block = plan.blocks[blockIndex];
      final phaseMicros = 30000000.0 / block.rateBpm;
      for (var phase = 0;; phase++, cueIndex++) {
        final at = block.start +
            Duration(microseconds: (phase * phaseMicros).round());
        if (at >= block.end) break;
        if (at > _elapsed) break;
        if (_deliveredCueIndexes.add(cueIndex)) {
          due.add((
            index: cueIndex,
            blockIndex: blockIndex,
            at: at,
            kind: block.pattern.phases[phase % 2].kind,
          ));
        }
      }
    }
    if (due.isEmpty) return;
    final current = _elapsed < plan.total ? due.removeLast() : null;
    for (final skipped in due) {
      _countMissed(skipped.blockIndex, skipped.at);
    }
    if (current != null) {
      unawaited(_deliverCue(current.blockIndex, current.at, current.kind));
    }
  }

  void _countMissed(int blockIndex, Duration at) {
    final block = plan.blocks[blockIndex];
    if (at >= block.settleEnd && at < block.end) {
      _missedCuesByBlock.update(blockIndex, (count) => count + 1,
          ifAbsent: () => 1);
    }
  }

  Future<void> _deliverCue(
    int blockIndex,
    Duration at,
    BreathPhaseKind kind,
  ) async {
    try {
      final delivery = await deliverCue(kind);
      if (delivery != CueDelivery.delivered) _countMissed(blockIndex, at);
    } catch (_) {
      _countMissed(blockIndex, at);
    }
  }

  void _fail(String message) {
    _state = SweepState.failed;
    _error = message;
    _result = null;
    _releaseStreamsOnce();
    _notify();
  }

  void _releaseStreamsOnce() {
    if (!_streamsHeld) return;
    _streamsHeld = false;
    releaseStreams();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _errorText(Object exception) {
    final text = exception.toString();
    return text.isEmpty ? 'Unable to complete the sweep.' : text;
  }
}
