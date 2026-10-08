// The ECG screener page (ecg-features): every state a reading can end in, in
// plain language, with a scholarly (DOI) link and a plain-language link where
// one applies. Content: lib/ecg/ecg_screener.dart and ecg_links.dart. Under the
// beats.dart rules: a screen, never a diagnosis, "not screened" distinct from
// "nothing flagged" (an outlined marker, not a colour), a permanent line that a
// result with nothing flagged does not mean you were cleared.
//
// The copy is in the ARBs (ecgScreener* keys, six locales); the page chrome
// below is still English literals.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ecg/ecg_links.dart';
import '../../ecg/ecg_screener.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'home_screen.dart' show pad;

class EcgScreenerScreen extends StatelessWidget {
  /// Opens a link; defaults to url_launcher. Tests hand in their own. Called
  /// with the link's EcgLink.url when a link row (key `ecg-link:<state>:<ref>`)
  /// is tapped.
  final Future<void> Function(Uri url)? openUrl;

  const EcgScreenerScreen({super.key, this.openUrl});

  Future<void> _open(Uri u) async {
    final open = openUrl;
    if (open != null) return open(u);
    await launchUrl(u, mode: LaunchMode.externalApplication);
  }

  static String _label(EcgLink l) {
    if (l.isDoi) return 'Clinical reference (DOI ${l.ref})';
    return switch (Uri.parse(l.url).host) {
      'medlineplus.gov' => 'Plain language: MedlinePlus',
      'www.nhs.uk' => 'Plain language: NHS',
      final h => 'Plain language: $h',
    };
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final loc = AppLocalizations.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        title: const Text('What the results mean'),
      ),
      body: ListView(
        padding: pad,
        children: [
          Text(
            ecgScreenerIntro(loc),
            style: F.body.copyWith(color: p.ink2, height: 1.4),
          ),
          const SizedBox(height: S.x3),
          // The supported heart-rate ranges, stated as this app's own reading
          // of the band's codes, never a validation of the device.
          Text(
            (loc ?? lookupAppLocalizations(const Locale('en'))).ecgRateMapping,
            key: const ValueKey('ecg-rate-mapping'),
            style: F.body.copyWith(color: p.ink2, height: 1.4),
          ),
          const SizedBox(height: S.x4),
          for (final e in ecgScreenerEntries(loc)) ...[
            Surface(
              key: ValueKey('ecg-states:${e.id}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.title, style: F.head.copyWith(color: p.ink)),
                  if (!e.screened) ...[
                    const SizedBox(height: S.x2),
                    Container(
                      key: const ValueKey('ecg-not-screened'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: S.x2,
                        vertical: S.x1,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: p.ink3),
                        borderRadius: R.rSm,
                      ),
                      child: Text(
                        'Not screened',
                        style: F.cap.copyWith(color: p.ink2),
                      ),
                    ),
                  ],
                  const SizedBox(height: S.x2),
                  Text(
                    e.meaning,
                    style: F.body.copyWith(color: p.ink2, height: 1.4),
                  ),
                  for (final l in kEcgLinks.where((l) => l.stateId == e.id))
                    Pressable(
                      key: ValueKey('ecg-link:${l.stateId}:${l.ref}'),
                      semanticLabel: _label(l),
                      onTap: () => _open(Uri.parse(l.url)),
                      child: Padding(
                        padding: const EdgeInsets.only(top: S.x2),
                        child: Row(
                          children: [
                            Icon(
                              l.isDoi
                                  ? LucideIcons.bookOpen
                                  : LucideIcons.externalLink,
                              size: 16,
                              color: p.on(C.blue),
                            ),
                            const SizedBox(width: S.x2),
                            Expanded(
                              child: Text(
                                _label(l),
                                style: F.cap.copyWith(
                                  color: p.on(C.blue),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: S.x3),
          ],
        ],
      ),
    );
  }
}
