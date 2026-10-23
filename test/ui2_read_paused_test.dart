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

import 'package:openstrap_edge/state/app_state.dart';
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

Future<void> _pump(WidgetTester t, FocusRepo repo, Widget home) async {
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
  setUp(resetFocus);
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

    testWidgets('stepping onto yesterday shows its published numbers; onto '
        'an older day shows the line, in place', (t) async {
      final repo = FocusRepo();
      await _pump(t, repo, const HomeScreen(hour: 9));
      expect(find.text('70'), findsOneWidget);

      startFocus();
      await t.tap(find.bySemanticsLabel('Previous day'));
      await _settle(t);
      expect(find.text('61'), findsOneWidget,
          reason: "yesterday's published readiness");
      _quiet();
      expect(find.text(kPausedLine), findsNothing);
      final navAtYesterday = t.getTopLeft(find.byType(DayNav));
      final ringsAtYesterday = t.getTopLeft(find.byType(RingTrio));

      await t.tap(find.bySemanticsLabel('Previous day'));
      await _settle(t);
      expect(find.text(kPausedLine), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(RingTrio), matching: find.text(kPausedLine)),
          findsOneWidget,
          reason: 'the line stands where the rings help text is, '
              'not in an extra row above');
      _quiet();
      expect(t.getTopLeft(find.byType(DayNav)), navAtYesterday,
          reason: 'no layout shift');
      expect(t.getTopLeft(find.byType(RingTrio)), ringsAtYesterday,
          reason: 'no row was inserted above the rings');
    });

    testWidgets('a paused day is not read again and again', (t) async {
      final repo = FocusRepo();
      await _pump(t, repo, const HomeScreen(hour: 9));
      startFocus();
      await t.tap(find.bySemanticsLabel('Previous day'));
      await _settle(t);
      await t.tap(find.bySemanticsLabel('Previous day'));
      await _settle(t);
      expect(find.text(kPausedLine), findsOneWidget);

      final before = repo.reads.length;
      await _settle(t, n: 400); // 8 s of frames
      expect(repo.reads.length, before,
          reason: 'no retry loop while paused: ${repo.reads.skip(before)}');
    });

    testWidgets('when focus ends the older day loads by itself, once',
        (t) async {
      final repo = FocusRepo();
      await _pump(t, repo, const HomeScreen(hour: 9));
      startFocus();
      await t.tap(find.bySemanticsLabel('Previous day'));
      await _settle(t);
      await t.tap(find.bySemanticsLabel('Previous day'));
      await _settle(t);
      expect(find.text('33'), findsNothing);
      final before = repo.count('getDayOverview', kDay2);

      endFocus();
      await _settle(t);

      expect(find.text(kPausedLine), findsNothing);
      expect(find.text('33'), findsOneWidget, reason: 'the real value is in');
      expect(repo.count('getDayOverview', kDay2), before + 1,
          reason: 'exactly one reload, no more');
      final after = repo.reads.length;
      await _settle(t, n: 200);
      expect(repo.reads.length, after, reason: 'and it stays quiet');
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
  });
}
