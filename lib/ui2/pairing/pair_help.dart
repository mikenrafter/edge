// H1: the "I can't pair my band" dialog. Two ways out: the maker's own help
// page (when the device has one) and the project's Discord. Links open in the
// user's own browser, never inside the app.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/adapters/_registry.dart';
import '../ui2.dart';
import 'pair_text.dart';
import 'pair_widgets.dart';

/// Opens a link outside the app; true when something took it. An interface
/// (not a function type) so tests pass a fake without an unresolved call.
abstract interface class PairLinkOpener {
  Future<bool> open(String url);
}

/// The real one: the user's own browser or app, never a WebView.
class SystemLinkOpener implements PairLinkOpener {
  const SystemLinkOpener();
  @override
  Future<bool> open(String url) => open3rdPartyLink(url);
}

/// The maker's official help page for [e], or null when the entry has none
/// (a no-official-site device, or nothing chosen yet).
String? officialHelpUrl(BandEntry? e) => e?.resetSteps?.officialUrl;

class PairHelpDialog extends StatelessWidget {
  /// The device the user is stuck on, or null when they have not chosen one
  /// (only the Discord choice is offered then).
  final BandEntry? entry;
  final PairLinkOpener openLink;

  const PairHelpDialog({
    super.key,
    required this.entry,
    this.openLink = const SystemLinkOpener(),
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = pairL10n(c);
    final url = officialHelpUrl(entry);
    return Dialog(
      backgroundColor: p.card,
      insetPadding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x6),
      shape: RoundedRectangleBorder(
          borderRadius: R.rXl, side: BorderSide(color: p.line)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(S.x4),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.pairHelpDialogTitle, style: F.t2.copyWith(color: p.ink)),
              const SizedBox(height: S.x4),
              if (url != null) ...[
                ChoiceRow(
                  LucideIcons.bluetooth,
                  l.pairHelpOfficialChoice,
                  l.pairHelpOfficialHint,
                  onTap: () => openLink.open(url),
                ),
                const SizedBox(height: S.x3),
              ],
              ChoiceRow(
                LucideIcons.messageCircle,
                l.pairHelpDiscordChoice,
                l.pairHelpDiscordHint,
                onTap: () => openLink.open(kDiscordUrl),
              ),
              const SizedBox(height: S.x2),
              TextLinkButton(l.pairHelpClose,
                  onTap: () => Navigator.of(c).pop()),
            ]),
      ),
    );
  }
}

/// Shows the dialog over the current screen.
Future<void> showPairHelpDialog(BuildContext c,
    {BandEntry? entry, PairLinkOpener openLink = const SystemLinkOpener()}) {
  return showDialog<void>(
    context: c,
    builder: (_) => PairHelpDialog(entry: entry, openLink: openLink),
  );
}
