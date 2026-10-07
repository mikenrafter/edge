// bedtime_session_controller.dart — runs one "Bedtime breathing cues" session.
//
// Bedtime breathing cues, with an optional stop when the band estimates sleep.
// Evidence: Tsai et al. 2015, doi:10.1111/psyp.12333 (see the policy file for
// what it does and does not support).
//
// No AppState reference: everything the session touches arrives as a callback.
// The stager is reached only through [observe] (the existing
// `NaturalStageObserver` behind it); this file never runs a stager of its own.

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
        _policy = BedtimePacingPolicy(plan: plan),
        _isConnected = isConnected,
        _deliverCue = deliverCue,
        _observe = observe,
        _acquireStreams = acquireStreams,
        _releaseStreams = releaseStreams,
        _now = now ?? DateTime.now;

  BedtimePlan _plan;
  BedtimePacingPolicy _policy;
  final bool Function() _isConnected;
  final Future<bool> Function(BreathPhaseKind) _deliverCue;
  final Future<NaturalObservation?> Function() _observe;
  final Future<void> Function() _acquireStreams;
  final void Function() _releaseStreams;
  final DateTime Function() _now;

  /// The most observations kept; only the newest few ever matter.
  static const int _maxStages = 16;

  BedtimeState _state = BedtimeState.idle;
  BedtimeStopReason? _stopReason;
  String _sleepEstimate = 'unavailable';
  int _cuesSent = 0;
  int _cuesMissed = 0;
  int _missedStreak = 0;
  BreathPhaseKind? _phase;

  DateTime? _startedAt;
  bool _disposed = false;

  // Streams: set BEFORE the acquire await, so every way out of a started
  // session releases exactly once, even one that ends mid-acquire.
  bool _acquired = false;
  bool _released = false;

  // One cue in flight; the phase index last cued (never repeated).
  bool _delivering = false;
  int _lastCueIndex = -1;

  // One observation in flight; throttled by when the last one was asked.
  bool _observing = false;
  DateTime? _lastObserveAsk;
  final List<StageSample> _stages = [];

  BedtimePlan get plan => _plan;
  BedtimeState get state => _state;
  BedtimeStopReason? get stopReason => _stopReason;
  String get sleepEstimate => _sleepEstimate;

  /// The phase the band was last cued for, or null before the first cue.
  BreathPhaseKind? get phase => _phase;

  /// Cues that reached the band / that did not.
  int get cuesSent => _cuesSent;
  int get cuesMissed => _cuesMissed;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Change the plan while idle; ignored once started.
  void setPlan(BedtimePlan plan) {
    if (_state != BedtimeState.idle || _disposed) return;
    _plan = plan;
    _policy = BedtimePacingPolicy(plan: plan);
    _changed();
  }

  /// Acquire the live streams and begin. Single use: a second call, or a call
  /// after the session ended, does nothing.
  Future<void> start() async {
    if (_state != BedtimeState.idle || _disposed) return;
    if (!_isConnected()) {
      // Nothing was acquired, so there is nothing to release.
      _state = BedtimeState.ended;
      _stopReason = BedtimeStopReason.disconnected;
      _changed();
      return;
    }
    _state = BedtimeState.running;
    _startedAt = _now();
    _acquired = true;
    _changed();
    try {
      await _acquireStreams();
    } catch (_) {
      // No live heart-rate stream means the band is not really there.
      _finish(BedtimeStopReason.disconnected);
    }
  }

  /// One step of the session: end it if the policy says so, else deliver one
  /// cue at a phase boundary. Safe to call at any rate, and re-entrantly.
  Future<void> tick() async {
    if (_state != BedtimeState.running || _disposed) return;
    final now = _now();
    final started = _startedAt!;
    final elapsed = now.isBefore(started) ? Duration.zero : now.difference(started);

    if (_plan.stopOnSleep) {
      _sleepEstimate = _policy.sleepEstimateStatus(_stages, now);
      _maybeObserve(now);
    }
    _countSkippedPhases(elapsed);
    final why = _policy.onTick(
      elapsed: elapsed,
      now: now,
      recentStages: _stages,
      consecutiveMissedCues: _missedStreak,
      connected: _isConnected(),
    );
    if (why != null) {
      _finish(why);
      return;
    }
    await _cueIfBoundary(elapsed);
  }

  /// End the session as [BedtimeStopReason.userStopped]. Idempotent.
  Future<void> stop() async {
    if (_state != BedtimeState.running) return;
    _finish(BedtimeStopReason.userStopped);
  }

  /// Ends the session (streams released) if it is still running.
  @override
  void dispose() {
    if (_disposed) return;
    if (_state == BedtimeState.running) {
      _finish(BedtimeStopReason.userStopped);
    }
    _disposed = true;
    super.dispose();
  }

  // ── internals ─────────────────────────────────────────────────────────────

  void _finish(BedtimeStopReason why) {
    if (_state == BedtimeState.ended) return;
    _state = BedtimeState.ended;
    _stopReason = why;
    if (_acquired && !_released) {
      _released = true; // a release that throws is not retried
      try {
        _releaseStreams();
      } catch (_) {/* already gone */}
    }
    _changed();
  }

  /// Phase boundaries that passed with no cue tried for them (a late tick, or a
  /// delivery that took longer than a phase) are missed cues: they add to the
  /// missed count and the in-a-row streak, before the policy looks at it. Only
  /// the current phase is ever cued. Not counted while a delivery is in flight;
  /// they are counted by the first tick after it lands.
  void _countSkippedPhases(Duration elapsed) {
    if (_delivering || _lastCueIndex < 0) return;
    final index = (_plan.breathsAt(elapsed) * 2).floor();
    final skipped = index - _lastCueIndex - 1;
    if (skipped <= 0) return;
    _cuesMissed += skipped;
    _missedStreak += skipped;
    _lastCueIndex = index - 1; // the current phase is cued next
    _changed();
  }

  /// One cue per phase boundary. The phase is the whole breaths completed so
  /// far (so a taper keeps one continuous phase): an even half-breath is an
  /// inhale, an odd one an exhale. A late tick plays the current phase once and
  /// does not replay the ones it missed (those were counted as missed).
  Future<void> _cueIfBoundary(Duration elapsed) async {
    if (_delivering) return;
    final index = (_plan.breathsAt(elapsed) * 2).floor();
    if (index == _lastCueIndex) return;
    final kind = index.isEven ? BreathPhaseKind.inhale : BreathPhaseKind.exhale;
    _lastCueIndex = index;
    _phase = kind;
    _delivering = true;
    var reached = false;
    try {
      reached = await _deliverCue(kind);
    } catch (_) {
      reached = false;
    } finally {
      _delivering = false;
    }
    if (_state != BedtimeState.running || _disposed) return;
    if (reached) {
      _cuesSent++;
      _missedStreak = 0;
    } else {
      _cuesMissed++;
      _missedStreak++;
    }
    _changed();
  }

  /// Ask the stager now unless one answer is still pending or the last ask was
  /// under [kBedtimeObserveInterval] ago. Fire and forget: a slow stager never
  /// delays a cue.
  void _maybeObserve(DateTime now) {
    if (_observing) return;
    final last = _lastObserveAsk;
    if (last != null && now.difference(last) < kBedtimeObserveInterval) return;
    _lastObserveAsk = now;
    _observing = true;
    _observeOnce(now);
  }

  Future<void> _observeOnce(DateTime askedAt) async {
    StageSample sample;
    try {
      sample = _sampleFrom(await _observe(), askedAt);
    } catch (_) {
      // A stager that failed said nothing: absent, never awake.
      sample = StageSample(at: askedAt, stage: 'absent', observedAt: askedAt);
    } finally {
      _observing = false;
    }
    if (_state != BedtimeState.running || _disposed) return;
    _stages.add(sample);
    if (_stages.length > _maxStages) {
      _stages.removeRange(0, _stages.length - _maxStages);
    }
    _sleepEstimate = _policy.sleepEstimateStatus(_stages, _now());
    _changed();
  }

  /// What the stager said, as a sample. Anything that does not name a current
  /// epoch with a known stage is 'absent'.
  static StageSample _sampleFrom(NaturalObservation? o, DateTime askedAt) {
    StageSample absent() =>
        StageSample(at: askedAt, stage: 'absent', observedAt: askedAt);
    if (o == null) return absent();
    final age = o.evidenceAgeMs;
    final epoch = o.epochStartMs;
    final known = o.stage == 'wake' || o.stage == 'nrem' || o.stage == 'rem';
    if (!known ||
        epoch == null ||
        age == null ||
        age > kBedtimeFreshness.inMilliseconds) {
      return absent();
    }
    return StageSample(
      at: DateTime.fromMillisecondsSinceEpoch(epoch.round(), isUtc: true),
      stage: o.stage,
      observedAt: askedAt,
      evidenceAge: Duration(milliseconds: age.round()),
    );
  }
}
