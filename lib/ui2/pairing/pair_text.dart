// The words the pairing screens print for registry and slot-comparison data,
// in the user's language. Registry and compute code store l10n KEYS; this is
// the one place a key becomes text (a generated class has no lookup by name).
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/adapters/_registry.dart';
import '../../ble/slot_comparison.dart';
import '../../l10n/app_localizations.dart';

/// Localizations for [c]; English when none are mounted (a bare test widget),
/// the same fallback the rest of the pairing copy has.
AppLocalizations pairL10n(BuildContext c) =>
    AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));

String capabilityLabel(AppLocalizations l, DeviceCapability c) => switch (c) {
  DeviceCapability.sleep => l.capLabelSleep,
  DeviceCapability.recovery => l.capLabelRecovery,
  DeviceCapability.strain => l.capLabelStrain,
  DeviceCapability.hrv => l.capLabelHrv,
  DeviceCapability.skinTemperature => l.capLabelSkinTemperature,
  DeviceCapability.bloodOxygen => l.capLabelBloodOxygen,
  DeviceCapability.workoutHeartRate => l.capLabelWorkoutHeartRate,
  DeviceCapability.workoutBeatToBeat => l.capLabelWorkoutBeatToBeat,
  DeviceCapability.steps => l.capLabelSteps,
};

/// The one-line condition under a capability, or null when it has none.
String? capabilityReason(AppLocalizations l, CapabilityStatus s) =>
    switch (s.kind) {
      CapabilityKind.native => null,
      CapabilityKind.vendorReported => l.capVendorReported,
      CapabilityKind.conditional => switch (s.reasonKey) {
        kReasonSkinTempNights => l.capReasonSkinTempNights,
        kReasonEstimated => l.capReasonEstimated,
        kReasonEarly => l.capReasonEarly,
        _ => null,
      },
    };

String deviceKindLabel(AppLocalizations l, DeviceKind k) => switch (k) {
  DeviceKind.strap => l.pairKindStrap,
  DeviceKind.ring => l.pairKindRing,
  DeviceKind.watch => l.pairKindWatch,
  DeviceKind.band => l.pairKindBand,
  DeviceKind.chestStrap => l.pairKindChestStrap,
  DeviceKind.armband => l.pairKindArmband,
  DeviceKind.scale => l.pairKindScale,
  DeviceKind.thermometer => l.pairKindThermometer,
  DeviceKind.other => l.pairKindOther,
};

/// "Sends: sleep, recovery, …" for [e] as the main band: what this app
/// computes (native) or computes under a stated condition. A vendor's own
/// number is left off (it is not ours to list as sent). Null when nothing.
String? sendsLine(AppLocalizations l, BandEntry e) {
  final sends = slotComparisonFor(e).asBand.sends;
  final names = [
    for (final k in DeviceCapability.values)
      if (sends[k]?.kind == CapabilityKind.native ||
          sends[k]?.kind == CapabilityKind.conditional)
        _midSentence(l, capabilityLabel(l, k)),
  ];
  return names.isEmpty ? null : l.pairSendsLine(names.join(', '));
}

// German capitalises its nouns; the other locales that have case do not.
String _midSentence(AppLocalizations l, String s) =>
    l.localeName.startsWith('de') ? s : s.toLowerCase();

IconData deviceKindIcon(DeviceKind k) => switch (k) {
  DeviceKind.ring => LucideIcons.circleDot,
  DeviceKind.strap || DeviceKind.watch || DeviceKind.band => LucideIcons.watch,
  DeviceKind.scale => LucideIcons.scale,
  DeviceKind.thermometer => LucideIcons.thermometer,
  DeviceKind.chestStrap || DeviceKind.armband || DeviceKind.other =>
    LucideIcons.heartPulse,
};
