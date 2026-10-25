// Older-calculation reasons on charts (spec cls-older-reasons-spec.md, mock v3):
//  1. scrubbing never adds, removes or changes a reason row;
//  2. when the AT-REST value is older its reason is a strip from the first
//     frame, unchanged while scrubbing, and takes no room otherwise;
//  3. consecutive older days are one algoVersion RANGE per run, labelled in the
//     lane's one fixed place;
//  4. no layout shift; 5. each status is spoken once.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/month_grid.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart'
    show MetricData, MetricDetail, specOf, WorkoutScreen;
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/explorer_harness.dart';
import 'support/older_version_fixtures.dart';

Finder get _strip => find.byIcon(LucideIcons.history);
Finder get _noteText => find.textContaining(kNoteV104);

void main() {
  setUpAll(() async {
    await initPrefs();
    await loadType();
  });
  setUp(clearPrefs);

  group('month grid (plain scrub row)', () {
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

    Future<void> scrubBack(WidgetTester t, int back) async {
      final r = t.getRect(find.byWidgetPredicate(
          (w) => w is ChartScrub && w.label == specOf('strain').title));
      await t.tapAt(Offset(r.left + r.width * (29 - back + .5) / 30, r.center.dy));
      await t.pump();
    }

    testWidgets('latest older: strip from the first frame, unchanged by a '
        'scrub, heights identical', (t) async {
      await host(t, series(30, flagged: {0, 1}));
      expect(olderNote('readout'), findsOneWidget);
      expect(_strip, findsOneWidget);
      final size = t.getSize(find.byType(MonthGrid));
      final at = t.getTopLeft(_strip);
      await scrubBack(t, 10); // a current day
      expect(_noteText, findsOneWidget);
      expect(_strip, findsOneWidget);
      expect(t.getTopLeft(_strip), at);
      expect(t.getSize(find.byType(MonthGrid)), size);
    });

    testWidgets('latest current: no strip; scrubbing onto an older day adds '
        'no row and no height', (t) async {
      await host(t, series(30, flagged: {5, 6}));
      expect(_strip, findsNothing);
      final size = t.getSize(find.byType(MonthGrid));
      await scrubBack(t, 5);
      expect(olderMark('readout'), findsOneWidget);
      expect(_noteText, findsNothing);
      expect(_strip, findsNothing);
      expect(t.getSize(find.byType(MonthGrid)), size);
    });

    testWidgets('a scrub onto another older day adds no second announcement',
        (t) async {
      final h = t.ensureSemantics();
      await host(t, series(30, flagged: {0, 5}));
      expect(spokenOlder(t, 104), 1, reason: 'the strip');
      await scrubBack(t, 5);
      expect(olderMark('readout'), findsOneWidget);
      expect(spokenOlder(t, 104), 1, reason: 'the slider value stays short');
      h.dispose();
    });

    testWidgets('spoken once', (t) async {
      final h = t.ensureSemantics();
      await host(t, series(30, flagged: {0}));
      expect(spokenOlder(t, 104), 1);
      await scrubBack(t, 0);
      expect(spokenOlder(t, 104), 1);
      h.dispose();
    });

    // The tinted run (owner-picked option A): a soft band behind each run of
    // consecutive older days, a label per run under the row title.
    Finder bands() => find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('month-older-band:'));
    Finder runLabels() => find.byWidgetPredicate((w) =>
        w is Text &&
        RegExp(r'^\w{3} \d{1,2}(\u2013[\w ]+)?: older calculation \(v104\)')
            .hasMatch(w.data ?? ''));

    testWidgets('one band per run, geometry per spec, behind the cells',
        (t) async {
      await host(t, series(30, flagged: {0, 1, 5, 6, 7}));
      expect(bands(), findsNWidgets(2));
      // The run 7..5 days back is slots 22..24; 30 equal cells across the strip.
      final strip = t.getRect(find.byWidgetPredicate(
          (w) => w is ChartScrub && w.label == specOf('strain').title));
      final cw = strip.width / 30;
      final r = t.getRect(find.byKey(const ValueKey('month-older-band:strain:22')));
      expect(r.left, closeTo(strip.left + 22 * cw + 1 - 2.5, .5));
      expect(r.width, closeTo(2 * cw + (cw - 2.5) + 5, .5));
      expect(r.height, closeTo(22 + 8, .5));
    });

    testWidgets('a band adds no height to the strip', (t) async {
      await host(t, series(30));
      final plain = t.getSize(find.byWidgetPredicate(
          (w) => w is ChartScrub && w.label == specOf('strain').title));
      await host(t, series(30, flagged: {5, 6}));
      expect(t.getSize(find.byWidgetPredicate(
              (w) => w is ChartScrub && w.label == specOf('strain').title)),
          plain);
    });

    testWidgets('one label per run, with the algoVersion icon', (t) async {
      await host(t, series(30, flagged: {0, 1, 5, 6, 7}));
      expect(runLabels(), findsNWidgets(2));
      expect(find.byIcon(LucideIcons.gitCommitVertical), findsNWidgets(2));
      await host(t, series(30));
      expect(find.byIcon(LucideIcons.gitCommitVertical), findsNothing);
      expect(bands(), findsNothing);
    });

    testWidgets('latest older: band, label and strip, each status spoken once',
        (t) async {
      final h = t.ensureSemantics();
      await host(t, series(30, flagged: {0, 1}));
      expect(bands(), findsNWidgets(1));
      expect(runLabels(), findsNWidgets(1));
      expect(_strip, findsOneWidget);
      expect(spokenOlder(t, 104), 1);
      h.dispose();
    });
  });

  group('Explorer', () {
    List<Map<String, dynamic>> older(Set<String> days, {int v = 104}) => [
          for (final d in [
            '2026-09-28', '2026-09-29', '2026-09-30', '2026-10-01',
            '2026-10-02', '2026-10-03',
          ])
            days.contains(d) ? {...pt(d, 7), 'from_older_version': v} : pt(d, 7),
        ];

    Future<void> open(WidgetTester t, Map<String, List<Map<String, dynamic>>> by,
        List<String> picks) async {
      await pumpExplorer(
          t, ExplorerRepo(charts: {for (final e in by.entries) specOf(e.key).chartKey: e.value}));
      await tapKey(t, 'explore-range:d7');
      for (final k in picks) {
        await tapKey(t, 'explore-pick:$k');
      }
    }

    testWidgets('scrubbing onto an older day: no note row, same heights',
        (t) async {
      await open(t, {'strain': older({'2026-10-01'})}, ['strain']);
      expect(_strip, findsNothing);
      final size = t.getSize(find.byType(ChartFrame));
      await scrubAt(t, 3.5 / 7);
      expect(olderMark('readout'), findsOneWidget);
      expect(_noteText, findsNothing);
      expect(t.getSize(find.byType(ChartFrame)), size);
    });

    testWidgets('latest older: strip on load, unchanged after a scrub',
        (t) async {
      await open(t, {'strain': older({'2026-10-03'})}, ['strain']);
      expect(olderNote('readout'), findsOneWidget);
      expect(_strip, findsOneWidget);
      final at = t.getTopLeft(_strip);
      final size = t.getSize(find.byType(ChartFrame));
      await scrubAt(t, 1.5 / 7);
      expect(_noteText, findsOneWidget);
      expect(t.getTopLeft(_strip), at);
      expect(t.getSize(find.byType(ChartFrame)), size);
    });

    testWidgets('one range per run of older days; the label is in the one '
        'fixed place and names the series', (t) async {
      await open(
          t,
          {'strain': older({'2026-09-29', '2026-09-30', '2026-10-02'})},
          ['strain']);
      final ranges = olderRanges(t);
      expect(ranges.length, 2, reason: 'runs: 29-30 Sep and 2 Oct');
      expect([for (final r in ranges) r.until! - r.at], [2.0, 1.0]);
      await scrubAt(t, 1.9 / 7);
      final first = find.byKey(ChartAnnotationLane.labelKey);
      expect(first, findsOneWidget);
      final text = t.widget<Text>(first).data!;
      expect(text, contains(specOf('strain').title));
      expect(text, contains('older calculation (v104)'));
      final at = t.getTopLeft(first);
      await scrubAt(t, 4.5 / 7);
      expect(t.getTopLeft(find.byKey(ChartAnnotationLane.labelKey)), at);
    });

    testWidgets('each series gets its own ranges, labelled by name',
        (t) async {
      await open(t, {
        'strain': older({'2026-09-29'}),
        'trimp': older({'2026-10-01'}, v: 103),
      }, ['strain', 'trimp']);
      final labels = [for (final r in olderRanges(t)) r.label];
      expect(labels.length, 2);
      expect(labels.where((l) => l.contains(specOf('strain').title)).length, 1);
      expect(labels.where((l) => l.contains(specOf('trimp').title)).length, 1);
    });

    testWidgets('no older day: no range, no strip', (t) async {
      await open(t, {'strain': older({})}, ['strain']);
      expect(olderRanges(t), isEmpty);
      expect(_strip, findsNothing);
    });

    testWidgets('spoken once', (t) async {
      final h = t.ensureSemantics();
      await open(t, {'strain': older({'2026-10-03'})}, ['strain']);
      expect(spokenOlder(t, 104), 1);
      h.dispose();
    });
  });

  group('Workout 7-day bars', () {
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

    Finder frame() => find.byWidgetPredicate(
        (w) => w is ChartFrame && w.title == 'Heart effort by day');

    testWidgets('latest older: strip on load; a scrub changes nothing',
        (t) async {
      await open(t, series(7, flagged: {0, 1}, base: 40));
      expect(olderNote('readout'), findsOneWidget);
      final size = t.getSize(frame());
      final at = t.getTopLeft(_strip);
      await scrubSlot(t, 1);
      expect(_noteText, findsOneWidget);
      expect(t.getTopLeft(_strip), at);
      expect(t.getSize(frame()), size);
    });

    testWidgets('latest current: no strip; scrub onto an older day adds no '
        'row', (t) async {
      await open(t, series(7, flagged: {3}, base: 40));
      expect(_strip, findsNothing);
      final size = t.getSize(frame());
      await scrubSlot(t, 3);
      expect(olderMark('readout'), findsOneWidget);
      expect(_noteText, findsNothing);
      expect(t.getSize(frame()), size);
    });

    testWidgets('one range per run', (t) async {
      // 6 and 5 days back (slots 0, 1), then 2 days back (slot 4).
      await open(t, series(7, flagged: {6, 5, 2}, base: 40));
      final ranges = olderRanges(t);
      expect(ranges.length, 2);
      expect([for (final r in ranges) r.until! - r.at], [2.0, 1.0]);
    });

    testWidgets('spoken once', (t) async {
      final h = t.ensureSemantics();
      await open(t, series(7, flagged: {0}, base: 40));
      expect(spokenOlder(t, 104), 1);
      h.dispose();
    });
  });

  group('Metric detail', () {
    Future<void> pump(WidgetTester t, List<Map<String, dynamic>> pts,
        {String? window}) async {
      t.view.physicalSize = const Size(390 * 3, 1800 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final d = await MetricData.load(
          OlderRepo(charts: {specOf('strain').chartKey: pts}), 'strain',
          journal: false);
      await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: MetricDetail('strain', data: d))));
      await t.pumpAndSettle();
      if (window != null) {
        await t.tap(find.text(window));
        await t.pumpAndSettle();
      }
    }

    Finder slider() => find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.slider == true);

    Finder panel() => find.byKey(ChartKeyReadout.panelKey);

    testWidgets('the latest reason is ONE strip on load, inside the panel',
        (t) async {
      final h = t.ensureSemantics();
      await pump(t, series(10, flagged: {0}), window: '7 days');
      expect(_strip, findsOneWidget);
      expect(
          find.descendant(of: panel(), matching: olderNote('readout')),
          findsOneWidget,
          reason: 'the strip lives in the inset now');
      expect(olderNote('headline'), findsNothing);
      expect(olderNote('latest'), findsNothing);
      expect(spokenOlder(t, 104), 1);
      h.dispose();
    });

    testWidgets('a scrub onto an older day adds no note and moves nothing',
        (t) async {
      await pump(t, series(10, flagged: {3}), window: '7 days');
      final before = t.getSize(find.byType(ChartFrame).first);
      final rect = t.getRect(panel());
      expect(olderNote('headline'), findsOneWidget);
      expect(_strip, findsOneWidget);
      await t.tapAt(t.getCenter(slider()));
      await t.pumpAndSettle();
      expect(olderNote('selected'), findsNothing);
      expect(olderNote('readout'), findsNothing);
      expect(
          find.descendant(of: panel(), matching: olderMark('readout')),
          findsOneWidget,
          reason: 'the compact * rides with the scrubbed value');
      expect(t.getSize(find.byType(ChartFrame).first), before);
      expect(t.getRect(panel()), rect);
      expect(olderNote('headline'), findsOneWidget);
      expect(_strip, findsOneWidget);
    });

    testWidgets('one range per run of older days', (t) async {
      await pump(t, series(10, flagged: {3, 4}), window: '7 days');
      final ranges = olderRanges(t);
      expect(ranges.length, 1);
      expect(ranges.single.until! - ranges.single.at, 2.0);
    });

    testWidgets('the panel is the same height on a current and an older day',
        (t) async {
      await pump(t, series(10, flagged: {3}), window: '7 days');
      final r = t.getRect(slider());
      await t.tapAt(Offset(r.right - 3, r.center.dy)); // today: current
      await t.pumpAndSettle();
      expect(olderMark('readout'), findsNothing);
      final current = t.getRect(panel());
      await t.tapAt(t.getCenter(slider())); // 3 days back: older
      await t.pumpAndSettle();
      expect(olderMark('readout'), findsOneWidget);
      expect(t.getRect(panel()), current);
    });

    testWidgets('selected older day: spoken once', (t) async {
      final h = t.ensureSemantics();
      await pump(t, series(10, flagged: {3}), window: '7 days');
      await t.tapAt(t.getCenter(slider()));
      await t.pumpAndSettle();
      expect(t.getSemantics(slider()).value, contains('older calculation'));
      expect(t.getSemantics(slider()).value, isNot(matches(kSpoken)));
      expect(spokenOlder(t, 104), 1,
          reason: 'the headline strip speaks the full explanation once');
      h.dispose();
    });
  });
}
