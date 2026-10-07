// water_units.dart — the ONE water formatter and step.
//
// Storage is one field, `water_ml` (journal_fields.dart), always millilitres.
// This only decides how an amount is SHOWN and how big one tap/glass is. Journal,
// Nutrition, the marked-moment Water answer and the water reminder text all go
// through here; a screen that divides by 1000 itself is the bug this replaces.
//
// RED-phase stub: every member throws until the GREEN phase implements it.

import '../state/units_controller.dart' show UnitSystem;

class WaterUnits {
  const WaterUnits._();

  /// Millilitres in one US fluid ounce (exact by definition).
  static const double mlPerFlOz = 29.5735295625;

  /// One imperial glass is one US cup: 8 fl oz.
  static const int glassFlOz = 8;

  /// "250 ml", "1.25 L", "1.5 L" (metric) or "8 fl oz" (imperial) for [ml].
  static String format(num ml, UnitSystem system) =>
      throw UnimplementedError('WaterUnits.format');

  /// One glass / one stepper tap, in ml, for [system].
  static double stepMl(UnitSystem system) =>
      throw UnimplementedError('WaterUnits.stepMl');
}
