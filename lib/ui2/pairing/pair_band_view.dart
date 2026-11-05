// First-run "Pair your band": the devices that can be the user's main band,
// filter pills, and the ways out (a heart-rate strap only, "I can't pair my
// band", skip). It names only what a band sends; what a secondary sensor
// lacks is for the screens that pair one.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/adapters/_registry.dart';
import '../../ble/slot_comparison.dart';
import '../../l10n/display_text.dart';
import '../ui2.dart';
import 'category_filter_pills.dart';
import 'pair_choice_sheet.dart';
import 'pair_help.dart';
import 'pair_text.dart';
import 'pair_widgets.dart';

/// The devices the first run offers as the main band, in registry order.
List<BandEntry> firstRunBandEntries() => [
  for (final e in kBandRegistry)
    if (e.canBeMainDevice) e,
];

/// What a band would give next to what a plain heart-rate strap gives: the
/// app's own band (WHOOP 5) against the generic strap's sensor side.
SlotComparison strapVersusBand() => SlotComparison(
  asBand: slotComparisonFor(kWhoopGen5).asBand,
  asSensor: slotComparisonFor(kBleHrs).asSensor,
);

/// What the first-run list asks of the screen around it.
abstract interface class PairBandHost {
  /// A device row was tapped.
  void pickBand(BandEntry entry);

  /// The user confirmed pairing a heart-rate strap as a sensor (no band).
  void strapOnlyConfirmed();
}

class PairBandView extends StatefulWidget {
  final List<BandEntry> entries;
  final PairBandHost host;

  /// Non-null only at true first run: walk past pairing.
  final VoidCallback? onSkip;

  /// Non-null only alongside [onSkip]: fill the app with demo data instead.
  final VoidCallback? onDemoMode;
  final bool demoBusy;

  /// The last failure, in a sentence.
  final String? problem;
  final PairLinkOpener openLink;

  const PairBandView({
    super.key,
    required this.entries,
    required this.host,
    this.onSkip,
    this.onDemoMode,
    this.demoBusy = false,
    this.problem,
    this.openLink = const SystemLinkOpener(),
  });

  @override
  State<PairBandView> createState() => _PairBandViewState();
}

class _PairBandViewState extends State<PairBandView> {
  final _kind = ValueNotifier<DeviceKind?>(null);

  @override
  void initState() {
    super.initState();
    _kind.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _kind.dispose();
    super.dispose();
  }

  /// The device the user last tried, so "I can't pair my band" can offer its
  /// own help page.
  BandEntry? _tried;

  Future<void> _strapOnly() async {
    final l = pairL10n(context);
    final choice = await showPairChoiceSheet(
      context,
      PairChoiceSheet(
        title: l.pairNoBandTitle,
        body: l.pairNoBandBody,
        comparison: strapVersusBand(),
        bandHeading: l.slotABandHeading,
        sensorHeading: l.slotThisStrapHeading,
        primaryLabel: l.pairAsSensorAnyway,
        backLabel: l.pairGoBack,
      ),
    );
    if (choice == PairChoice.primary) widget.host.strapOnlyConfirmed();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = pairL10n(c);
    final shown = filterByKind(widget.entries, _kind.value);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          NavBar(l.pairBandTitle),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                Text(l.pairBandSubtitle, style: F.body.copyWith(color: p.ink2)),
                const SizedBox(height: S.x2),
                Text(l.pairMainBandWhoopOnly,
                    key: const ValueKey('main-band-whoop-only-note'),
                    style: F.cap.copyWith(color: p.ink3)),
                const SizedBox(height: S.x4),
                CategoryFilterPills(
                  kinds: [for (final e in widget.entries) e.kind],
                  selection: _kind,
                ),
                const SizedBox(height: S.x4),
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0) const SizedBox(height: S.x3),
                  _BandRow(
                    entry: shown[i],
                    onTap: () {
                      _tried = shown[i];
                      widget.host.pickBand(shown[i]);
                    },
                  ),
                ],
                if (widget.problem != null) ...[
                  const SizedBox(height: S.x4),
                  StatusCard(l.pairSensorThatDidNotWork, widget.problem!,
                      icon: LucideIcons.circleAlert),
                ],
                const SizedBox(height: S.x5),
                TextLinkButton(l.pairStrapOnlyLink, onTap: _strapOnly),
                OutlineAction(l.pairHelpButton,
                    icon: LucideIcons.circleHelp,
                    quiet: true,
                    onTap: () => showPairHelpDialog(c,
                        entry: _tried, openLink: widget.openLink)),
                if (widget.onSkip != null) ...[
                  const SizedBox(height: S.x2),
                  Row(children: [
                    Expanded(
                      child: BigButton(l.pairingSkipForNow,
                          color: C.blue, soft: true, onTap: widget.onSkip),
                    ),
                    if (widget.onDemoMode != null) ...[
                      const SizedBox(width: S.x3),
                      Expanded(
                        child: BigButton(
                          widget.demoBusy ? 'Setting up…' : 'Try demo mode',
                          icon: widget.demoBusy ? null : LucideIcons.sparkles,
                          color: C.orange,
                          soft: true,
                          onTap: widget.demoBusy ? null : widget.onDemoMode,
                        ),
                      ),
                    ],
                  ]),
                  const SizedBox(height: S.x2),
                  Text(l.pairingSkipNote,
                      style: F.cap.copyWith(color: p.ink3)),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _BandRow extends StatelessWidget {
  final BandEntry entry;
  final VoidCallback onTap;
  const _BandRow({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = pairL10n(c);
    final sends = sendsLine(l, entry);
    return Surface(
      key: ValueKey('band-row-${entry.id}'),
      onTap: onTap,
      child: Row(children: [
        Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
          child: Icon(deviceKindIcon(entry.kind), size: 24, color: p.ink2),
        ),
        const SizedBox(width: S.x3),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(uiText(c, entry.label),
                    style: F.body
                        .copyWith(color: p.ink, fontWeight: FontWeight.w600)),
                if (sends != null) ...[
                  const SizedBox(height: 2),
                  Text(sends, style: F.cap.copyWith(color: p.ink2)),
                ],
              ]),
        ),
        Icon(LucideIcons.chevronRight, size: 18, color: p.ink3),
      ]),
    );
  }
}
