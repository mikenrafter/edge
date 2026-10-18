// One water formatter, one step (RED).
//
// Storage stays ONE field, `water_ml` (step 250, max 6000). Bug: Nutrition
// showed `ml / 1000` to one decimal, so 250 ml read "0.3 L" and 750 ml "0.8 L"
// (a different amount), and nothing honoured the imperial units setting.
//
// Decisions pinned here (the owner confirms them in the RED report):
//   * metric: under 1000 ml the number is millilitres ("250 ml"); from 1000 ml
//     it is litres with as many decimals as the amount needs, up to the ml
//     ("1 L", "1.25 L", "1.5 L"). Parsing the text back always gives the stored
//     ml, so the display is never a different amount.
//   * imperial: US fluid ounces, whole when whole, else one decimal.
//   * the imperial glass is 8 fl oz, stored as EXACT 8 x 29.5735295625 ml
//     (236.5882365), not 236.6 or 237: a rounded glass makes the 25th glass
//     read 200.4 fl oz instead of 200, so exact multiples are what keeps
//     imperial totals whole.
//   * the ceiling stays 6000 ml in both systems.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/water_units.dart';
import 'package:openstrap_edge/state/units_controller.dart';

const _m = UnitSystem.metric;
const _i = UnitSystem.imperial;

/// "1.25 L" -> 1250, "250 ml" -> 250: what the reader of the text takes away.
double _mlOf(String shown) {
  final parts = shown.split(' ');
  final n = double.parse(parts[0]);
  return switch (parts[1]) {
    'L' => n * 1000,
    'ml' => n,
    _ => throw FormatException('not a metric volume: $shown'),
  };
}

void main() {
  group('metric display is exact', () {
    test('the owner\'s examples', () {
      expect(WaterUnits.format(250, _m), '250 ml');
      expect(WaterUnits.format(750, _m), '750 ml');
      expect(WaterUnits.format(1000, _m), '1 L');
      expect(WaterUnits.format(1250, _m), '1.25 L');
      expect(WaterUnits.format(1500, _m), '1.5 L');
      expect(WaterUnits.format(6000, _m), '6 L');
    });

    test('the old one-decimal litre rounding is gone', () {
      for (final ml in [250, 750, 1250, 1750]) {
        final old = '${(ml / 1000).toStringAsFixed(1)} L';
        expect(WaterUnits.format(ml, _m), isNot(old),
            reason: '$ml ml must not read "$old"');
      }
    });

    test('every multiple of the step round-trips to the same amount', () {
      for (var ml = 0; ml <= 6000; ml += 250) {
        expect(_mlOf(WaterUnits.format(ml, _m)), ml.toDouble(),
            reason: '$ml ml');
      }
    });

    test('an in-between amount is shown to the millilitre, not rounded away',
        () {
      expect(WaterUnits.format(1234, _m), '1.234 L');
      expect(WaterUnits.format(80, _m), '80 ml');
      expect(WaterUnits.format(1001, _m), '1.001 L');
    });

    test('zero is a zero, with a unit', () {
      expect(WaterUnits.format(0, _m), '0 ml');
    });
  });

  group('imperial shows fluid ounces', () {
    test('whole ounces for whole glasses', () {
      final glass = WaterUnits.stepMl(_i);
      expect(WaterUnits.format(glass, _i), '8 fl oz');
      expect(WaterUnits.format(glass * 2, _i), '16 fl oz');
      expect(WaterUnits.format(0, _i), '0 fl oz');
    });

    test('an amount stored in metric reads to one decimal', () {
      expect(WaterUnits.format(500, _i), '16.9 fl oz');
      expect(WaterUnits.format(1000, _i), '33.8 fl oz');
    });

    test('a hand-rounded glass (236.6 ml) still reads 8 fl oz, not 8.0', () {
      expect(WaterUnits.format(236.6, _i), '8 fl oz');
    });

    test('no imperial text mentions ml or litres', () {
      for (final ml in [0, 250, 1500, 6000]) {
        final t = WaterUnits.format(ml, _i);
        expect(t, endsWith(' fl oz'));
        expect(t.contains('ml'), isFalse);
        expect(t.contains(' L'), isFalse);
      }
    });
  });

  group('the step', () {
    test('metric: 250 ml, the journal field\'s own step', () {
      expect(WaterUnits.stepMl(_m), 250);
      expect(WaterUnits.stepMl(_m), kJournalFieldsByKey['water_ml']!.step);
    });

    test('imperial: 8 US fl oz stored as its exact millilitre equivalent', () {
      expect(WaterUnits.glassFlOz, 8);
      expect(WaterUnits.mlPerFlOz, 29.5735295625);
      expect(WaterUnits.stepMl(_i), closeTo(8 * 29.5735295625, 1e-9));
      expect(WaterUnits.stepMl(_i), isNot(236.6));
      expect(WaterUnits.stepMl(_i), isNot(237));
    });

    test('imperial totals stay whole ounces for any number of glasses, '
        'added one at a time', () {
      final glass = WaterUnits.stepMl(_i);
      var total = 0.0;
      for (var n = 1; n <= 25; n++) {
        total += glass;
        expect(WaterUnits.format(total, _i), '${8 * n} fl oz', reason: '$n');
      }
    });

    test('25 imperial glasses fit under the 6000 ml ceiling, 26 would not',
        () {
      final glass = WaterUnits.stepMl(_i);
      final max = kJournalFieldsByKey['water_ml']!.max;
      expect(glass * 25, lessThan(max));
      expect(glass * 26, greaterThan(max));
    });
  });

  group('UnitsController carries it, like weight and distance', () {
    test('water() follows the system', () {
      expect(UnitsController.seed(_m).water(250), '250 ml');
      expect(UnitsController.seed(_i).water(250), WaterUnits.format(250, _i));
      expect(UnitsController.seed(_i).water(500), '16.9 fl oz');
    });

    test('waterStepMl follows the system', () {
      expect(UnitsController.seed(_m).waterStepMl, 250);
      expect(UnitsController.seed(_i).waterStepMl, WaterUnits.stepMl(_i));
    });
  });
}
