// hr_rhythm_fit.dart — an EXPERIMENTAL cosinor fit to recorded hourly heart
// rate. Output 2 of 3 of the circadian explore prototype.
//
// What this is: the phase, amplitude and mesor of a 24 h cosine fitted to the
// hourly HR the band recorded. What it is NOT: an internal-clock estimate, or
// melatonin onset. Nothing here has been validated against a reference such as
// dim-light melatonin onset, and fit quality is not accuracy.
//
// Strict admission, else null (never a guess; AGENTS.md section 3.3):
//   * a bin counts only with a non-null meanHr and a KNOWN realMinutes >=
//     [kMinRealMinutesPerBin] (unknown never counts)
//   * a day counts only with >= [kMinCoveredHoursPerDay] covered hours
//   * >= [kMinRhythmDays] such days
//   * amplitude >= [kMinRhythmAmplitudeBpm], else flat
//   * leave-one-day-out acrophase spread <= [kMaxPhaseSpreadHours], else unstable
//   * per-day acrophase circular SD <= [kMaxDayPhaseSdHours], else unstable
//
// PROTOTYPE: phase estimation belongs in the analytics repo; this lives in edge
// only to explore it, and moves there (AGENTS.md section 1).

import 'dart:math' as math;

/// One local clock hour of recorded HR. [hourStartLocal] is a local wall-clock
/// hour start; [realMinutes] is minutes of real samples in that hour, or null
/// when that is not knowable (a stored curve without per-minute sample counts).
/// Null is unknown, never zero and never a full hour.
class HourlyBin {
  const HourlyBin({
    required this.hourStartLocal,
    required this.meanHr,
    required this.realMinutes,
  });
  final DateTime hourStartLocal;
  final double? meanHr;
  final int? realMinutes;
}

enum RhythmRejection {
  tooFewDays,
  lowCoverage,

  /// Too few days passed the coverage gate, and some hours have no known
  /// real-minute count (days stored without per-minute sample counts), so
  /// whether they would have passed is unknown.
  unknownCoverage,
  flat,
  unstable,
}

const int kMinRhythmDays = 7;
const int kMinCoveredHoursPerDay = 18;
const int kMinRealMinutesPerBin = 10;
const double kMinRhythmAmplitudeBpm = 2.0;
const double kMaxPhaseSpreadHours = 2.0;

/// Day-to-day consistency: the circular standard deviation, in hours, of the
/// acrophase fitted to each usable day on its own. Leave-one-out alone cannot
/// see a step change (half the days at each of two phases barely moves it).
const double kMaxDayPhaseSdHours = 2.0;

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

HrRhythm fitHrRhythm(List<HourlyBin> bins) {
  // Every local calendar day present in the input, admitted or not, and each
  // day's admitted bins.
  final present = <int>{};
  final admittedByDay = <int, List<HourlyBin>>{};
  var unknownBins = false; // an hour whose real-minute count is not known
  for (final b in bins) {
    final day = _dayKey(b.hourStartLocal);
    present.add(day);
    final hr = b.meanHr;
    final real = b.realMinutes;
    if (hr != null && hr.isFinite && real == null) unknownBins = true;
    if (hr != null && hr.isFinite && real != null && real >= kMinRealMinutesPerBin) {
      (admittedByDay[day] ??= []).add(b);
    }
  }

  // A day is usable with enough distinct wall-clock hours covered. A fall-back
  // day has two bins for one wall hour; that hour is covered once.
  final usable = <int, List<HourlyBin>>{};
  var coverageSum = 0.0;
  for (final e in admittedByDay.entries) {
    final hours = {for (final b in e.value) b.hourStartLocal.hour};
    if (hours.length >= kMinCoveredHoursPerDay) {
      usable[e.key] = e.value;
      coverageSum += hours.length / 24.0;
    }
  }
  final daysUsed = usable.length;
  final coverage = daysUsed == 0 ? 0.0 : coverageSum / daysUsed;

  HrRhythm reject(RhythmRejection why) => HrRhythm(
        daysUsed: daysUsed,
        coverage: coverage,
        rejection: why,
      );

  if (present.length < kMinRhythmDays) return reject(RhythmRejection.tooFewDays);
  if (daysUsed < kMinRhythmDays) {
    return reject(unknownBins
        ? RhythmRejection.unknownCoverage
        : RhythmRejection.lowCoverage);
  }

  final days = usable.keys.toList()..sort();
  final all = <HourlyBin>[for (final d in days) ...usable[d]!];
  final fit = _cosinor(all);
  if (fit == null || fit.amplitude < kMinRhythmAmplitudeBpm) {
    return reject(RhythmRejection.flat);
  }

  // Leave one day out: the acrophase must not hinge on any single day.
  final loo = <double>[];
  for (final d in days) {
    final f = _cosinor([
      for (final k in days)
        if (k != d) ...usable[k]!,
    ]);
    if (f == null) return reject(RhythmRejection.unstable);
    loo.add(f.acrophaseHours);
  }
  if (_circularRangeHours(loo) > kMaxPhaseSpreadHours) {
    return reject(RhythmRejection.unstable);
  }

  // Day to day: each day's own acrophase must agree with the others.
  final perDay = <double>[];
  for (final d in days) {
    final f = _cosinor(usable[d]!);
    if (f == null) return reject(RhythmRejection.unstable);
    perDay.add(f.acrophaseHours);
  }
  if (_circularSdHours(perDay) > kMaxDayPhaseSdHours) {
    return reject(RhythmRejection.unstable);
  }

  final peak = Duration(seconds: (fit.acrophaseHours * 3600).round() % 86400);
  return HrRhythm(
    acrophaseClock: peak,
    bathyphaseClock: Duration(seconds: (peak.inSeconds + 12 * 3600) % 86400),
    amplitudeBpm: fit.amplitude,
    mesorBpm: fit.mesor,
    daysUsed: daysUsed,
    coverage: coverage,
  );
}

