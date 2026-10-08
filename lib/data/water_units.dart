// water_units.dart — the ONE water formatter and step.
//
// Storage is one field, `water_ml` (journal_fields.dart), always millilitres.
// This only decides how an amount is SHOWN and how big one tap/glass is. Journal,
// Nutrition, the marked-moment Water answer and the water reminder text all go
// through here; a screen that divides by 1000 itself is the bug this replaces.
//

import '../state/units_controller.dart' show UnitSystem;

class WaterUnits {
  const WaterUnits._();

  /// Millilitres in one US fluid ounce (exact by definition).
  static const double mlPerFlOz = 29.5735295625;

  /// One imperial glass is one US cup: 8 fl oz.
  static const int glassFlOz = 8;

  /// "250 ml", "1.25 L", "1.5 L" (metric) or "8 fl oz" (imperial) for [ml].
  ///
  /// Metric is exact: under 1000 ml the number is millilitres; from 1000 ml it
  /// is litres with the decimals the amount needs, down to the millilitre, so
  /// reading the text back always gives the stored amount. Imperial is US
  /// fluid ounces, whole when whole, else one decimal. A non-finite or negative
  /// amount is a caller bug (an absent value is null and never reaches here).
  static String format(num ml, UnitSystem system) {
    final v = ml.toDouble();
    if (!v.isFinite || v < 0) {
      throw ArgumentError.value(ml, 'ml', 'must be a finite amount >= 0');
    }
    if (system == UnitSystem.imperial) {
      return '${_trim((v / mlPerFlOz * 10).round() / 10)} fl oz';
    }
    final whole = v.round();
    if (whole < 1000) return '$whole ml';
    final litres = whole ~/ 1000;
    final rest = whole % 1000;
    if (rest == 0) return '$litres L';
    final frac = rest.toString().padLeft(3, '0').replaceFirst(RegExp(r'0+$'), '');
    return '$litres.$frac L';
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  /// One glass / one stepper tap, in ml, for [system]. Imperial is exactly
  /// 8 US fl oz (not 236.6 or 237) so imperial totals stay whole ounces.
  static double stepMl(UnitSystem system) => system == UnitSystem.imperial
      ? glassFlOz * mlPerFlOz
      : 250;
}
