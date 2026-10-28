part of 'learning.dart';

Map<String, double> _validatedKineticTargets(
  TrackDefinition track,
  String system,
  List<_NightPair> pairs,
  TrackEffectEstimator estimator,
) {
  if (pairs.length < 32) return const {};
  final timing = pairs
      .map((p) => p.exposed.features[track.id]!.timingHours)
      .whereType<double>()
      .map((v) => (v * 4).round())
      .toSet();
  final doses = pairs
      .map((p) => p.exposed.features[track.id]!.dose)
      .whereType<double>()
      .toSet();
  final history = pairs.every(
    (p) =>
        p.exposed.features[track.id]!.effectiveResidual != null &&
        p.control.features[track.id]!.effectiveResidual != null,
  );
  final runs = {
    for (final pair in pairs)
      for (final row in [pair.exposed, pair.control])
        if ((row.features[track.id]!.exposureRunDays ?? 0) > 0)
          row.features[track.id]!.exposureRunDays!,
  };
  final abstinence = {
    for (final pair in pairs)
      for (final row in [pair.exposed, pair.control])
        if ((row.features[track.id]!.abstinenceDays ?? 0) > 0)
          row.features[track.id]!.abstinenceDays!,
  };
  DateTime lastOutcome(_NightPair pair) =>
      pair.exposed.night.at.isAfter(pair.control.night.at)
      ? pair.exposed.night.at
      : pair.control.night.at;
  final ordered = List<_NightPair>.of(pairs)
    ..sort((a, b) => lastOutcome(a).compareTo(lastOutcome(b)));
  final targets = <String, double>{};
  for (final key in trackKineticKeys) {
    // Slow fields need identifiable frequency and abstinence histories.
    // Constant-dose/time experiments may identify these, but never acute PK.
    if ((key == 'half_life_hours' || key == 'onset_hours') &&
        (timing.length < 3 || doses.length < 3)) {
      continue;
    }
    if (key == 'tolerance_days' && (!history || runs.length < 3)) continue;
    if (key == 'withdrawal_days' && (!history || abstinence.length < 3)) {
      continue;
    }
    final field = track.kinetics.fields[key];
    if (field == null ||
        field.locked ||
        field.value == null ||
        field.value! <= 0) {
      continue;
    }
    final current = field.value!;
    final window = trackHistoryWindow(track);
    final baseline = _kineticValidationLoss(
      track,
      system,
      ordered,
      estimator,
      window,
    );
    if (baseline == null || baseline < 1e-10) continue;
    var bestLoss = baseline, best = current;
    for (final factor in [.5, .75, 1.25, 1.5]) {
      final candidate = _withKinetic(track, key, current * factor);
      final loss = _kineticValidationLoss(
        candidate,
        system,
        ordered,
        estimator,
        window,
      );
      if (loss != null && loss < bestLoss) {
        bestLoss = loss;
        best = current * factor;
      }
    }
    // A held-out improvement must be material; noise must not cause a drift.
    if (bestLoss < baseline * .8) targets[key] = best;
  }
  return targets;
}

TrackDefinition _withKinetic(TrackDefinition t, String key, double value) =>
    TrackDefinition(
      id: t.id,
      name: t.name,
      icon: t.icon,
      kind: t.kind,
      systems: t.systems,
      subActivities: t.subActivities,
      kinetics: TrackKinetics({
        ...t.kinetics.fields,
        key: TrackKineticField(value: value),
      }),
    );

double? _kineticValidationLoss(
  TrackDefinition candidate,
  String system,
  List<_NightPair> pairs,
  TrackEffectEstimator estimator,
  Duration window,
) {
  final split = (pairs.length * .7).floor();
  final history = pairs.every(
    (p) =>
        p.exposed.features[candidate.id]!.effectiveResidual != null &&
        p.control.features[candidate.id]!.effectiveResidual != null,
  );
  final xs = <List<double>>[], ys = <double>[];
  for (final pair in pairs) {
    final a = estimator.features(
      candidate,
      pair.exposed.night.events,
      pair.exposed.night.at,
      historyComplete: pair.exposed.night.completeHistoryTrackIds.contains(
        candidate.id,
      ),
      historyWindow: window,
    );
    final b = estimator.features(
      candidate,
      pair.control.night.events,
      pair.control.night.at,
      historyComplete: pair.control.night.completeHistoryTrackIds.contains(
        candidate.id,
      ),
      historyWindow: window,
    );
    if (a.residualMg == null || b.residualMg == null) return null;
    if (history) {
      if (a.effectiveResidual == null || b.effectiveResidual == null) {
        return null;
      }
      xs.add([
        a.effectiveResidual! - b.effectiveResidual!,
        a.withdrawalPressure! - b.withdrawalPressure!,
      ]);
    } else {
      xs.add([a.residualMg! - b.residualMg!]);
    }
    ys.add(
      _adjustedOutcome(pair.exposed.night, system) -
          _adjustedOutcome(pair.control.night, system),
    );
  }
  // Both outcomes in every training pair must precede both outcomes in a
  // validation pair. A late matched control must not leak into earlier tests.
  var trainingEnd = pairs.first.exposed.night.at;
  for (final pair in pairs.take(split)) {
    for (final at in [pair.exposed.night.at, pair.control.night.at]) {
      if (at.isAfter(trainingEnd)) trainingEnd = at;
    }
  }
  final validation = [
    for (var i = split; i < pairs.length; i++)
      if (pairs[i].exposed.night.at.isAfter(trainingEnd) &&
          pairs[i].control.night.at.isAfter(trainingEnd))
        i,
  ];
  if (validation.length < 8) return null;
  final columns = [
    for (var j = 0; j < xs.first.length; j++)
      [for (var i = 0; i < split; i++) xs[i][j]],
  ];
  final scales = [
    for (final column in columns) math.sqrt(_dot(column, column)),
  ];
  if (scales.any((s) => s < 1e-9)) return null;
  final normalized = [
    for (var j = 0; j < columns.length; j++)
      [for (final value in columns[j]) value / scales[j]],
  ];
  final response = ys.take(split).toList();
  final matrix = [
    for (final x in normalized)
      [for (final y in normalized) _dot(x, y), _dot(x, response)],
  ];
  final fit = _solve(matrix);
  if (fit == null) return null;
  final beta = [for (var j = 0; j < fit.length; j++) fit[j] / scales[j]];
  var loss = 0.0;
  for (final i in validation) {
    final error = ys[i] - _dot(xs[i], beta);
    loss += error * error;
  }
  return loss / validation.length;
}
