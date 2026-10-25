import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'backup/backup_support.dart';
import 'support/apk1_harness.dart';
import 'support/pin_tz.dart';

/// Real link, real AppShell, real Navigator. The destination must be a tab,
/// including when it is already selected, never another SleepDetail route.
Future<void> _jump(WidgetTester t, Finder link, Apk1Routes routes) async {
  await apk1Reveal(t, link);
  expect(link, findsOneWidget, reason: 'the production link must be built');
  final depth = routes.routes.length;
  final pushes = routes.pushes;
  await t.tap(link);
  await apk1Settle(t);
  expect(apk1Selected(t), ShellDomain.sleep.index,
      reason: 'a domain link selects Sleep in AppShell');
  expect(routes.routes, hasLength(depth), reason: 'no duplicate tab route');
  expect(routes.pushes, pushes, reason: 'do not push then immediately pop');
  expect(find.byType(SleepDetail), findsOneWidget);
  expect(t.widget<SleepDetail>(find.byType(SleepDetail)).embedded, isTrue,
      reason: 'the visible night is the Sleep tab root');
  expect(t.takeException(), isNull);

  // Repeated links must not lengthen tab history or leave an orphaned root.
  // The shell's existing Back contract returns to Today from a cold Sleep tab.
  await t.binding.handlePopRoute();
  await apk1Settle(t);
  expect(apk1Selected(t), ShellDomain.today.index);
  expect(routes.routes, hasLength(depth));
  expect(find.byType(SleepDetail), findsNothing,
      reason: 'Back must not reveal a pushed duplicate of the Sleep root');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  pinProcessTimeZone();
  late BackupEnv env;
  setUpAll(() async => env = await apk1Environment('apk1_jumps.db'));
  tearDownAll(() => env.dispose());
  setUp(apk1ClearPrefs);

  for (final scale in [1.0, 3.1]) {
    apk1Test('Home sleep ring selects the Sleep tab without a push at $scale', (t) async {
      final routes = Apk1Routes();
      await apk1Mount(t, routes: routes, scale: scale,
          source: HomeScreen(data: apk1Home(observation: null), now: apk1Now));
      // The dial's visible title, scoped to the ring card so it cannot hit
      // the Sleep tab-bar label. This is a pointer tap, not onOpen invocation.
      await _jump(t, find.descendant(of: apk1Rings, matching: find.text('SLEEP')), routes);
    });

    apk1Test('Home short-sleep why row selects the Sleep tab without a push at $scale', (t) async {
      final routes = Apk1Routes();
      await apk1Mount(t, routes: routes, scale: scale,
          source: HomeScreen(data: apk1Home(observation: null), now: apk1Now));
      await _jump(t, find.byKey(const ValueKey<String>('home-why:sleep')), routes);
    });

    apk1Test('sleep-plan recommendation reuses the selected Sleep tab at $scale', (t) async {
      final routes = Apk1Routes();
      await apk1Mount(t, routes: routes, scale: scale, initial: ShellDomain.sleep);
      // Real WellnessScreen(sleepPlanOnly: true) inside the real SleepTab.
      final link = find.text('See what last night cost you');
      await apk1Reveal(t, link);
      await _jump(t, link, routes);
    });

    apk1Test('a selected sleep-metric day opens in the Sleep tab without a push at $scale', (t) async {
      final routes = Apk1Routes();
      final repo = Apk1Repo();
      await apk1Mount(t, routes: routes, repo: repo, scale: scale,
        source: MetricDetail('sleep', initialRange: 7, data: MetricData(
          series: [for (var i = 0; i < 7; i++) ChartPoint(
            t: DateTime(2026, 9, 28 + i, 12).millisecondsSinceEpoch ~/ 1000,
            v: 420 + i.toDouble(),
          )], daysAvailable: 30,
        )),
      );
      // initialDay is only applied by the live load today. Drive the same
      // horizontal gesture a user makes instead of depending on that path in
      // an injected fixture. Slot 5 of 7 is 3 October, the chosen past day.
      final plot = find.byType(Scrubber).first;
      await apk1Reveal(t, plot);
      final box = t.getRect(plot);
      await t.dragFrom(Offset(box.left + box.width * .45, box.center.dy),
          Offset(box.width * (5 / 6 - .45), 0));
      await apk1Settle(t);
      // _picked's public semantic door exists today; do not depend on a
      // proposed tab-jump controller or a future widget class.
      final link = find.byWidgetPredicate((w) => w is Surface &&
          (w.semanticLabel ?? '').startsWith('Open ') && w.onTap != null);
      await _jump(t, link, routes);
      expect(repo.openedNights, contains('2026-10-03'),
          reason: 'switching domains must preserve the chosen calendar day');
    });
  }

  for (final (domain, destination) in <(ShellDomain, Widget)>[
    (ShellDomain.activity, const WorkoutScreen()),
    (ShellDomain.health, const HealthScreen()),
  ]) {
    apk1Test('${domain.label} links through go reuse the shell tab', (t) async {
      final routes = Apk1Routes();
      // Exercise the shared production link and navigation helper with both
      // non-sleep roots. Details keep their own routes; roots select domains.
      await apk1Mount(t, routes: routes, source: Builder(builder: (c) =>
        detailLinkRow(c, domain.icon, 'Open ${domain.label}', '',
            () => go(c, destination))));
      final link = find.text('Open ${domain.label}');
      final depth = routes.routes.length;
      final pushes = routes.pushes;
      for (var visit = 0; visit < 2; visit++) {
        await apk1Reveal(t, link);
        await t.tap(link);
        await apk1Settle(t);
        expect(apk1Selected(t), domain.index);
        expect(routes.routes, hasLength(depth));
        expect(routes.pushes, pushes);
        expect(find.byType(destination.runtimeType), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.binding.handlePopRoute();
        await apk1Settle(t);
        expect(apk1Selected(t), ShellDomain.today.index);
        expect(find.byType(destination.runtimeType), findsNothing);
      }
    });
  }

}
