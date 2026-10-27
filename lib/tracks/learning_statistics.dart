part of 'learning.dart';

double _adjustedOutcome(TrackNight n, String system) =>
    n.outcomes[system]! - n.baselines[system]!;

double _meanContrast(List<_NightPair> pairs, String system) =>
    pairs.fold<double>(
      0,
      (sum, p) =>
          sum +
          _adjustedOutcome(p.exposed.night, system) -
          _adjustedOutcome(p.control.night, system),
    ) /
    pairs.length;

double _dateShuffleP(
  List<_NightPair> pairs,
  String system,
  double observed,
  int family,
) {
  final values = [
    for (final p in pairs) ...[
      _adjustedOutcome(p.exposed.night, system),
      _adjustedOutcome(p.control.night, system),
    ],
  ];
  // Fixed seed makes repeated derives reproducible. Shuffle actual dated
  // outcomes, preserving the matched exposure design, rather than flipping signs.
  final random = math.Random(83117);
  var extreme = 0;
  // Resolution must support the family-wise threshold. A fixed 255 draws
  // made every effect impossible once users selected thirteen systems.
  final permutations = (family * 100).clamp(255, 4095);
  for (var trial = 0; trial < permutations; trial++) {
    values.shuffle(random);
    var difference = 0.0;
    for (var i = 0; i < values.length; i += 2) {
      difference += values[i] - values[i + 1];
    }
    if ((difference / pairs.length).abs() >= observed.abs() - 1e-12) extreme++;
  }
  // The plus-one correction prevents claiming a zero-probability finding.
  return (extreme + 1) / (permutations + 1);
}

bool? _failsNegativeControl(
  List<_NightPair> pairs,
  String system,
  double observed,
  String trackId,
) {
  Map<String, double> controls(TrackNight night) =>
      night.negativeControlsByTrack[trackId] ?? night.negativeControls;
  final eligible = pairs
      .where(
        (p) =>
            controls(p.exposed.night)[system]?.isFinite == true &&
            controls(p.control.night)[system]?.isFinite == true,
      )
      .toList();
  if (eligible.length < 12) return null;
  final differences = [
    for (final p in eligible)
      controls(p.exposed.night)[system]! - controls(p.control.night)[system]!,
  ];
  final moments = differences.fold(const TrackMoments(), (a, x) => a.add(x));
  final standardError = math.sqrt(
    moments.m2 / (moments.count - 1) / moments.count,
  );
  return moments.mean.abs() >= observed.abs() * .5 &&
      moments.mean.abs() > 3 * standardError;
}

class _TermFit {
  const _TermFit(this.coefficients, this.predictedMean);
  final Map<String, double> coefficients;
  final double predictedMean;
}

_TermFit? _fitPairTerms(List<_NightPair> pairs, String trackId, String system) {
  final raw = <String, List<double>>{};
  void column(String name) {
    final values = <double>[];
    for (final p in pairs) {
      final a = _termValue(name, p.exposed.features[trackId]!);
      final b = _termValue(name, p.control.features[trackId]!);
      if (a == null || b == null) return;
      values.add(a - b);
    }
    raw[name] = values;
  }

  // Prefer residual exposure; add dose, lag and timing only when the data
  // identify them separately. Collinear terms never receive invented effects.
  for (final name in [
    'effective_residual',
    'withdrawal_pressure',
    'residual_mg',
    'dose',
    'next_night_dose',
    'timing_hours',
  ]) {
    column(name);
  }
  final names = <String>[],
      basis = <List<double>>[],
      normalized = <List<double>>[];
  final scales = <double>[];
  for (final entry in raw.entries) {
    final norm = math.sqrt(_dot(entry.value, entry.value));
    if (norm < 1e-9) continue;
    final vector = entry.value.map((x) => x / norm).toList();
    final independent = List<double>.of(vector);
    for (final axis in basis) {
      final projection = _dot(independent, axis);
      for (var i = 0; i < independent.length; i++) {
        independent[i] -= projection * axis[i];
      }
    }
    final length = math.sqrt(_dot(independent, independent));
    if (length < 1e-5) continue;
    names.add(entry.key);
    scales.add(norm);
    normalized.add(vector);
    basis.add(independent.map((x) => x / length).toList());
  }
  if (names.isEmpty) return null;
  final response = [
    for (final p in pairs)
      _adjustedOutcome(p.exposed.night, system) -
          _adjustedOutcome(p.control.night, system),
  ];
  final matrix = [
    for (final x in normalized)
      [for (final y in normalized) _dot(x, y), _dot(x, response)],
  ];
  final beta = _solve(matrix);
  if (beta == null) return null;
  final coefficients = {
    for (var j = 0; j < names.length; j++) names[j]: beta[j] / scales[j],
  };
  var predicted = 0.0;
  for (var j = 0; j < names.length; j++) {
    predicted +=
        coefficients[names[j]]! *
        raw[names[j]]!.reduce((a, b) => a + b) /
        pairs.length;
  }
  return _TermFit(coefficients, predicted);
}

double? _termValue(String name, TrackExposureFeatures features) =>
    switch (name) {
      'effective_residual' => features.effectiveResidual,
      'withdrawal_pressure' => features.withdrawalPressure,
      'residual_mg' => features.residualMg,
      'dose' => features.dose,
      'next_night_dose' => features.nextNightDose,
      'timing_hours' => features.dose == 0 ? 0 : features.timingHours,
      _ => null,
    };

double _dot(List<double> a, List<double> b) {
  var result = 0.0;
  for (var i = 0; i < a.length; i++) {
    result += a[i] * b[i];
  }
  return result;
}

List<double>? _solve(List<List<double>> rows) {
  final n = rows.length;
  for (var col = 0; col < n; col++) {
    var pivot = col;
    for (var row = col + 1; row < n; row++) {
      if (rows[row][col].abs() > rows[pivot][col].abs()) pivot = row;
    }
    if (rows[pivot][col].abs() < 1e-8) return null;
    final swap = rows[col];
    rows[col] = rows[pivot];
    rows[pivot] = swap;
    final scale = rows[col][col];
    for (var j = col; j <= n; j++) {
      rows[col][j] /= scale;
    }
    for (var row = 0; row < n; row++) {
      if (row == col) continue;
      final factor = rows[row][col];
      for (var j = col; j <= n; j++) {
        rows[row][j] -= factor * rows[col][j];
      }
    }
  }
  return [for (final row in rows) row[n]];
}
