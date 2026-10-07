// The ECG screener page (ecg-features): every state a reading can end in, in
// plain language, with a scholarly (DOI) link and a plain-language link where
// one applies. Content: lib/ecg/ecg_screener.dart and ecg_links.dart. Under the
// beats.dart rules: a screen, never a diagnosis, "not screened" distinct from
// "nothing flagged", a permanent line that a result with nothing flagged does
// not mean you were cleared.
//
// RED stub: throws until the green phase.

import 'package:flutter/widgets.dart';

class EcgScreenerScreen extends StatelessWidget {
  /// Opens a link; defaults to url_launcher. Tests hand in their own. Called
  /// with the link's EcgLink.url when a link row (key `ecg-link:<ref>`) is tapped.
  final Future<void> Function(Uri url)? openUrl;

  const EcgScreenerScreen({super.key, this.openUrl});

  @override
  Widget build(BuildContext context) =>
      throw UnimplementedError('EcgScreenerScreen');
}
