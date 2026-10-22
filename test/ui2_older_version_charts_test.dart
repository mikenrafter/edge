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
      final r = t.getRect(strip);
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

    testWidgets('every picked metric is flagged on its own, whatever the '
        'order', (t) async {
      // Resting HR (current) is picked FIRST, strain (older on 1 Oct) second.
      await pumpExplorer(
          t,
          ExplorerRepo(charts: {
            specOf('resting_hr').chartKey: [
              pt('2026-09-30', 50),
              pt('2026-10-01', 51),
              pt('2026-10-03', 52),
            ],
            specOf('strain').chartKey: pts(),
          }));
      await tapKey(t, 'explore-range:d7');
      await tapKey(t, 'explore-pick:resting_hr');
      await tapKey(t, 'explore-pick:strain');
      await scrubAt(t, 3.5 / 7); // 1 Oct: strain older, resting HR current
      expect(readoutText(t, specOf('strain').title), contains('8'));
      expect(readoutText(t, specOf('resting_hr').title), contains('51'));
      expect(olderMark('readout'), findsOneWidget);
      await scrubAt(t, 2.5 / 7); // 30 Sep: neither is older
      expect(anyOlderMarker(), findsNothing);
    });

    testWidgets('two older metrics on one day get two marks', (t) async {
      await pumpExplorer(
          t,
          ExplorerRepo(charts: {
            specOf('trimp').chartKey: [
              {...pt('2026-10-01', 40), 'from_older_version': 103},
            ],
            specOf('strain').chartKey: pts(),
          }));
      await tapKey(t, 'explore-range:d7');
      await tapKey(t, 'explore-pick:trimp');
      await tapKey(t, 'explore-pick:strain');
      await scrubAt(t, 3.5 / 7);
      expect(
          find.byWidgetPredicate((w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>)
                  .value
                  .startsWith('older-version-mark:')),
          findsNWidgets(2));
      expect(find.textContaining('(v103)'), findsWidgets);
      expect(find.textContaining('(v104)'), findsWidgets);
    });

    testWidgets('value and flag always come from the same day, also at the '
        'slot boundaries', (t) async {
      await open(t);
      // 1 Oct is the only flagged day and the only one that reads 8.
      for (final f in [
        0.30, 0.42, 0.427, 0.4285, 0.43, 0.45, 0.50, 0.56, 0.5713, 0.5714,
        0.572, 0.58, 0.70, 0.85
      ]) {
        await scrubAt(t, f);
        final v = readoutText(t, specOf('strain').title);
        expect(olderMark('readout').evaluate().isNotEmpty, v.contains('8'),
            reason: 'at $f the readout says "$v"');
      }
    });

    testWidgets('a trailing gap: the latest readout is the last real value, '
        'and carries its flag', (t) async {
      await pumpExplorer(
          t,
          ExplorerRepo(charts: {
            specOf('strain').chartKey: [
              pt('2026-10-02', 6),
              {...pt('2026-10-03', 8), 'from_older_version': 104},
            ],
          }));
      await tapKey(t, 'explore-range:d7');
      await tapKey(t, 'explore-pick:strain');
      // Nothing scrubbed: "Latest" is 3 Oct (today, 4 Oct, has no row).
      expect(readoutText(t, specOf('strain').title), contains('8'));
      expect(olderMark('readout'), findsOneWidget);
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
      expect(t.getSemantics(slider).value, matches(kSpoken));
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
