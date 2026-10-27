// Evidence-limited track detectors. Each returns a reason or null: a candidate
// is a prompt for the wearer to review, never a diagnosis and never a dose.
// Missing evidence never matches (no imputation, no fallback signal).
import 'learning.dart';

/// One observed window, built by the caller from recorded data.
class DetectionWindow {
  const DetectionWindow({
    required this.startTs,
    required this.endTs,
    required this.phase,
    this.hr,
    this.rmssd,
    this.baselineHr,
    this.baselineRmssd,
    this.motion,
    this.coverage,
  });
  final int startTs, endTs;
  final String phase;
  final double? hr, rmssd, baselineHr, baselineRmssd, motion, coverage;

  static double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

  static DetectionWindow? fromMap(Map<String, Object?> m) {
    final start = _num(m['start_ts']), end = _num(m['end_ts']);
    if (start == null || end == null || end <= start) return null;
    return DetectionWindow(
      startTs: start.toInt(),
      endTs: end.toInt(),
      phase: m['phase'] as String? ?? '',
      hr: _num(m['hr']),
      rmssd: _num(m['rmssd']),
      baselineHr: _num(m['baseline_hr']),
      baselineRmssd: _num(m['baseline_rmssd']),
      motion: _num(m['motion']),
      coverage: _num(m['coverage']),
    );
  }

  Map<String, Object?> evidence() => {
    'hr': ?hr,
    'baseline_hr': ?baselineHr,
    'rmssd': ?rmssd,
    'baseline_rmssd': ?baselineRmssd,
  };
}

/// A supported effect learned by T2 for one affected system.
class LearnedSignature {
  const LearnedSignature(this.system, this.effect);
  final String system;
  final double effect;
}

/// Why a detector with the right window still said nothing. Abstaining is a
/// typed answer, not a quiet fall-through to another signal.
enum DetectionAbstain { noHrvSeries, noBaseline }

class TrackDetectors {
  const TrackDetectors();
  static const minCoverage = .5;
  static const maxRestingMotion = .1;
  static const alcoholHrRise = 5.0, alcoholRmssdRatio = .8;
  static const cannabisHrRise = 15.0;
  // The estimator's own gate, plus a margin for a stable personal signature.
  static const minLearnedPairs = 20, maxLearnedP = .05;

  /// Preset ids with a physiological detector. Caffeine has none: its
  /// relation to sleep is correlational, so nothing is proposed from the body.
  static bool hasPreset(String trackId) =>
      trackId == 'alcohol' || trackId == 'cannabis';

  static bool _usable(DetectionWindow w) =>
      (w.coverage ?? 0) >= minCoverage;

  /// Early sleep: heart rate up and RMSSD down against the personal baseline.
  /// Needs both signals; a rise alone is also what illness or late meals do.
  String? alcohol(DetectionWindow w, Set<String> systems) {
    if (!systems.containsAll(const ['hr', 'hrv']) || w.phase != 'early_sleep') {
      return null;
    }
    final hr = w.hr, base = w.baselineHr;
    final rmssd = w.rmssd, baseRmssd = w.baselineRmssd;
    if (!_usable(w) ||
        hr == null ||
        base == null ||
        rmssd == null ||
        baseRmssd == null ||
        baseRmssd <= 0) {
      return null;
    }
    return hr - base >= alcoholHrRise && rmssd <= baseRmssd * alcoholRmssdRatio
        ? 'early_sleep_hr_hrv'
        : null;
  }

  /// Why [alcohol] cannot judge an early-sleep window that is otherwise usable,
  /// or null when it can (it then matches or does not). A heart-rate rise alone
  /// is never enough, so a missing HRV series is a stated abstention.
  DetectionAbstain? alcoholAbstain(DetectionWindow w, Set<String> systems) {
    if (!systems.containsAll(const ['hr', 'hrv']) ||
        w.phase != 'early_sleep' ||
        !_usable(w) ||
        w.hr == null) {
      return null;
    }
    if (w.rmssd == null) return DetectionAbstain.noHrvSeries;
    final baseRmssd = w.baselineRmssd;
    if (w.baselineHr == null || baseRmssd == null || baseRmssd <= 0) {
      return DetectionAbstain.noBaseline;
    }
    return null;
  }

  /// A resting heart-rate jump with measured low motion.
  String? cannabis(DetectionWindow w, Set<String> systems) {
    if (!systems.contains('hr') || w.phase != 'awake') return null;
    final hr = w.hr, base = w.baselineHr, motion = w.motion;
    if (!_usable(w) ||
        hr == null ||
        base == null ||
        motion == null ||
        motion > maxRestingMotion) {
      return null;
    }
    return hr - base >= cannabisHrRise ? 'resting_hr_jump' : null;
  }

  /// A custom track needs a stable T2 signature. Only systems the wearer
  /// selected AND the window measures (hr, hrv) can match, in the learned
  /// direction and at least three quarters of the learned size.
  String? learned(DetectionWindow w, List<LearnedSignature> signatures) {
    final motion = w.motion;
    if (!_usable(w) ||
        motion == null ||
        motion > maxRestingMotion ||
        signatures.isEmpty) {
      return null;
    }
    var matched = 0;
    for (final s in signatures) {
      final double? now, base;
      switch (s.system) {
        case 'hr':
          now = w.hr;
          base = w.baselineHr;
        case 'hrv':
          now = w.rmssd;
          base = w.baselineRmssd;
        default:
          continue; // no window measurement for this system
      }
      if (now == null || base == null) return null;
      final deviation = (now - base) * s.effect.sign;
      if (deviation < 3 || deviation < s.effect.abs() * .75) return null;
      matched++;
    }
    return matched == 0 ? null : 'learned_signature';
  }

  /// Whether a stored T2 effect row supports detection.
  static bool stable({
    required String? reason,
    required num? effect,
    required num? pairs,
    required num? adjustedP,
    required num? shuffleP,
  }) =>
      reason == 'estimated' &&
      effect != null &&
      effect.isFinite &&
      effect != 0 &&
      (pairs ?? 0) >= minLearnedPairs &&
      adjustedP != null &&
      adjustedP <= maxLearnedP &&
      (shuffleP == null || shuffleP <= maxLearnedP);

  /// Learning must have passed the global observation period.
  static bool pastGlobalPeriod(int startedMs, int nowMs) =>
      nowMs - startedMs >= const TrackLearningPolicy().globalMinimum.inMilliseconds;
}
