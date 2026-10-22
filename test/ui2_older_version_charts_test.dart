// RULES B.2 on chart surfaces that read through the shared ChartPoint path:
// the month grid (strain cells + scrub readout), the Data Explorer scrub
// readout and the Workout 7-day heart-effort bars. A flagged point's readout
// carries the asterisk and the note; a current or absent day carries neither.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/month_grid.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart'
    show specOf, WorkoutScreen;
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/explorer_harness.dart';
import 'support/older_version_fixtures.dart';

void main() {
  setUpAll(() async {
    await initPrefs();
    await loadType();
  });

  setUp(clearPrefs);

  group('month grid', () {
    Future<void> host(WidgetTester t, List<Map<String, dynamic>> strain) async {
      t.view.physicalSize = const Size(390 * 3, 1600 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final rows = await loadGridRows(
          OlderRepo(charts: {specOf('strain').chartKey: strain}));
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: SingleChildScrollView(child: MonthGrid(rows))),
      ));
      await t.pumpAndSettle();
    }

    Future<void> scrubToday(WidgetTester t) async {
      final strip = find.byWidgetPredicate(
          (w) => w is ChartScrub && w.label == specOf('strain').title);
      final r = t.getRect(strip);
      await t.tapAt(Offset(r.right - 3, r.center.dy));
      await t.pump();
    }

    testWidgets('a flagged day: scrub readout asterisk + note, row spoken',
        (t) async {
      final h = t.ensureSemantics();
      await host(t, series(30, flagged: {0, 1}));
      expect(find.bySemanticsLabel(kSpoken), findsWidgets,
          reason: 'the strain row says some days are from an older calculation');
      await scrubToday(t);
      expect(olderMark('readout'), findsOneWidget);
      expect(find.textContaining(kNoteV104), findsWidgets);
      h.dispose();
    });

    testWidgets('a current day: no marker; the row still says some days are older',
        (t) async {
      final h = t.ensureSemantics();
      await host(t, series(30, flagged: {5, 6}));
      expect(find.bySemanticsLabel(kSpoken), findsWidgets);
      await scrubToday(t);
      expect(olderMark('readout'), findsNothing);
      h.dispose();
    });

    testWidgets('no flagged day anywhere: nothing is marked', (t) async {
      final h = t.ensureSemantics();
      await host(t, series(30));
      expect(anyOlderMarker(), findsNothing);
      expect(find.bySemanticsLabel(kSpoken), findsNothing);
      await scrubToday(t);
      expect(anyOlderMarker(), findsNothing);
      h.dispose();
    });

    testWidgets('a gap day inside flagged days stays a gap, unmarked',
        (t) async {
      await host(t, series(30, flagged: {0, 2}, gaps: {1}));
      await scrubToday(t); // today flagged
      expect(olderMark('readout'), findsOneWidget);
      final strip = find.byWidgetPredicate(
          (w) => w is ChartScrub && w.label == specOf('strain').title);
      final r = t.getRect(strip);
      await t.tapAt(Offset(r.right - 3 - r.width / 30, r.center.dy));
      await t.pump();
      expect(olderMark('readout'), findsNothing, reason: 'the gap day');
    });
  });

  group('Explorer scrub readout', () {
    List<Map<String, dynamic>> pts() => [
          pt('2026-09-30', 7),
          {...pt('2026-10-01', 8), 'from_older_version': 104},
          pt('2026-10-03', 9),
        ];

    Future<void> open(WidgetTester t) async {
      await pumpExplorer(
          t, ExplorerRepo(charts: {specOf('strain').chartKey: pts()}));
      await tapKey(t, 'explore-range:d7');
      await tapKey(t, 'explore-pick:strain');
    }

    testWidgets('the flagged day: real value, asterisk and note', (t) async {
      await open(t);
      await scrubAt(t, 3.5 / 7); // 1 Oct
      expect(readoutText(t, specOf('strain').title), contains('8'));
      expect(olderMark('readout'), findsOneWidget);
      expect(find.textContaining(kNoteV104), findsWidgets);
    });

    testWidgets('a current day beside it: no marker', (t) async {
      await open(t);
      await scrubAt(t, 5.5 / 7); // 3 Oct
      expect(readoutText(t, specOf('strain').title), contains('9'));
      expect(anyOlderMarker(), findsNothing);
    });

    testWidgets('a day with no row reads — and takes no marker', (t) async {
      await open(t);
      await scrubAt(t, 4.5 / 7); // 2 Oct
      expect(readoutText(t, specOf('strain').title), '—');
      expect(anyOlderMarker(), findsNothing);
    });
  });

  group('Workout 7-day heart effort', () {
    Future<void> open(WidgetTester t, List<Map<String, dynamic>> trimp) async {
      t.view.physicalSize = const Size(390 * 3, 2400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final app = AppState.forTesting()
        ..repo = OlderRepo(charts: {'trimp': trimp});
      addTearDown(app.dispose);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ChangeNotifierProvider<AppState>.value(
            value: app, child: const Scaffold(body: WorkoutScreen())),
      ));
      for (var i = 0; i < 40; i++) {
        await t.pump(const Duration(milliseconds: 25));
      }
    }

    Future<void> scrubSlot(WidgetTester t, int slot) async {
      final strip = find.byWidgetPredicate(
          (w) => w is ChartScrub && w.label == 'Heart effort by day');
      await t.ensureVisible(strip);
      final r = t.getRect(strip);
      await t.tapAt(Offset(r.left + r.width * (slot + .5) / 7, r.center.dy));
      await t.pump();
    }

    testWidgets('the flagged day: asterisk and note in the readout',
        (t) async {
      await open(t, series(7, flagged: {0}, base: 40));
      await scrubSlot(t, 6);
      expect(find.textContaining(' points'), findsWidgets,
          reason: 'the scrub readout shows the value (7 base 40 + 0)');
      expect(olderMark('readout'), findsOneWidget);
      expect(find.textContaining(kNoteV104), findsWidgets);
    });

    testWidgets('a current day: no marker', (t) async {
      await open(t, series(7, flagged: {0}, base: 40));
      await scrubSlot(t, 2);
      expect(anyOlderMarker(), findsNothing);
    });

    testWidgets('a gap day: no marker', (t) async {
      await open(t, series(7, flagged: {0}, gaps: {3}, base: 40));
      await scrubSlot(t, 3);
      expect(anyOlderMarker(), findsNothing);
    });
  });
}