int _dayKey(DateTime t) => t.year * 10000 + t.month * 100 + t.day;

class _Cosinor {
  const _Cosinor(this.mesor, this.amplitude, this.acrophaseHours);
  final double mesor, amplitude;

  /// Hours since local midnight in [0, 24).
  final double acrophaseHours;
}

/// Least squares of y = M + a cos(wt) + b sin(wt), w = 2 pi / 24 h, t the wall
/// clock hour of the middle of each bin. Null when the system is singular.
_Cosinor? _cosinor(List<HourlyBin> bins) {
  const w = 2 * math.pi / 24.0;
  // Normal equations A x = r for x = (M, a, b).
  final m = List.generate(3, (_) => List<double>.filled(4, 0));
  for (final bin in bins) {
    final t = bin.hourStartLocal.hour + bin.hourStartLocal.minute / 60.0 + 0.5;
    final row = [1.0, math.cos(w * t), math.sin(w * t)];
    final y = bin.meanHr!;
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        m[i][j] += row[i] * row[j];
      }
      m[i][3] += row[i] * y;
    }
  }
  // Gaussian elimination with partial pivoting.
  for (var col = 0; col < 3; col++) {
    var piv = col;
    for (var r = col + 1; r < 3; r++) {
      if (m[r][col].abs() > m[piv][col].abs()) piv = r;
    }
    if (m[piv][col].abs() < 1e-9) return null;
    final tmp = m[col];
    m[col] = m[piv];
    m[piv] = tmp;
    for (var r = 0; r < 3; r++) {
      if (r == col) continue;
      final f = m[r][col] / m[col][col];
      for (var c = col; c < 4; c++) {
        m[r][c] -= f * m[col][c];
      }
    }
  }
  final mesor = m[0][3] / m[0][0];
  final a = m[1][3] / m[1][1];
  final b = m[2][3] / m[2][2];
  var phase = math.atan2(b, a) / w;
  phase = ((phase % 24) + 24) % 24;
  return _Cosinor(mesor, math.sqrt(a * a + b * b), phase);
}

/// Smallest arc, in hours, holding every point of [hours] on the 24 h circle.
double _circularRangeHours(List<double> hours) {
  if (hours.length < 2) return 0;
  final s = [for (final h in hours) ((h % 24) + 24) % 24]..sort();
  // The arc is 24 minus the widest gap between neighbours round the circle.
  var widest = s.first + 24 - s.last;
  for (var i = 1; i < s.length; i++) {
    widest = math.max(widest, s[i] - s[i - 1]);
  }
  return 24 - widest;
}

/// Circular standard deviation of [hours] on the 24 h circle, in hours.
double _circularSdHours(List<double> hours) {
  if (hours.length < 2) return 0;
  var c = 0.0, s = 0.0;
  for (final h in hours) {
    final a = 2 * math.pi * h / 24.0;
    c += math.cos(a);
    s += math.sin(a);
  }
  final r = math.sqrt(c * c + s * s) / hours.length;
  if (r < 1e-12) return double.infinity;
  return math.sqrt(-2 * math.log(math.min(1.0, r))) * 24.0 / (2 * math.pi);
}
