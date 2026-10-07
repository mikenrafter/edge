// hr_rhythm_fit.dart — an EXPERIMENTAL cosinor fit to recorded hourly heart
// rate. Output 2 of 3 of the circadian explore prototype.
//
// What this is: the phase, amplitude and mesor of a 24 h cosine fitted to the
// hourly HR the band recorded. What it is NOT: an internal-clock estimate, or
// melatonin onset. Nothing here has been validated against a reference such as
// dim-light melatonin onset, and fit quality is not accuracy.
//
// Strict admission, else null (never a guess; AGENTS.md section 3.3):
//   * a bin counts only with a non-null meanHr and >= [kMinRealMinutesPerBin]
//   * a day counts only with >= [kMinCoveredHoursPerDay] covered hours
//   * >= [kMinRhythmDays] such days
//   * amplitude >= [kMinRhythmAmplitudeBpm], else flat
//   * leave-one-day-out acrophase spread <= [kMaxPhaseSpreadHours], else unstable
//
// PROTOTYPE: phase estimation belongs in the analytics repo; this lives in edge
// only to explore it, and moves there (AGENTS.md section 1).

/// One local clock hour of recorded HR. [hourStartLocal] is a local wall-clock
/// hour start; [realMinutes] is minutes of real samples in that hour.
class HourlyBin {
  const HourlyBin({
    required this.hourStartLocal,
    required this.meanHr,
    required this.realMinutes,
  });
  final DateTime hourStartLocal;
  final double? meanHr;
  final int realMinutes;
}

enum RhythmRejection { tooFewDays, lowCoverage, flat, unstable }

const int kMinRhythmDays = 7;
const int kMinCoveredHoursPerDay = 18;
const int kMinRealMinutesPerBin = 10;
const double kMinRhythmAmplitudeBpm = 2.0;
const double kMaxPhaseSpreadHours = 2.0;

class HrRhythm {
  const HrRhythm({
    this.acrophaseClock,
    this.bathyphaseClock,
    this.amplitudeBpm,
    this.mesorBpm,
    required this.daysUsed,
    required this.coverage,
    this.rejection,
  });

  /// Local clock time of the fitted HR peak, since midnight in [0, 24 h).
  final Duration? acrophaseClock;

  /// Local clock time of the fitted HR trough (acrophase + 12 h).
  final Duration? bathyphaseClock;

  /// Half the peak-to-trough swing of the fit.
  final double? amplitudeBpm;

  /// Fitted 24 h mean.
  final double? mesorBpm;

  /// Days that passed the coverage gate.
  final int daysUsed;

  /// Mean fraction of the 24 hourly bins admitted, over the days used.
  final double coverage;

  /// Why nothing was reported; null when admitted. A rejection carries null
  /// acrophase, bathyphase, amplitude and mesor.
  final RhythmRejection? rejection;
}

HrRhythm fitHrRhythm(List<HourlyBin> bins) => throw UnimplementedError();
