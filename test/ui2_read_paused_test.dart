// Import focus, UI side, part 1: Home and the Sleep tab.
//
// While an import has the database to itself the repository THROWS
// ReadPaused('import') (lib/data/read_paused.dart) for every read except the
// models the engine published for today and yesterday (ImportFocus.days).
// The screens must:
//  * say nothing alarming about a paused read: no error text, no spinner that
//    never ends, no retry loop (the fake counts every read);
//  * put ONE line, "Older days load when the import finishes", where the
//    older data would be (inside the content, not stacked above it);
//  * draw today and yesterday from the published models;
//  * reload an older day once, by themselves, when focus ends.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/state/prefs.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/import_focus.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/screens/sleep_tab.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/read_paused_fakes.dart';

Future<void> _settle(WidgetTester t, {int n = 40}) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<AppState> _pump(WidgetTester t, FocusRepo repo, Widget home) async {
  t.view.physicalSize = const Size(390 * 3, 1800 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  app.repo = repo;
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<ThemeController>.value(
          value: ThemeController.seed(AppThemeChoice.light, Brightness.light)),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: home),
    ),
  ));
  await _settle(t);
  return app;
}

/// Nothing that reads as an error or an unfinished wait.
void _quiet() {
  expect(find.text('Today could not be read'), findsNothing);
  expect(find.textContaining('could not be read'), findsNothing);
  expect(find.textContaining('Try again'), findsNothing);
  expect(find.textContaining('ReadPaused'), findsNothing);
  expect(find.byType(CircularProgressIndicator), findsNothing);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetFocus();
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  tearDown(resetFocus);

  test('the line is an l10n string with the agreed words', () {
    expect(kPausedLine, 'Older days load when the import finishes');
  });

  group('Home', () {
    testWidgets('opened during focus: today is drawn from the published '
        'model, quietly', (t) async {
      startFocus();
      final repo = FocusRepo();
      await _pump(t, repo, const HomeScreen(hour: 9));

      expect(find.text('77'), findsOneWidget, reason: 'published readiness');
      expect(find.text('70'), findsNothing, reason: 'not the DB value');
      _quiet();
      expect(find.text(kPausedLine), findsNothing,
          reason: 'today is not an older day');
    });

    /// Focus starts while Home shows an older day (the day list is the
    /// import-time one: today and yesterday, plus the day on screen).
    Future<(FocusRepo, AppState)> onOlderDayThenFocus(WidgetTester t) async {
      final repo = FocusRepo();
      final app = await _pump(t, repo, const HomeScreen(hour: 9));
      await t.tap(find.bySemanticsLabel('Previous day'));
      await _settle(t);
      await t.tap(find.bySemanticsLabel('Previous day'));
      await _settle(t);
      expect(find.text('33'), findsOneWidget, reason: 'older day, loaded');
      startFocus();
      await _settle(t);
      return (repo, app);
    }

    testWidgets('focus starting on an older day: ITS numbers go, the line '
        'stands in the rings, nothing else moves', (t) async {
      final (repo, _) = await onOlderDayThenFocus(t);

      expect(find.text('33'), findsNothing,
          reason: 'a paused day shows NO numbers');
      expect(find.text('42'), findsNothing);
      expect(find.text('70'), findsNothing);
      expect(find.text(kPausedLine), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(RingTrio), matching: find.text(kPausedLine)),
          findsOneWidget,
          reason: 'the line is IN the rings card, not a row above it');
      _quiet();
      expect(repo.reads, isNotEmpty);
    });

    testWidgets('stepping onto published yesterday clears the pause: its '
        'numbers, no line; nothing older is reachable', (t) async {
      final (repo, _) = await onOlderDayThenFocus(t);
      final navAtOlder = t.getTopLeft(find.byType(DayNav));
      final ringsAtOlder = t.getTopLeft(find.byType(RingTrio));

      await t.tap(find.bySemanticsLabel('Next day'));
      await _settle(t);
      expect(find.text('61'), findsOneWidget);
      expect(find.text(kPausedLine), findsNothing,
          reason: 'a successful read un-pauses the screen');
      _quiet();
      expect(t.getTopLeft(find.byType(DayNav)), navAtOlder);
      expect(t.getTopLeft(find.byType(RingTrio)), ringsAtOlder);

      final d2Reads = repo.count('getDayOverview', kDay2);
      final prev = find.bySemanticsLabel('Previous day');
      if (prev.evaluate().isNotEmpty) {
        await t.tap(prev, warnIfMissed: false);
        await _settle(t);
      }
      expect(find.text('61'), findsOneWidget, reason: 'still yesterday');
      expect(repo.count('getDayOverview', kDay2), d2Reads,
          reason: 'during focus only today and yesterday are on offer');
    });

    testWidgets('warm Home: focus keeps the day list to today and '
        'yesterday', (t) async {
      final repo = FocusRepo();
      await _pump(t, repo, const HomeScreen(hour: 9));
      startFocus();
      await _settle(t);

      final prev = find.bySemanticsLabel('Previous day');
      await t.tap(prev);
      await _settle(t);
      expect(find.text('61'), findsOneWidget);
      if (prev.evaluate().isNotEmpty) {
        await t.tap(prev, warnIfMissed: false);
        await _settle(t);
      }
      expect(find.text('61'), findsOneWidget, reason: 'cannot go past yesterday');
      expect(repo.count('getDayOverview', kDay2), 0);
    });

    testWidgets('a paused day is not read again and again, whatever the '
        'revisions do', (t) async {
      final (repo, app) = await onOlderDayThenFocus(t);
      expect(find.text(kPausedLine), findsOneWidget);

      final before = repo.reads.length;
      await _settle(t, n: 400); // 8 s of frames
      for (var i = 0; i < 5; i++) {
        app.bumpInsights(); // a derive publishes again and again
        await _settle(t, n: 20);
      }
      expect(repo.reads.skip(before), isEmpty,
          reason: 'no read at all while the day is paused');
      expect(find.text(kPausedLine), findsOneWidget);
    });

    testWidgets('when focus ends the older day loads by itself, once, even '
        'with a trailing revision', (t) async {
      final (repo, app) = await onOlderDayThenFocus(t);
      final before = repo.count('getDayOverview', kDay2);

      endFocus();
      app.bumpInsights(); // the derive's last publish lands right behind it
      app.bumpInsights();
      await _settle(t);

      expect(find.text(kPausedLine), findsNothing);
      expect(find.text('33'), findsOneWidget, reason: 'the real value is in');
      expect(repo.count('getDayOverview', kDay2), before + 1,
          reason: 'exactly one reload, no more');
      final after = repo.reads.length;
      await _settle(t, n: 200);
      expect(repo.reads.length, after, reason: 'and it stays quiet');
    });

    testWidgets('cold start before anything is published: a quiet pending '
        'line, no spinner, no first-weeks guidance; then the publish lands',
        (t) async {
      startFocus(const {});
      final repo = FocusRepo();
      await _pump(t, repo, const HomeScreen(hour: 9));

      expect(find.text(kPendingLine), findsOneWidget);
      expect(find.textContaining('Crunching'), findsNothing);
      expect(find.text('Reading today'), findsNothing);
      expect(find.textContaining('No nights scored yet'), findsNothing);
      expect(find.textContaining('Wear the band'), findsNothing);
      _quiet();

      ImportFocus.days.value = publishedDays();
      await _settle(t);
      expect(find.text('77'), findsOneWidget);
      expect(find.text(kPendingLine), findsNothing);
    });

    group('published today goes through the normal mapping', () {
      Map<String, dynamic> payload({
        Map<String, dynamic> status = const {},
        Map<String, dynamic> daily = const {},
      }) =>
          {
            'daily': {
              'readiness': {'value': 55, 'confidence': .8, 'tier': 'HIGH'},
              'resting_hr': {'value': 58, 'confidence': .8, 'tier': 'HIGH'},
              ...daily,
            },
            'sleep': {
              'duration_min': {'value': 300, 'confidence': .8, 'tier': 'HIGH'},
            },
            'status': {'today_day': kToday, 'overnight_state': 'ready', ...status},
          };

      testWidgets("a prior overnight is not shown as today's", (t) async {
        startFocus({
          kToday: {
            'getToday': payload(status: {
              'showing_prior_overnight': true,
              'overnight_day': kYesterday,
              'overnight_state': 'building',
            }),
          },
        });
        await _pump(t, FocusRepo(), const HomeScreen(hour: 9));
        expect(find.text('55'), findsNothing, reason: "last night's recovery");
        expect(find.text('58'), findsNothing, reason: "last night's RHR");
        expect(find.text('5h 00m'), findsNothing, reason: "last night's sleep");
        _quiet();
      });

      testWidgets('provisional recovery is the provisional number, as on a '
          'normal load', (t) async {
        final p = payload(status: {
          'overnight_state': 'building',
          'recovery_state': 'provisional',
        }, daily: {
          'readiness_provisional': {'value': 48, 'confidence': .5, 'tier': 'ESTIMATE'},
        });
        // The same payload through the ordinary path.
        final normal = FocusRepo()..todayPayload = p;
        await _pump(t, normal, const HomeScreen(hour: 9));
        final normalShows48 = find.text('48').evaluate().length;
        final normalShows55 = find.text('55').evaluate().length;
        expect(normalShows48, 1, reason: 'sanity: the normal path');
        expect(normalShows55, 0);

        await t.pumpWidget(const SizedBox());
        startFocus({kToday: {'getToday': p}});
        await _pump(t, FocusRepo(), const HomeScreen(hour: 9));
        expect(find.text('48'), findsNWidgets(normalShows48));
        expect(find.text('55'), findsNothing);
      });
    });
  });

  group('Sleep tab', () {
    testWidgets("today's night is drawn from the published model, quietly",
        (t) async {
      startFocus();
      final repo = FocusRepo();
      await _pump(t, repo, const SleepTab());

      expect(
          find.descendant(
              of: find.byKey(const ValueKey('card:answer')),
              matching: find.text('7h 11m')),
          findsOneWidget,
          reason: 'published sleep.duration_min 431');
      expect(find.text('No night to show'), findsNothing);
      expect(find.textContaining('could not be read'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text(kPausedLine), findsNothing);
    });

    testWidgets('an older night says it loads later, with no retry loop, '
        'and reloads once when focus ends', (t) async {
      startFocus();
      final repo = FocusRepo();
      await _pump(t, repo, SleepDetail(day: kDay2));

      expect(find.text(kPausedLine), findsOneWidget);
      expect(find.text('No night to show'), findsNothing,
          reason: 'a paused night is not a missing night');
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('could not be read'), findsNothing);

      final before = repo.reads.length;
      await _settle(t, n: 400);
      expect(repo.reads.length, before, reason: 'no retry loop while paused');

      final bundles = repo.count('getSleepDetailBundle', kDay2);
      endFocus();
      await _settle(t);
      expect(find.text(kPausedLine), findsNothing);
      expect(repo.count('getSleepDetailBundle', kDay2), bundles + 1,
          reason: 'one reload when focus ends');
    });

    testWidgets('the SELECTED night decides: on yesterday, publishing today '
        'does not put today\'s sleep in its place', (t) async {
      final repo = FocusRepo();
      final app = await _pump(t, repo, const SleepDetail());
      await t.tap(find.bySemanticsLabel('Previous day'));
      await _settle(t);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('card:answer')),
              matching: find.text('4h 10m')),
          findsOneWidget,
          reason: 'yesterday, loaded');

      startFocus(); // today is published; yesterday has no sleep model
      await _settle(t);
      app.bumpInsights();
      await _settle(t);

      expect(find.text('7h 11m'), findsNothing,
          reason: "today's published night is not yesterday's");
      expect(find.text('4h 10m'), findsNothing);
      expect(find.text(kPausedLine), findsOneWidget);
    });

    testWidgets('revisions while an older night is paused read nothing; '
        'one reload after focus, trailing revision or not', (t) async {
      startFocus();
      final repo = FocusRepo();
      final app = await _pump(t, repo, SleepDetail(day: kDay2));
      final before = repo.reads.length;
      for (var i = 0; i < 5; i++) {
        app.bumpInsights();
        await _settle(t, n: 20);
      }
      expect(repo.reads.skip(before), isEmpty);

      final bundles = repo.count('getSleepDetailBundle', kDay2);
      endFocus();
      app.bumpInsights();
      app.bumpInsights();
      await _settle(t);
      expect(repo.count('getSleepDetailBundle', kDay2), bundles + 1);
    });
  });
}
