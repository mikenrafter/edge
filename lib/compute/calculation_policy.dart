import 'package:openstrap_analytics/onehz.dart';
import '../wake/natural_wake.dart';

/// Length of one causal stager epoch; an epoch's evidence is complete only
/// once it has closed.
const double _kEpochMs = 30000;

/// Picks how much of a day's derivation may be reused.
///
/// [CalculationMode.periodicAwake] (the only reusing mode) needs ALL of: no
/// heavy/forced request, the phone known to be unplugged, and a fresh,
/// confident, non-abstaining `wake` from the causal stager whose closed epoch
/// is itself within the evidence-age bound. Anything missing, unknown or
/// non-finite falls back to a full run ([CalculationMode.sleep]), so a night
/// or a nap is always recomputed from scratch.
CalculationMode selectCalculationMode({
  required bool heavy,
  required bool forced,
  required bool? phoneCharging,
  required NaturalObservation? observation,
  required double nowMs,
}) {
  if (heavy) return CalculationMode.heavy;
  if (forced) return CalculationMode.forced;
  if (phoneCharging != false || observation == null || !nowMs.isFinite) {
    return CalculationMode.sleep;
  }
  final o = observation;
  final age = o.evidenceAgeMs;
  final epoch = o.epochStartMs;
  final epochAge = epoch == null ? double.nan : nowMs - (epoch + _kEpochMs);
  bool fresh(double? ms) =>
      ms != null && ms.isFinite && ms >= 0 && ms <= kNaturalMaxEvidenceAgeMs;
  final awake = o.stage == 'wake' &&
      o.abstention == null &&
      o.confidence.isFinite &&
      o.confidence >= kNaturalMinConfidence &&
      fresh(age) &&
      fresh(epochAge);
  return awake ? CalculationMode.periodicAwake : CalculationMode.sleep;
}
