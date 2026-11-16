// WHY: the screen-reader pilot changes the semantics tree, not the pixels
// (owner bar "pixels unchanged" 7). These goldens were rendered on the BASE
// commit (integrate/next b3eacf0c6, before merging the a11y pilot) and must still
// match after it. A diff here is a bug in the pilot, unless the report lists
// the change as one a fix needs (error-text contrast). Refreshed base-first
// after the integrate/next merge; see edge.research/a11y-pilot-report.md,
// "Merge with integrate/next" for provenance and comparisons.
//
// CLAIM(a11y-pixels-unchanged): the shared widgets the pilot touches, the four
// tab roots and Sleep detail paint the same pixels as on the base commit.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'backup/backup_support.dart';
import 'support/apk1_harness.dart';
import 'support/pin_tz.dart';

Widget _sheet() => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SafeArea(
          child: Column(children: [
            const NavBar('Sleep detail', sub: 'Tue 3 Nov'),
            Expanded(
              child: ListView(padding: const EdgeInsets.all(16), children: [
                SubTabs(const ['Day', 'Week', 'Month'], 0, (_) {},
                    disabled: const {2}),
                Section(
                    'Stages',
                    Column(children: const [
                      StatusCard('Not enough nights', 'Needs 7 nights of sleep.'),
                      SizedBox(height: 8),
                      StatusCard('Band not connected', 'Pair it to score.',
                          fix: 'Pair a band'),
                    ]),
                    action: 'See all',
                    onAction: () {}),
                const SizedBox(height: 8),
                const InlineLoading(
                    status: 'Reading last night', detail: 'day 3 of 12'),
                const SizedBox(height: 8),
                DayNav(
                    day: '2026-11-15',
                    days: const ['2026-11-15', '2026-11-14'],
                    onDay: (_) {}),
                SettingsAccordion('Sleep',
                    summary: 'Goal 8 h', children: const [Text('row one')]),
                const SizedBox(height: 8),
                BigButton('Save', onTap: () {}),
                const SizedBox(height: 8),
                const BigButton('Save', onTap: null),
                const SizedBox(height: 8),
                BigButton('Saving', busy: true, onTap: () {}),
                const SizedBox(height: 8),
                InsightCard('Bed earlier', 'Three short nights in a row.',
                    action: 'See why', onTap: () {}),
              ]),
            ),
          ]),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  pinProcessTimeZone();
  late BackupEnv env;
  setUpAll(() async => env = await apk1Environment('a11y_pixels.db'));
  tearDownAll(() => env.dispose());
  setUp(apk1ClearPrefs);

  // Fonts come from apk1Environment (setUpAll): loading them inside a test
  // body waits on real file reads that fake async never completes.
  testWidgets('shared widgets', (t) async {
    t.view.physicalSize = const Size(720, 2400);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(_sheet());
    await t.pump(const Duration(milliseconds: 500));
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/a11y/grammar.png'));
  });

  for (final d in ShellDomain.values) {
    apk1Test('tab ${d.name}', (t) async {
      // hour: the greeting reads the wall clock, not package:clock, so an
      // unpinned Home says "Good afternoon" after noon and the golden moves.
      await apk1Mount(t, initial: d,
          source: HomeScreen(data: apk1Home(), now: apk1Now, hour: 9));
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/a11y/tab_${d.name}.png'));
    });
  }

  apk1Test('sleep detail', (t) async {
    await apk1Mount(t, page: SleepDetail(data: apk1Sleep()));
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/a11y/sleep_detail.png'));
  });
}
