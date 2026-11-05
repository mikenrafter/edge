// What to do when a device will not finish pairing: the steps for this device,
// or general steps clearly marked as general. Three states (ResetKind):
//  - specific: sourced steps for this device;
//  - unverified: general steps, an orange "we haven't checked" note and a row
//    that opens the maker's own help page;
//  - noOfficialSite: general steps and no link (the maker has no site).
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/adapters/_registry.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'pair_help.dart' show PairLinkOpener, SystemLinkOpener;
import 'pair_text.dart';
import 'pair_widgets.dart';

bool isWhoopEntry(BandEntry e) =>
    e.id == kWhoopGen4.id || e.id == kWhoopGen5.id;

/// The l10n key of every step to show for [e] (its own, else the general ones).
List<String> resetStepKeysFor(BandEntry e) {
  final r = e.resetSteps;
  if (r != null && r.kind == ResetKind.specific && r.keys!.isNotEmpty) {
    return r.keys!;
  }
  return kGenericResetStepKeys;
}

String resetStepText(AppLocalizations l, String key) => switch (key) {
  'pairResetWhoop5Step1' => l.pairResetWhoop5Step1,
  'pairResetWhoop5Step2' => l.pairResetWhoop5Step2,
  'pairResetWhoop5Step3' => l.pairResetWhoop5Step3,
  'pairResetWhoop5Step4' => l.pairResetWhoop5Step4,
  'pairResetGenericStep1' => l.pairResetGenericStep1,
  'pairResetGenericStep2' => l.pairResetGenericStep2,
  'pairResetGenericStep3' => l.pairResetGenericStep3,
  _ => key,
};

/// "Your ring is paired somewhere else" for a ring, the band wording for the rest.
String resetTitle(AppLocalizations l, BandEntry e) =>
    e.kind == DeviceKind.ring ? l.pairResetTitleRing : l.pairResetTitleBand;

class ResetStepsView extends StatelessWidget {
  final BandEntry entry;
  final PairLinkOpener openLink;
  const ResetStepsView(
      {super.key, required this.entry, this.openLink = const SystemLinkOpener()});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = pairL10n(c);
    final r = entry.resetSteps;
    final kind = r?.kind ?? ResetKind.noOfficialSite;
    final general = kind != ResetKind.specific;
    final url = kind == ResetKind.unverified ? r?.officialUrl : null;
    final keys = resetStepKeysFor(entry);
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (general) ...[
            // The orange note says so loudly for an unchecked device; a device
            // with no maker site gets the same sentence, muted.
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                    kind == ResetKind.unverified
                        ? LucideIcons.circleAlert
                        : LucideIcons.info,
                    size: 14,
                    color: kind == ResetKind.unverified
                        ? p.on(C.orange)
                        : p.ink3),
              ),
              const SizedBox(width: S.x2),
              Expanded(
                child: Text(l.pairResetGenericNote,
                    key: const ValueKey('reset-general-note'),
                    style: F.cap.copyWith(
                        color: kind == ResetKind.unverified
                            ? p.on(C.orange)
                            : p.ink3)),
              ),
            ]),
            const SizedBox(height: S.x3),
          ],
          Surface(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.pairResetHeading,
                      style: F.head.copyWith(color: p.ink)),
                  const SizedBox(height: S.x2),
                  for (var i = 0; i < keys.length; i++)
                    PairStepRow(i + 1, resetStepText(l, keys[i])),
                ]),
          ),
          if (isWhoopEntry(entry)) ...[
            const SizedBox(height: S.x3),
            Text(l.pairResetWhoopTakeover,
                key: const ValueKey('reset-whoop-takeover'),
                style: F.cap.copyWith(color: p.ink2)),
          ],
          if (url != null) ...[
            const SizedBox(height: S.x3),
            ChoiceRow(
              LucideIcons.externalLink,
              l.pairResetOfficialLink,
              l.pairResetOfficialSub(Uri.parse(url).host),
              trailing: LucideIcons.chevronRight,
              onTap: () => openLink.open(url),
            ),
          ],
        ]);
  }
}
