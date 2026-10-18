import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart' show CalculationMode;
import 'package:openstrap_edge/compute/calculation_policy.dart';
import 'package:openstrap_edge/wake/natural_wake.dart';

const _now = 1700000900000.0;
NaturalObservation _observation({
  String stage = 'wake',
  double confidence = .8,
  double? evidenceAgeMs = 5000,
  double? epochStartMs = _now - 60000,
  String? abstention,
}) => NaturalObservation(
  stage: stage,
  confidence: confidence,
  evidenceAgeMs: evidenceAgeMs,
  abstention: abstention,
  runSec: 120,
  epochStartMs: epochStartMs,
  note: 'deterministic policy fixture',
);
CalculationMode _select({
  bool heavy = false,
  bool forced = false,
  bool? charging = false,
  NaturalObservation? observation,
  double now = _now,
}) => selectCalculationMode(
  heavy: heavy,
  forced: forced,
  phoneCharging: charging,
  observation: observation,
  nowMs: now,
);

void main() {
  test('unknown stage label refuses reuse', () {
    expect(
      _select(observation: _observation(stage: 'unknown')),
      CalculationMode.sleep,
    );
  });
  for (final charging in <bool?>[false, true, null]) {
    for (final stage in ['wake', 'nrem', 'rem', 'absent']) {
      test('charging=$charging observed stage=$stage', () {
        expect(
          _select(
            charging: charging,
            observation: _observation(stage: stage),
          ),
          charging == false && stage == 'wake'
              ? CalculationMode.periodicAwake
              : CalculationMode.sleep,
        );
      });
    }
    test('charging=$charging missing observation runs full', () {
      expect(_select(charging: charging), CalculationMode.sleep);
    });
    test('heavy outranks charging=$charging and fresh awake evidence', () {
      expect(
        _select(heavy: true, charging: charging, observation: _observation()),
        CalculationMode.heavy,
      );
    });
    test('forced outranks charging=$charging and fresh awake evidence', () {
      expect(
        _select(forced: true, charging: charging, observation: _observation()),
        CalculationMode.forced,
      );
    });
  }
  test('heavy and forced together always run full', () {
    expect(
      _select(heavy: true, forced: true, observation: _observation()),
      anyOf(CalculationMode.heavy, CalculationMode.forced),
    );
  });
  for (final conf in [
    double.nan,
    double.infinity,
    -.1,
    0.0,
    .299999,
    .3,
    .8,
    1.0,
  ]) {
    test('finite confidence >= minimum conf=$conf', () {
      expect(
        _select(observation: _observation(confidence: conf)),
        conf.isFinite && conf >= kNaturalMinConfidence
            ? CalculationMode.periodicAwake
            : CalculationMode.sleep,
      );
    });
  }
  for (final age in <double?>[
    null,
    double.nan,
    double.infinity,
    -1,
    0,
    149999,
    150000,
    150001,
  ]) {
    test('evidence freshness age=$age', () {
      expect(
        _select(observation: _observation(evidenceAgeMs: age)),
        age != null && age.isFinite && age >= 0 && age <= 150000
            ? CalculationMode.periodicAwake
            : CalculationMode.sleep,
      );
    });
  }
  for (final epoch in <double?>[
    null,
    double.nan,
    double.infinity,
    _now - 180001,
    _now - 180000,
    _now - 30000,
    _now - 29999,
    _now + 1,
  ]) {
    test('closed epoch within freshness bound start=$epoch', () {
      final elapsed = epoch == null ? double.nan : _now - (epoch + 30000);
      expect(
        _select(observation: _observation(epochStartMs: epoch)),
        elapsed.isFinite && elapsed >= 0 && elapsed <= 150000
            ? CalculationMode.periodicAwake
            : CalculationMode.sleep,
      );
    });
  }
  for (final reason in ['missingHr', 'noSignal', 'staleEvidence', '']) {
    test('any abstention refuses reuse reason=$reason', () {
      expect(
        _select(observation: _observation(abstention: reason)),
        CalculationMode.sleep,
      );
    });
  }
  for (final now in [double.nan, double.infinity, double.negativeInfinity]) {
    test('nonfinite current time refuses reuse now=$now', () {
      expect(
        _select(observation: _observation(), now: now),
        CalculationMode.sleep,
      );
    });
  }
  test(
    'charging/full state never becomes reusable on fresh high-confidence wake',
    () {
      final awake = _observation(
        confidence: 1,
        evidenceAgeMs: 0,
        epochStartMs: _now - 30000,
      );
      expect(
        _select(charging: true, observation: awake),
        CalculationMode.sleep,
      );
      expect(
        _select(charging: null, observation: awake),
        CalculationMode.sleep,
      );
      expect(
        _select(charging: false, observation: awake),
        CalculationMode.periodicAwake,
      );
    },
  );
}
