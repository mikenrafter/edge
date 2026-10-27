part of 'learning.dart';

class TrackEffectEstimator {
  const TrackEffectEstimator({
    this.minimumPairs = 12,
    this.priorWeight = 8,
    this.minimumCoverage = .8,
  });
  final int minimumPairs;
  final double priorWeight, minimumCoverage;

  TrackExposureFeatures features(
    TrackDefinition track,
    List<TrackEvent> events,
    DateTime bedtime, {
    bool historyComplete = false,
    Duration? historyWindow,
  }) {
    var dose = 0.0, residual = 0.0, lag = 0.0, weightedHours = 0.0;
    var unknownDose = false, unknownResidual = false;
    for (final event in events) {
      if (event.trackId != track.id) continue;
      final at = event.atMs;
      if (at == null) {
        final firstDate = dayLabelOf(
          bedtime.subtract(const Duration(hours: 48)),
        );
        if (event.date.compareTo(firstDate) >= 0 &&
            event.date.compareTo(dayLabelOf(bedtime)) <= 0) {
          unknownDose = true;
          unknownResidual = true;
        }
        continue;
      }
      final hours =
          (bedtime.millisecondsSinceEpoch - at) / Duration.millisecondsPerHour;
      if (hours < 0 || hours > 48) continue;
      // ↳ CLAIM(unit-abstain)
      final amount = _amountInTrackUnit(track, event);
      if (amount == null) {
        unknownDose = true;
        unknownResidual = true;
        continue;
      }
      if (hours <= 24) {
        dose += amount;
        weightedHours += amount * hours;
      } else {
        lag += amount;
      }
      var kinetics = track.kinetics;
      for (final sub in track.subActivities) {
        if (sub.id == event.subActivityId) {
          kinetics = TrackKinetics({
            ...kinetics.fields,
            for (final field in sub.kinetics.fields.entries)
              if (field.value.value != null || field.value.locked)
                field.key: field.value,
          });
          break;
        }
      }
      final halfLife = kinetics.fields['half_life_hours']?.value;
      final onset = kinetics.fields['onset_hours']?.value ?? 0;
      if (halfLife == null || !halfLife.isFinite || halfLife <= 0) {
        unknownResidual = true;
      } else if (hours >= onset) {
        residual += amount * math.pow(.5, hours / halfLife);
      }
    }
    final history = historyComplete
        ? _historyExposure(
            track,
            events,
            bedtime,
            unknownResidual ? null : residual,
            historyWindow ?? trackHistoryWindow(track),
          )
        : null;
    return TrackExposureFeatures(
      dose: unknownDose ? null : dose,
      residualMg: unknownResidual ? null : residual,
      timingHours: unknownDose || dose == 0 ? null : weightedHours / dose,
      nextNightDose: unknownDose ? null : lag,
      effectiveResidual: history?.effectiveResidual,
      withdrawalPressure: history?.withdrawalPressure,
      exposureRunDays: history?.exposureRunDays,
      abstinenceDays: history?.abstinenceDays,
    );
  }

  List<TrackEffectEstimate> estimate({
    required List<TrackDefinition> tracks,
    required List<TrackNight> nights,
    required DateTime asOf,
    Map<String, double> priors = const {},
  }) {
    final active = tracks.where((t) => t.enabled).toList();
    final ordered = {
      for (final n in nights)
        if (!n.at.isAfter(asOf)) n.at.millisecondsSinceEpoch: n,
    }.values.toList()..sort((a, b) => a.at.compareTo(b.at));
    final family = active.fold<int>(0, (n, t) => n + t.systems.toSet().length);
    return [
      for (final track in active)
        for (final system in track.systems.toSet())
          _estimateOne(
            track,
            system,
            active,
            ordered,
            math.max(1, family),
            priors['${track.id}:$system'] ?? 0,
          ),
    ];
  }

