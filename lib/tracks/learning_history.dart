part of 'learning.dart';

/// Observation window for the user's slow kinetics, including candidate fits.
/// Ten entered day scales provide warm-up for candidate fits. Each fit also
/// verifies sensitivity to the unknown initial state is below 1e-6. This
/// engineering model does not claim a measured population washout.
Duration trackHistoryWindow(TrackDefinition track) {
  double value(String key) => track.kinetics.fields[key]?.value ?? 0;
  final hours = math.max(
    48.0,
    math.max(
      value('half_life_hours') * 10,
      math.max(value('tolerance_days'), value('withdrawal_days')) * 24 * 10,
    ),
  );
  final bounded = hours.clamp(48.0, 730.0 * 24);
  return Duration(
    microseconds: (bounded * Duration.microsecondsPerHour).ceil(),
  );
}

class _HistoryExposure {
  const _HistoryExposure(
    this.effectiveResidual,
    this.withdrawalPressure,
    this.exposureRunDays,
    this.abstinenceDays,
  );
  final double effectiveResidual, withdrawalPressure;
  final int exposureRunDays, abstinenceDays;
}

_HistoryExposure? _historyExposure(
  TrackDefinition track,
  List<TrackEvent> events,
  DateTime bedtime,
  double? residual,
  Duration window,
) {
  final toleranceDays = track.kinetics.fields['tolerance_days']?.value;
  final withdrawalDays = track.kinetics.fields['withdrawal_days']?.value;
  if (residual == null ||
      toleranceDays == null ||
      toleranceDays <= 0 ||
      withdrawalDays == null ||
      withdrawalDays <= 0) {
    return null;
  }
  if (math.max(toleranceDays, withdrawalDays) * 24 * 5 > window.inHours) {
    return null;
  }
  final start = bedtime.subtract(window);
  final doses = <String, double>{};
  final firstDate = dayLabelOf(start), lastDate = dayLabelOf(bedtime);
  for (final event in events) {
    if (event.trackId != track.id) continue;
    final timestamp = event.atMs;
    if (timestamp == null) {
      if (event.date.compareTo(firstDate) >= 0 &&
          event.date.compareTo(lastDate) <= 0) {
        return null;
      }
      continue;
    }
    if (timestamp < start.millisecondsSinceEpoch ||
        timestamp > bedtime.millisecondsSinceEpoch) {
      continue;
    }
    // ↳ CLAIM(unit-abstain)
    final amount = _amountInTrackUnit(track, event);
    if (amount == null) return null;
    final date = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(timestamp));
    doses[date] = (doses[date] ?? 0) + amount;
  }
  final positive = doses.values.where((d) => d > 0).toList()..sort();
  if (positive.isEmpty) return null;
  // Scale dose to this person's observed typical daily amount. No population
  // reference dose or physiological effect size is supplied by this model.
  final reference = positive[positive.length ~/ 2];
  var tolerance = 0.0, uncertainty = 1.0, run = 0, abstinence = 0;
  var usedToday = false;
  for (
    var day = DateTime(start.year, start.month, start.day);
    !day.isAfter(bedtime);
    day = DateTime(day.year, day.month, day.day + 1)
  ) {
    final dose = doses[dayLabelOf(day)] ?? 0;
    usedToday = dose > 0;
    if (usedToday) {
      final normalized = math.min(1.0, dose / reference);
      final retained = math.exp(-math.ln10 * normalized / toleranceDays);
      tolerance = 1 - (1 - tolerance) * retained;
      uncertainty *= retained;
      run++;
      abstinence = 0;
    } else {
      final retained = math.exp(-math.ln10 / withdrawalDays);
      tolerance *= retained;
      uncertainty *= retained;
      abstinence++;
      run = 0;
    }
  }
  // Reject histories that still depend on an unknown state before logging.
  if (uncertainty > 1e-6) return null;
  // Entered day scales mean 90% approach/loss. The outcome coefficients are
  // fitted independently, so neither tolerance nor withdrawal invents a score.
  return _HistoryExposure(
    residual * (1 - tolerance),
    usedToday ? 0 : tolerance,
    run,
    abstinence,
  );
}
