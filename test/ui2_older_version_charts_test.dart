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

import 'support/chart_harness.dart';
import 'support/older_version_fixtures.dart';

void main() {
  setUpAll(() async {
    await initPrefs();
    await loadType();
  });


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
      final r = t.getRect(find.descendant(of: strip, matching: find.byType(Scrubber)));
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
      expect(find.textContaining(kNoteV104), findsOneWidget,
          reason: 'the on-load strip only; the scrub adds no row');
      h.dispose();
    });

    testWidgets('a trailing gap: the at-rest readout is the last real day '
        'and carries its flag', (t) async {
      await host(t, series(30, flagged: {1}, gaps: {0}));
      expect(olderMark('readout'), findsOneWidget);
    });

    testWidgets('cell boundaries: value and flag come from the same day',
        (t) async {
      // Flagged: days 3 and 4 back. Read the row's own category from the
      // readout and compare with the flag on 30 slots, at and between centres.
      await host(t, series(30, flagged: {3}));
      final strip = find.byWidgetPredicate(
          (w) => w is ChartScrub && w.label == specOf('strain').title);
      final r = t.getRect(find.descendant(of: strip, matching: find.byType(Scrubber)));
      for (var slot = 0; slot < 30; slot++) {
        for (final off in [.02, .5, .98]) {
          await t.tapAt(Offset(r.left + r.width * (slot + off) / 30, r.center.dy));
          await t.pump();
          final back = 29 - slot;
          expect(olderMark('readout').evaluate().isNotEmpty, back == 3,
              reason: 'slot $slot (+$off), $back days back');
        }
      }
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
      final r = t.getRect(find.descendant(of: strip, matching: find.byType(Scrubber)));
      await t.tapAt(Offset(r.right - 3 - r.width / 30, r.center.dy));
      await t.pump();
      expect(olderMark('readout'), findsNothing, reason: 'the gap day');
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
      expect(find.textContaining(kNoteV104), findsOneWidget,
          reason: 'today is older: the on-load strip, and nothing from the scrub');
    });

    testWidgets('a current day: no marker', (t) async {
      await open(t, series(7, flagged: {0}, base: 40));
      await scrubSlot(t, 2);
      expect(olderMark('readout'), findsNothing);
      // (today is older, so the on-load strip is on the page; the scrub adds none)
    });

    testWidgets('a gap day: no marker', (t) async {
      await open(t, series(7, flagged: {0}, gaps: {3}, base: 40));
      await scrubSlot(t, 3);
      expect(olderMark('readout'), findsNothing);
      // (today is older, so the on-load strip is on the page; the scrub adds none)
    });

    Future<void> scrubAtFrac(WidgetTester t, double f) async {
      final strip = find.byWidgetPredicate(
          (w) => w is ChartScrub && w.label == 'Heart effort by day');
      await t.ensureVisible(strip);
      final r = t.getRect(strip);
      await t.tapAt(Offset(r.left + r.width * f, r.center.dy));
      await t.pump();
    }

    testWidgets('bar boundaries: the flag follows the bar the value is read '
        'from', (t) async {
      // Only the oldest bar (slot 0, 6 days back) is older, and only it is 99.
      final pts = [
        for (var back = 6; back >= 0; back--)
          cp(back, back == 6 ? 99 : 40 + back, older: back == 6 ? 104 : null),
      ];
      await open(t, pts);
      for (final f in [0.01, 0.10, 0.14, 0.1428, 0.1429, 0.15, 0.20, 0.28,
          0.29, 0.5, 0.99]) {
        await scrubAtFrac(t, f);
        final v99 = find.textContaining('99 ').evaluate().isNotEmpty;
        expect(olderMark('readout').evaluate().isNotEmpty, v99,
            reason: 'at $f: value 99 shown = $v99');
      }
    });

    testWidgets('trailing gap: the at-rest readout is the last real bar and '
        'carries its flag', (t) async {
      await open(t, series(7, flagged: {1}, gaps: {0}, base: 40));
      expect(olderMark('readout'), findsOneWidget);
    });

    testWidgets('the readout is spoken and its note is not hidden from '
        'screen readers', (t) async {
      final h = t.ensureSemantics();
      await open(t, series(7, flagged: {0}, base: 40));
      await scrubSlot(t, 6);
      final slider = find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.slider == true &&
              w.properties.label == 'Heart effort by day');
      // The slider says only the short form; the strip carries the full note.
      expect(t.getSemantics(slider).value, contains('older calculation'));
      expect(find.bySemanticsLabel(RegExp(r'From an older calculation \(v104\)')),
          findsWidgets);
      h.dispose();
    });

    testWidgets('the note wraps: no overflow at 320 pt and 3x text',
        (t) async {
      t.view.physicalSize = const Size(320 * 3, 2400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final app = AppState.forTesting()
        ..repo = OlderRepo(charts: {
          'trimp': [
            for (var back = 6; back >= 0; back--)
              {
                ...cp(back, 40 + back, older: back == 0 ? 104 : null),
                if (back == 0) 'older_version_reason': kReasonRaw,
              },
          ]
        });
      addTearDown(app.dispose);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (c, w) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(3)),
            child: w!),
        home: ChangeNotifierProvider<AppState>.value(
            value: app, child: const Scaffold(body: WorkoutScreen())),
      ));
      for (var i = 0; i < 40; i++) {
        await t.pump(const Duration(milliseconds: 25));
      }
      await scrubAtFrac(t, 0.95);
      expect(olderMark('readout'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