  TrackEffectEstimate _estimateOne(
    TrackDefinition track,
    String system,
    List<TrackDefinition> tracks,
    List<TrackNight> nights,
    int family,
    double prior,
  ) {
    TrackEffectEstimate absent(
      String reason, {
      int pairs = 0,
      double? p,
      double? adjusted,
    }) => TrackEffectEstimate(
      trackId: track.id,
      system: system,
      reason: reason,
      matchedPairs: pairs,
      shuffleP: p,
      adjustedP: adjusted,
    );
    final withOutcome = nights
        .where((n) => n.outcomes[system]?.isFinite == true)
        .toList();
    if (withOutcome.isEmpty) return absent('missing_system_data');
    final covered = withOutcome
        .where((n) => n.coverage.isFinite && n.coverage >= minimumCoverage)
        .toList();
    if (covered.length < minimumPairs * 2) {
      return absent(
        covered.length < withOutcome.length
            ? 'coverage'
            : 'insufficient_samples',
      );
    }
    final complete = covered
        .where((n) => n.completeTrackIds.contains(track.id))
        .toList();
    if (complete.length < minimumPairs * 2) return absent('logging_incomplete');
    final relevant = tracks.where((t) => t.systems.contains(system)).toList();
    final rows = [
      for (final n in complete)
        _LearningRow(n, {
          for (final t in relevant)
            t.id: features(
              t,
              n.events,
              n.at,
              historyComplete: n.completeHistoryTrackIds.contains(t.id),
            ),
        }),
    ];
    final pairs = _matchedPairs(track, system, rows, relevant);
    if (pairs.length < minimumPairs) {
      final confounded = relevant.any(
        (t) =>
            t.id != track.id &&
            rows.every(
              (r) =>
                  ((r.features[track.id]?.dose ?? 0) > 0) ==
                  ((r.features[t.id]?.dose ?? 0) > 0),
            ),
      );
      return absent(
        confounded ? 'cannot_separate' : 'unmatched',
        pairs: pairs.length,
      );
    }
    final observed = _meanContrast(pairs, system);
    final p = _dateShuffleP(pairs, system, observed, family);
    final adjusted = math.min(1.0, p * family);
    final negativeControl = _failsNegativeControl(
      pairs,
      system,
      observed,
      track.id,
    );
    if (negativeControl != false) {
      return absent(
        negativeControl == null
            ? 'negative_control_missing'
            : 'negative_control',
        pairs: pairs.length,
        p: p,
        adjusted: adjusted,
      );
    }
    if (p > .05) {
      return absent(
        'date_shuffle',
        pairs: pairs.length,
        p: p,
        adjusted: adjusted,
      );
    }
    if (adjusted > .05) {
      return absent(
        'multiple_comparisons',
        pairs: pairs.length,
        p: p,
        adjusted: adjusted,
      );
    }
    final model = _fitPairTerms(pairs, track.id, system);
    final effect = model == null ? observed : model.predictedMean;
    final weight = pairs.length / (pairs.length + priorWeight);
    return TrackEffectEstimate(
      trackId: track.id,
      system: system,
      reason: 'estimated',
      effect: effect * weight + (prior.isFinite ? prior : 0) * (1 - weight),
      matchedPairs: pairs.length,
      shuffleP: p,
      adjustedP: adjusted,
      coefficients: model?.coefficients ?? {},
      kineticTargets: _validatedKineticTargets(track, system, pairs, this),
    );
  }
}

// CLAIM(unit-abstain): an event amount enters dose fitting only when its unit
// equals the track's current unit (empty means unstated, taken as compatible);
// any other unit is an unsupported conversion and leaves the amount unknown
// [S3; track_effect_estimator_test].
double? _amountInTrackUnit(TrackDefinition track, TrackEvent event) {
  final amount = event.amount;
  if (amount == null || !amount.isFinite || amount < 0) return null;
  final unit = event.unit?.trim().toLowerCase() ?? '';
  final expected = track.unit.trim().toLowerCase();
  if (unit.isNotEmpty && expected.isNotEmpty && unit != expected) return null;
  return amount;
}

