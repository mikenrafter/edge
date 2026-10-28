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
    // Range exposures (kRangeExposureSource), see CLAIM(range-presence) and
    // CLAIM(range-untimed-dose): presence = an amountless exposure inside the
    // 24 h dose window; unknownLag = an amountless one in the 24-48 h window;
    // unknownTiming = an untimed amount, whose hour is not known.
    var presenceSeen = false, unknownLag = false, unknownTiming = false;
    final eveningDate = dayLabelOf(bedtime.subtract(const Duration(hours: 6)));
    final previousEveningDate = _previousDay(eveningDate);
    // CLAIM(residual-window): residual exposure is summed over seven half-lives
    // (under 1% left per dose), never a fixed 48 h; a window beyond the 48 h
    // exposure record needs the track's complete history or the residual stays
    // unknown [S6; track_effect_estimator_test]. Dose and lag keep 48 h.
    final windowHours = _residualWindowHours(track);
    if (windowHours > 48 && !historyComplete) unknownResidual = true;
    // ↳ CLAIM(unit-abstain): a unitless track still cannot mix explicit units.
    // Checked inside each feature's own window (R3-4): an old event outside
    // the 48 h dose window cannot blank a recent dose.
    if (_explicitUnitsConflict(track, events, bedtime, 48)) unknownDose = true;
    if (_explicitUnitsConflict(track, events, bedtime, windowHours)) {
      unknownResidual = true;
    }
    for (final event in events) {
      if (event.trackId != track.id) continue;
      final at = event.atMs;
      final fromRange = event.sourceKind == kRangeExposureSource;
      if (at == null) {
        final firstDate = dayLabelOf(
          bedtime.subtract(Duration(minutes: (windowHours * 60).ceil())),
        );
        if (event.date.compareTo(firstDate) >= 0 &&
            event.date.compareTo(dayLabelOf(bedtime)) <= 0) {
          unknownResidual = true;
          final inDoseDates =
              event.date.compareTo(
                dayLabelOf(bedtime.subtract(const Duration(hours: 48))),
              ) >=
              0;
          if (!fromRange) {
            if (inDoseDates) unknownDose = true;
            continue;
          }
          // ↳ CLAIM(range-untimed-dose): a period asserts the same intake
          // every day, so an untimed day still has a dose by its date.
          final amount = event.amount == null
              ? null
              : _amountInTrackUnit(track, event);
          if (event.amount != null && amount == null) {
            if (inDoseDates) unknownDose = true;
          } else if (event.date == eveningDate) {
            if (amount == null) {
              presenceSeen = true;
            } else {
              dose += amount;
              unknownTiming = true;
            }
          } else if (event.date == previousEveningDate) {
            if (amount == null) {
              unknownLag = true;
            } else {
              lag += amount;
            }
          }
          // A later date is after bedtime; an earlier one is out of the dose
          // windows. Neither is a dose, and the residual is already unknown.
        }
        continue;
      }
      final hours =
          (bedtime.millisecondsSinceEpoch - at) / Duration.millisecondsPerHour;
      if (hours < 0 || hours > windowHours) continue;
      if (fromRange && event.amount == null) {
        // ↳ CLAIM(range-presence): taken, but no amount, so no dose or
        // residual number; only whether it happened.
        unknownResidual = true;
        if (hours <= 24) {
          presenceSeen = true;
        } else if (hours <= 48) {
          unknownLag = true;
        }
        continue;
      }
      // ↳ CLAIM(unit-abstain)
      final amount = _amountInTrackUnit(track, event);
      if (amount == null) {
        unknownResidual = true;
        if (hours <= 48) unknownDose = true;
        continue;
      }
      if (hours <= 24) {
        dose += amount;
        weightedHours += amount * hours;
      } else if (hours <= 48) {
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
      final onset = kinetics.fields['onset_hours']?.value;
      // CLAIM(onset-unknown): an unknown onset leaves residual exposure
      // unknown; it is never read as zero [S5; track_effect_estimator_test].
      if (halfLife == null ||
          !halfLife.isFinite ||
          halfLife <= 0 ||
          onset == null ||
          !onset.isFinite ||
          onset < 0) {
        unknownResidual = true;
      } else if (hours >= onset) {
        // ↳ CLAIM(residual-window)
        residual += amount * math.pow(.5, hours / halfLife);
      }
    }
    // CLAIM(range-presence): presence (level 1) and a real amount are different
    // scales, so a window holding both is unknown, never 1 + 80. Presence-only
    // nights report no dose, residual or timing (no dose fitting); the contrast
    // reads exposureLevel instead [tracks_range_exposure_test].
    if (presenceSeen && dose > 0) unknownDose = true;
    if ((presenceSeen || unknownLag) && lag > 0) unknownLag = true;
    final presenceOnly = presenceSeen && !unknownDose;
    final slowWindow = historyWindow ?? trackHistoryWindow(track);
    // ↳ CLAIM(unit-abstain): the slow history is judged over its own, longer
    // window; a conflict there blanks only the slow features [R4-1].
    final slowUnitsConflict = _explicitUnitsConflict(
      track,
      events,
      bedtime,
      slowWindow.inMicroseconds / Duration.microsecondsPerHour,
    );
    final history = historyComplete && !slowUnitsConflict
        ? _historyExposure(
            track,
            events,
            bedtime,
            unknownResidual ? null : residual,
            slowWindow,
          )
        : null;
    return TrackExposureFeatures(
      dose: unknownDose || presenceOnly ? null : dose,
      residualMg: unknownResidual ? null : residual,
      timingHours: unknownDose || unknownTiming || presenceOnly || dose == 0
          ? null
          : weightedHours / dose,
      nextNightDose: unknownDose || unknownLag ? null : lag,
      presenceOnly: presenceOnly,
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
    Map<String, double> references = const {},
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
            references[track.id],
          ),
    ];
  }

  TrackEffectEstimate _estimateOne(
    TrackDefinition track,
    String system,
    List<TrackDefinition> tracks,
    List<TrackNight> nights,
    int family,
    double prior, [
    double? storedReference,
  ]) {
    // CLAIM(reference-only-in-baseline-mode): a saved reference applies only
    // while "this track is my baseline" is on [R4-3; track_effect_estimator_test].
    double? established = track.noUnadjustedData ? storedReference : null;
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
      referenceDose: established,
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
    final habitual = track.noUnadjustedData
        ? _habitualDose(track, rows, minimumPairs * 2)
        : null;
    // CLAIM(baseline-reference): once enough nights exist the habitual dose is
    // established, returned for persistence, and from then on read back from
    // learning state, so nights leaving the read window never move it [S4,
    // R2-3, R3-3; tracks_learning_storage_test].
    if (established == null && habitual != null && habitual.established) {
      established = habitual.dose;
    }
    final pairs = _matchedPairs(
      track,
      system,
      rows,
      relevant,
      referenceDose: established ?? habitual?.dose ?? 0.0,
    );
    if (pairs.length < minimumPairs) {
      final confounded = relevant.any(
        (t) =>
            t.id != track.id &&
            rows.every(
              (r) =>
                  ((r.features[track.id]?.exposureLevel ?? 0) > 0) ==
                  ((r.features[t.id]?.exposureLevel ?? 0) > 0),
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
      referenceDose: established,
    );
  }
}

double _longestHalfLife(TrackDefinition track) {
  var halfLife = 0.0;
  for (final k in [
    track.kinetics,
    for (final sub in track.subActivities) sub.kinetics,
  ]) {
    final value = k.fields['half_life_hours']?.value;
    if (value != null && value.isFinite && value > halfLife) halfLife = value;
  }
  return halfLife;
}

double _residualWindowHours(TrackDefinition track) =>
    math.min(math.max(48.0, _longestHalfLife(track) * 7), 730.0 * 24);

// CLAIM(unit-abstain): an event amount enters dose fitting only when its unit
// equals the track's current unit (an event without a unit is taken as the
// track's); with no track unit, all explicit event units must agree; any other
// unit is an unsupported conversion and leaves the amount unknown
// [S3; track_effect_estimator_test].
double? _amountInTrackUnit(TrackDefinition track, TrackEvent event) {
  final amount = event.amount;
  if (amount == null || !amount.isFinite || amount < 0) return null;
  final unit = event.unit?.trim().toLowerCase() ?? '';
  final expected = track.unit.trim().toLowerCase();
  // ↳ CLAIM(unit-abstain) [review P8a-P1]: a period's amount is stored with the
  // unit it was entered in, so the units must be identical, an empty unit
  // included; only a real log without a unit is read as the track's own.
  if (event.sourceKind == kRangeExposureSource) return unit == expected ? amount : null;
  if (unit.isNotEmpty && expected.isNotEmpty && unit != expected) return null;
  return amount;
}

bool _explicitUnitsConflict(
  TrackDefinition track,
  List<TrackEvent> events,
  DateTime bedtime,
  double windowHours,
) {
  if (track.unit.trim().isNotEmpty) return false;
  final units = {
    for (final e in events)
      if (e.trackId == track.id &&
          e.atMs != null &&
          (e.unit?.trim().isNotEmpty ?? false) &&
          (bedtime.millisecondsSinceEpoch - e.atMs!) /
                  Duration.millisecondsPerHour <=
              windowHours &&
          e.atMs! <= bedtime.millisecondsSinceEpoch)
        e.unit!.trim().toLowerCase(),
  };
  return units.length > 1;
}

String _previousDay(String date) {
  final day = DateTime.parse(date);
  return dayLabelOf(DateTime(day.year, day.month, day.day - 1));
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

({double dose, bool established})? _habitualDose(
  TrackDefinition track,
  List<_LearningRow> rows,
  int establishedNights,
) {
  final valid = rows
      .where((r) => r.features[track.id]?.dose != null)
      .take(establishedNights)
      .toList();
  if (valid.isEmpty) return null;
  final counts = <double, int>{};
  for (final r in valid) {
    counts.update(r.features[track.id]!.dose!, (n) => n + 1, ifAbsent: () => 1);
  }
  final dose = counts.entries
      .reduce((best, e) => e.value > best.value ? e : best)
      .key;
  return (dose: dose, established: valid.length >= establishedNights);
}

List<_NightPair> _matchedPairs(
  TrackDefinition track,
  String system,
  List<_LearningRow> rows,
  List<TrackDefinition> tracks, {
  required double referenceDose,
}) {
  // ↳ CLAIM(range-presence): a presence-only night is level 1 against a
  // reference of 0. Against any other reference (a persisted mg dose) the scales
  // differ, so such a night is unknown instead of "below" or "above" it.
  double? level(_LearningRow r) {
    final f = r.features[track.id];
    if (f == null) return null;
    return f.dose ?? (referenceDose == 0 ? f.exposureLevel : null);
  }

  final valid = rows.where((r) => level(r) != null).toList();
  // ↳ CLAIM(baseline-reference)
  final controls = valid.where((r) => level(r) == referenceDose).toList();
  final exposed = valid.where((r) => level(r)! != referenceDose).toList();
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
      // ↳ CLAIM(baseline-reference): the pair's "exposed" side is always the
      // higher dose, so a night below the reference keeps the effect's sign.
      pairs.add(
        level(row)! > referenceDose
            ? _NightPair(row, best)
            : _NightPair(best, row),
      );
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
