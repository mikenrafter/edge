// The two confirm sheets of the "Add a device" flow, both built on one
// PairChoiceSheet:
//  - a scanned device is a band: "This is <label>", the matrix, and either
//    "Pair it as my band" (+ a secondary link) or only the secondary choice;
//  - a heart-rate sensor with no band paired: "Pair a sensor without a band?".
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/adapters/_registry.dart';
import '../../ble/slot_comparison.dart';
import '../../l10n/display_text.dart';
import 'pair_choice_sheet.dart';
import 'pair_text.dart';

/// What the user picked on the band-found sheet. Going back is null.
enum BandSheetChoice { asBand, asSensor }

/// "This is (band)": [afterConnect] is the same sheet after the connect found
/// the band (nothing was saved), with the sentence that says so.
Future<BandSheetChoice?> showBandFoundSheet(
  BuildContext c, {
  required BandEntry band,
  required bool hasMainBand,
  bool afterConnect = false,
}) async {
  final l = pairL10n(c);
  final label = uiText(c, band.label);
  // The main-band choice only exists when there is no main band yet and the
  // app can run this device as one.
  final canBeMain = !hasMainBand && band.canBeMainDevice;
  final body = afterConnect
      ? l.pairIdentifiedBody(label)
      : canBeMain
          ? l.pairBandFoundBody
          : hasMainBand
              ? l.pairBandFoundBodyHasBand
              : l.pairBandFoundBodyNoMain;
  final choice = await showPairChoiceSheet(
    c,
    PairChoiceSheet(
      title: l.pairBandFoundTitle(label),
      body: body,
      comparison: slotComparisonFor(band),
      bandUnavailableReason: band.canBeMainDevice ? null : l.pairMainBandUnavailable,
      primaryLabel: canBeMain ? l.pairAsMyBand : l.pairAsSecondary,
      primaryIcon: canBeMain ? LucideIcons.watch : null,
      primaryIsRecommended: canBeMain,
      secondaryLabel: canBeMain ? l.pairAsSecondaryAnyway : null,
      backLabel: l.pairGoBack,
    ),
  );
  return switch (choice) {
    PairChoice.primary =>
      canBeMain ? BandSheetChoice.asBand : BandSheetChoice.asSensor,
    PairChoice.secondary => BandSheetChoice.asSensor,
    _ => null,
  };
}

/// What a band would give next to what [sensor] gives: the app's own band
/// (WHOOP 5) against the sensor's side.
SlotComparison sensorVersusBand(BandEntry sensor) => SlotComparison(
  asBand: slotComparisonFor(kWhoopGen5).asBand,
  asSensor: slotComparisonFor(sensor).asSensor,
);

/// "Pair a sensor without a band?" True when the user chose to go ahead.
Future<bool> showSensorWithoutBandSheet(BuildContext c,
    {required BandEntry sensor}) async {
  final l = pairL10n(c);
  final choice = await showPairChoiceSheet(
    c,
    PairChoiceSheet(
      title: l.pairNoBandTitle,
      body: l.pairNoBandBody,
      comparison: sensorVersusBand(sensor),
      bandHeading: l.slotABandHeading,
      sensorHeading: sensor.kind == DeviceKind.chestStrap
          ? l.slotThisStrapHeading
          : l.slotThisDeviceHeading,
      primaryLabel: l.pairAsSensorAnyway,
      backLabel: l.pairGoBack,
    ),
  );
  return choice == PairChoice.primary;
}