class _LearningRow {
  const _LearningRow(this.night, this.features);
  final TrackNight night;
  final Map<String, TrackExposureFeatures> features;
}

class _NightPair {
  const _NightPair(this.exposed, this.control);
  final _LearningRow exposed, control;
}

List<_NightPair> _matchedPairs(
  TrackDefinition track,
  String system,
  List<_LearningRow> rows,
  List<TrackDefinition> tracks,
) {
  final valid = rows.where((r) => r.features[track.id]?.dose != null).toList();
  var referenceDose = 0.0;
  if (track.noUnadjustedData && valid.isNotEmpty) {
    referenceDose = valid
        .map((r) => r.features[track.id]!.dose!)
        .reduce(math.min);
  }
  final controls = valid
      .where((r) => r.features[track.id]!.dose == referenceDose)
      .toList();
  final exposed = valid
      .where((r) => r.features[track.id]!.dose! > referenceDose)
      .toList();
  final used = <int>{};
  final pairs = <_NightPair>[];
  for (final row in exposed) {
    _LearningRow? best;
    var distance = double.infinity;
    for (final control in controls) {
      if (used.contains(control.night.at.millisecondsSinceEpoch) ||
          !_covariatesMatch(row.night, control.night, system)) {
        continue;
      }
      if (tracks.any(
        (t) => t.id != track.id && !_coExposureMatches(row, control, t.id),
      )) {
        continue;
      }
      final gap = row.night.at
          .difference(control.night.at)
          .inHours
          .abs()
          .toDouble();
      if (gap < distance) {
        best = control;
        distance = gap;
      }
    }
    if (best != null) {
      used.add(best.night.at.millisecondsSinceEpoch);
      pairs.add(_NightPair(row, best));
    }
  }
  return pairs;
}

bool _covariatesMatch(TrackNight a, TrackNight b, String system) {
  final baselineA = a.baselines[system], baselineB = b.baselines[system];
  if (baselineA == null ||
      baselineB == null ||
      !baselineA.isFinite ||
      !baselineB.isFinite ||
      !a.sleepDebtHours.isFinite ||
      !b.sleepDebtHours.isFinite ||
      !a.load.isFinite ||
      !b.load.isFinite) {
    return false;
  }
  if (a.bedtimeMinute < 0 ||
      a.bedtimeMinute >= 1440 ||
      b.bedtimeMinute < 0 ||
      b.bedtimeMinute >= 1440) {
    return false;
  }
  final minutes = (a.bedtimeMinute - b.bedtimeMinute).abs();
  // Engineering calipers, not validated clinical boundaries. Circular clock
  // distance preserves matching across midnight.
  return a.at.weekday == b.at.weekday &&
      math.min(minutes, 1440 - minutes) <= 60 &&
      (a.sleepDebtHours - b.sleepDebtHours).abs() <= 1 &&
      (a.load - b.load).abs() <= 10 &&
      (baselineA - baselineB).abs() <= math.max(1, baselineA.abs() * .1);
}

bool _coExposureMatches(_LearningRow a, _LearningRow b, String id) {
  if (!a.night.completeTrackIds.contains(id) ||
      !b.night.completeTrackIds.contains(id)) {
    return false;
  }
  final x = a.features[id]!, y = b.features[id]!;
  bool near(double? p, double? q) =>
      p != null &&
      q != null &&
      (p - q).abs() <= math.max(1e-6, math.max(p.abs(), q.abs()) * .05);
  return ((x.effectiveResidual == null && y.effectiveResidual == null) ||
          near(x.effectiveResidual, y.effectiveResidual)) &&
      ((x.withdrawalPressure == null && y.withdrawalPressure == null) ||
          near(x.withdrawalPressure, y.withdrawalPressure)) &&
      near(x.dose, y.dose) &&
      near(x.nextNightDose, y.nextNightDose) &&
      ((x.residualMg == null && y.residualMg == null) ||
          near(x.residualMg, y.residualMg));
}
