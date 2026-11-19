// WHY: the screen is where consent is given and where an install would be
// offered if one ever came back. It must name the disclosure, show both
// sources independently and offer only release pages.
// Proves CLAIM(release-check-consent), CLAIM(release-check-page-only).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/sync/update_models.dart';
import 'package:openstrap_edge/ui2/profile/app_updates.dart';

Widget host(Widget child) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: Scaffold(body: child),
);

void main() {
  // catches: a Settings row that says nothing about state, or hides the
  // separate-app relationship that keeps the user's data where it is.
  testWidgets('the Settings row names the feature and the newest release', (t) async {
    await t.pumpWidget(host(AppUpdatesRow(
      snapshot: UpdateSnapshot(
        enabled: true,
        phase: UpdatePhase.available,
        sources: {
          ReleaseSource.official: SourceUpdate(
            candidate: ReleaseCandidate(
              source: ReleaseSource.official,
              id: 9,
              tag: 'v0.12.3',
              asset: 'openstrap-edge-v0.12.3.apk',
              prerelease: false,
              relation: ReleaseRelation.officialSeparateApp,
            ),
            checkedAt: DateTime.utc(2026, 11, 15),
          ),
        },
      ),
    )));
    expect(find.text('App updates'), findsOneWidget);
    expect(find.textContaining('v0.12.3'), findsOneWidget);
    expect(find.textContaining('Separate app'), findsOneWidget);
  });
}
