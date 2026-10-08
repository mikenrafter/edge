// water_display.dart — the UI half of the shared water formatter.
//
// data/water_units.dart owns the numbers; this finds the user's unit system
// from the widget tree so Journal, Nutrition and the follow-up screen read it
// the same way (Provider<UnitsController>, metric when none is above, like
// every other unit in the app).

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../data/water_units.dart';
import '../l10n/app_localizations.dart';
import '../state/units_controller.dart';

/// The unit system above [c]. [listen] false for event handlers (a `watch`
/// outside build throws, and swallowing that would silently mean metric).
UnitSystem waterSystemOf(BuildContext c, {bool listen = true}) {
  try {
    final u = listen ? c.watch<UnitsController>() : c.read<UnitsController>();
    return u.system;
  } on ProviderNotFoundException {
    return UnitSystem.metric;
  }
}

/// "250 ml" / "8 fl oz" in the unit system above [c].
String waterText(BuildContext c, num ml, {bool listen = true}) =>
    WaterUnits.format(ml, waterSystemOf(c, listen: listen));

/// "Includes 250 ml assumed" — the part of a water total that came from
/// "Assume I drank water" and not from the wearer. Null when there is none.
String? assumedShareText(BuildContext c, double? assumedMl) {
  if (assumedMl == null || assumedMl <= 0) return null;
  final amount = waterText(c, assumedMl);
  return AppLocalizations.of(c)?.waterIncludesAssumed(amount) ??
      'Includes $amount assumed';
}
