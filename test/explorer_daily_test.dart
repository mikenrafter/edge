// 8AH, RED. The daily scale: one shared day grid, gaps that stay gaps,
// per-metric normalisation, z against a baseline only where one exists, the
// scrub readout with REAL values, ranges, loading and failure.
//
// ASSUMED API: test/support/explorer_harness.dart, explorer_series_test.dart.
//   * A daily metric is read with repo.getChart(specOf(key).chartKey) and
//     aligned by LOCAL day label onto ExploreWindow (default range d30).
//   * The painter's lines are the NORMALISED runs (ExploreLine.normalised);
//     a metric with no reading in the window has NO line (not a zero line)
//     and shows ValueKey('explore-empty:<key>').
//   * z history = every point getChart returned for that metric (the whole
//     stored series, not just the window); baseline = exploreBaseline(history).
//   * explore-z:<key> toggles that metric's z mode; it is disabled, with the
//     reason from exploreZUnavailable shown in ValueKey('explore-z-reason:<key>'),
//     where z is not on offer.
//   * Readout labels are the MetricSpec titles; the time row is
//     ChartScrub.day(that local day); a value reads "<n> <unit>", "—" if absent.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/explorer_series.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/explorer.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart' show specOf;
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/explorer_harness.dart';

List<Map<String, dynamic>> _pts(Iterable<int> idx, double Function(int) v) =>
    [for (final i in idx) pt(kWeek[i], v(i))];

/// The local day [back] days before today, as a label.
String _back(int back) {
  final d = DateTime(2026, 10, 4 - back);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// 40 nights of resting HR ending today, a repeating 50..55.
List<Map<String, dynamic>> _forty() =>
    [for (var i = 0; i < 40; i++) pt(_back(i), 50.0 + (i % 6))];

/// resting HR on every day of the week but 1 Oct, plus a wild reading well
/// outside any range under test; HRV missing 29 Sep and today.
ExplorerRepo _repo() => ExplorerRepo(charts: {
      specOf('resting_hr').chartKey: [
        pt('2026-09-20', 200),
        ..._pts([0, 1, 2, 4, 5, 6], (i) => 50.0 + i),
      ],
      specOf('hrv').chartKey: _pts([0, 2, 3, 4, 5], (i) => 60.0 + i),
    });

Future<void> _week7(WidgetTester t, ExplorerRepo repo) async {
  await pumpExplorer(t, repo);
  await tapKey(t, 'explore-range:d7');
  await tapKey(t, 'explore-pick:resting_hr');
  await tapKey(t, 'explore-pick:hrv');
}

void main() {
  setUpAll(() async {
    await initPrefs();
    await loadType();
  });
  setUp(clearPrefs);

  group('shared date grid', () {
    testWidgets('different missing days make gaps at exactly those days',
        (t) async {
      await _week7(t, _repo());
      final rhr = plotLine(t, 'resting_hr'), hrv = plotLine(t, 'hrv');
      expect(runLens(rhr), [3, 3], reason: '1 Oct is the break');
      expect(runLens(hrv), [1, 4], reason: '29 Sep is a hole, 4 Oct is a hole');
      // Same x for the same day on both lines.
      expect(rhr.runs.first.first.at, closeTo(.5 / 7, 1e-9));
      expect(rhr.runs.last.first.at, closeTo(4.5 / 7, 1e-9));
      expect(hrv.runs.first.first.at, closeTo(.5 / 7, 1e-9));
      expect(hrv.runs.last.first.at, closeTo(2.5 / 7, 1e-9));
      expect(hrv.runs.last.last.at, closeTo(5.5 / 7, 1e-9));
    });

    testWidgets('no point exists on a day with no reading (nothing interpolated)',
        (t) async {
      await _week7(t, _repo());
      final rhrAts = {
        for (final r in plotLine(t, 'resting_hr').runs)
          for (final p in r) double.parse(p.at.toStringAsFixed(6)),
      };
      expect(rhrAts.contains(double.parse((3.5 / 7).toStringAsFixed(6))), isFalse);
      // 6 real readings on one line and 5 on the other: exactly 11 points.
      final n = [
        for (final l in plotPainter(t).lines)
          for (final r in l.runs) r.length,
      ].fold<int>(0, (a, b) => a + b);
      expect(n, 11);
    });

    testWidgets('readings outside the window do not exist on the grid or the scale',
        (t) async {
      await _week7(t, _repo());
      // 200 bpm on 20 Sep is outside 7 days; the in-window max is 56, so the
      // top of the scale is 56, not 200: the day with 56 sits at exactly 1.0.
      final ys = [for (final r in plotLine(t, 'resting_hr').runs) for (final p in r) p.y];
      expect(ys.reduce((a, b) => a > b ? a : b), 1.0);
      expect(ys.reduce((a, b) => a < b ? a : b), 0.0);
    });

    testWidgets('a longer range puts the same day further right, same data',
        (t) async {
      final repo = ExplorerRepo(charts: {
        specOf('hrv').chartKey: [pt('2026-10-04', 60), pt('2026-09-24', 55)],
      });
      await pumpExplorer(t, repo);
      await tapKey(t, 'explore-pick:hrv');
      await tapKey(t, 'explore-range:d7');
      expect(runLens(plotLine(t, 'hrv')), [1],
          reason: '24 Sep is 10 days back: outside 7 days');
      expect(plotLine(t, 'hrv').runs.single.single.at, closeTo(6.5 / 7, 1e-9));
      await tapKey(t, 'explore-range:d30');
      expect(runLens(plotLine(t, 'hrv')), [1, 1]);
      expect(plotLine(t, 'hrv').runs.last.single.at, closeTo(29.5 / 30, 1e-9));
      await tapKey(t, 'explore-range:m6');
      expect(plotLine(t, 'hrv').runs.last.single.at, closeTo(179.5 / 180, 1e-9));
      await tapKey(t, 'explore-range:y1');
      expect(plotLine(t, 'hrv').runs.last.single.at, closeTo(364.5 / 365, 1e-9));
    });

    testWidgets('the default range is 30 days', (t) async {
      final repo = ExplorerRepo(charts: {
        specOf('hrv').chartKey: [pt('2026-10-04', 60)],
      });
      await pumpExplorer(t, repo);
      await tapKey(t, 'explore-pick:hrv');
      expect(plotLine(t, 'hrv').runs.single.single.at, closeTo(29.5 / 30, 1e-9));
    });
  });

  group('custom range', () {
    testWidgets('the custom chip opens the date-range picker; cancelling keeps the range',
        (t) async {
      await pumpExplorer(t, _repo());
      await tapKey(t, 'explore-pick:hrv');
      await tapKey(t, 'explore-range:d7');
      await t.tap(find.byKey(const ValueKey('explore-range:custom')));
      await settle(t, done: () => find.byType(DateRangePickerDialog).evaluate().isNotEmpty);
      expect(find.byType(DateRangePickerDialog), findsOneWidget);
      await t.binding.handlePopRoute();
      await settle(t);
      expect(find.byType(DateRangePickerDialog), findsNothing);
      expect(Prefs.getString(kExploreRangePref, ''), startsWith('d7'));
      expect(plotLine(t, 'hrv').runs.first.first.at, closeTo(.5 / 7, 1e-9));
    });

    testWidgets('a remembered custom span lays the grid over exactly those days',
        (t) async {
      Prefs.setString(kExploreRangePref, 'custom:2026-09-01..2026-09-20');
      final repo = ExplorerRepo(charts: {
        specOf('hrv').chartKey: [
          pt('2026-09-01', 50),
          pt('2026-09-05', 52),
          pt('2026-09-20', 54),
          pt('2026-09-21', 99), // one day past the span
        ],
      });
      await pumpExplorer(t, repo);
      await tapKey(t, 'explore-pick:hrv');
      final l = plotLine(t, 'hrv');
      expect(runLens(l), [1, 1, 1]);
      expect(l.runs[0].single.at, closeTo(.5 / 20, 1e-9));
      expect(l.runs[1].single.at, closeTo(4.5 / 20, 1e-9));
      expect(l.runs[2].single.at, closeTo(19.5 / 20, 1e-9));
    });
  });

  group('normalised', () {
    testWidgets('the chart says Normalised, plainly', (t) async {
      await _week7(t, _repo());
      final note = find.byKey(const ValueKey('explore-normalised-note'));
      expect(note, findsOneWidget);
      expect(t.widget<Text>(note).data, contains('Normalised'));
    });

    testWidgets('each metric spans 0..1 over its own range, on one chart',
        (t) async {
      await _week7(t, _repo());
      for (final k in ['resting_hr', 'hrv']) {
        final ys = [for (final r in plotLine(t, k).runs) for (final p in r) p.y];
        expect(ys.reduce((a, b) => a < b ? a : b), 0.0, reason: k);
        expect(ys.reduce((a, b) => a > b ? a : b), 1.0, reason: k);
      }
    });
  });

  group('z against a baseline', () {
    /// 40 stored nights of RHR so a baseline exists; HRV only 4 so it does not.
    ExplorerRepo repo() => ExplorerRepo(charts: {
          specOf('resting_hr').chartKey: _forty(),
          specOf('hrv').chartKey: [
            pt('2026-10-04', 60),
            pt('2026-10-03', 61),
            pt('2026-10-02', 62),
            pt('2026-10-01', 63),
          ],
          specOf('readiness').chartKey: [
            for (var i = 0; i < 20; i++)
              pt('2026-09-${(i + 10).toString().padLeft(2, '0')}', 60.0 + i),
          ],
        });

    testWidgets('on: the line is drawn as z, not min..max', (t) async {
      final r = repo();
      await pumpExplorer(t, r);
      await tapKey(t, 'explore-range:d7');
      await tapKey(t, 'explore-pick:resting_hr');
      final mm = [for (final x in plotLine(t, 'resting_hr').runs) for (final p in x) p.y];
      await tapKey(t, 'explore-z:resting_hr');

      final history = [
        for (final p in r.charts[specOf('resting_hr').chartKey]!) (p['v'] as num).toDouble(),
      ];
      expect(exploreZUnavailable('resting_hr', history), isNull);
      final base = exploreBaseline(history)!;
      final raw = [
        for (final x in plotLine(t, 'resting_hr').runs)
          for (final p in x) p.y
      ];
      expect(raw, isNot(mm));
      final expected = [
        for (final p in r.charts[specOf('resting_hr').chartKey]!)
          if ((p['t'] as int) >= DateTime(2026, 9, 28).millisecondsSinceEpoch ~/ 1000)
            exploreZ01((p['v'] as num).toDouble(), base),
      ]..sort();
      expect([...raw]..sort(), [for (final e in expected) closeTo(e, 1e-9)]);
      expect(t.widget<Text>(find.byKey(const ValueKey('explore-normalised-note'))).data,
          contains('baseline'));
    });

    testWidgets('off again: back to min..max', (t) async {
      await pumpExplorer(t, repo());
      await tapKey(t, 'explore-range:d7');
      await tapKey(t, 'explore-pick:resting_hr');
      final mm = [for (final x in plotLine(t, 'resting_hr').runs) for (final p in x) p.y];
      await tapKey(t, 'explore-z:resting_hr');
      await tapKey(t, 'explore-z:resting_hr');
      expect([for (final x in plotLine(t, 'resting_hr').runs) for (final p in x) p.y], mm);
    });

    testWidgets('disabled with a reason where there is not enough history',
        (t) async {
      final r = repo();
      await pumpExplorer(t, r);
      await tapKey(t, 'explore-range:d7');
      await tapKey(t, 'explore-pick:hrv');
      final before = [for (final x in plotLine(t, 'hrv').runs) for (final p in x) p.y];
      final reason = find.byKey(const ValueKey('explore-z-reason:hrv'));
      expect(reason, findsOneWidget, reason: 'the reason is on screen, not hidden');
      expect(t.widget<Text>(reason).data, contains('7'));
      await t.tap(find.byKey(const ValueKey('explore-z:hrv')), warnIfMissed: false);
      await settle(t);
      expect([for (final x in plotLine(t, 'hrv').runs) for (final p in x) p.y], before,
          reason: 'a disabled toggle changes nothing');
    });

    testWidgets('disabled for a score that is already built against a baseline',
        (t) async {
      await pumpExplorer(t, repo());
      await tapKey(t, 'explore-pick:readiness');
      expect(find.byKey(const ValueKey('explore-z-reason:readiness')), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('explore-z-reason:readiness'))).data,
          exploreZUnavailable('readiness', [for (var i = 0; i < 20; i++) 60.0 + i]));
    });

    testWidgets('where z is on offer there is no reason line', (t) async {
      await pumpExplorer(t, repo());
      await tapKey(t, 'explore-pick:resting_hr');
      expect(find.byKey(const ValueKey('explore-z-reason:resting_hr')), findsNothing);
      expect(find.byKey(const ValueKey('explore-z:resting_hr')), findsOneWidget);
    });
  });

  group('scrub readout: real values, never the normalised ones', () {
    testWidgets('lists each picked metric with its value and unit at that day',
        (t) async {
      await _week7(t, _repo());
      await scrubAt(t, 2.5 / 7); // 30 Sep
      expect(find.byKey(ChartScrub.cursorKey), findsOneWidget);
      final rhr = readoutText(t, specOf('resting_hr').title);
      final hrv = readoutText(t, specOf('hrv').title);
      expect(rhr, contains('52'));
      expect(rhr, contains('bpm'));
      expect(hrv, contains('62'));
      expect(hrv, contains('ms'));
      expect(
          find.descendant(
              of: find.byKey(ChartKeyReadout.timeKey),
              matching: find.text(ChartScrub.day(DateTime(2026, 9, 30)))),
          findsOneWidget);
    });

    testWidgets('a day one metric has no reading for reads "—" for it alone',
        (t) async {
      await _week7(t, _repo());
      await scrubAt(t, 3.5 / 7); // 1 Oct: RHR has no row
      expect(readoutText(t, specOf('resting_hr').title), '—');
      expect(readoutText(t, specOf('hrv').title), contains('63'));
      await scrubAt(t, 6.5 / 7); // 4 Oct: HRV has no row
      expect(readoutText(t, specOf('hrv').title), '—');
      expect(readoutText(t, specOf('resting_hr').title), contains('56'));
    });

    testWidgets('z mode still reads the real value, not a z', (t) async {
      final r = ExplorerRepo(charts: {
        specOf('resting_hr').chartKey: _forty(),
      });
      await pumpExplorer(t, r);
      await tapKey(t, 'explore-range:d7');
      await tapKey(t, 'explore-pick:resting_hr');
      await tapKey(t, 'explore-z:resting_hr');
      await scrubAt(t, 6.5 / 7); // 4 Oct is i = 0 -> 50
      expect(readoutText(t, specOf('resting_hr').title), contains('50'));
    });
  });

  group('loading and failure', () {
    testWidgets('a slow read shows InlineLoading in the chart section only',
        (t) async {
      final repo = _repo()..gate = Completer<void>();
      await pumpExplorer(t, repo);
      await tapKey(t, 'explore-range:d7');
      await tapKey(t, 'explore-pick:hrv');
      expect(find.byType(InlineLoading), findsOneWidget);
      // The controls are live while it waits.
      expect(find.byKey(const ValueKey('explore-range:d30')), findsOneWidget);
      expect(chip('hrv'), findsOneWidget);
      await tapKey(t, 'explore-range:d30');
      repo.gate!.complete();
      await settle(t, done: () => find.byType(InlineLoading).evaluate().isEmpty);
      expect(find.byType(InlineLoading), findsNothing);
      expect(find.byKey(ExplorerView.plotKey), findsOneWidget);
    });

    testWidgets('a read that throws is a retryable error, not an empty chart',
        (t) async {
      final repo = _repo()..failChart = 1;
      await pumpExplorer(t, repo);
      await tapKey(t, 'explore-range:d7');
      await tapKey(t, 'explore-pick:hrv');
      expect(find.byKey(const ValueKey('explore-retry')), findsOneWidget);
      expect(find.byKey(const ValueKey('explore-no-data')), findsNothing,
          reason: 'a failed read is not "no data"');
      expect(find.byKey(ExplorerView.plotKey), findsNothing);
      final calls = repo.chartCalls.length;
      await tapKey(t, 'explore-retry');
      expect(repo.chartCalls.length, greaterThan(calls));
      expect(find.byKey(const ValueKey('explore-retry')), findsNothing);
      expect(find.byKey(ExplorerView.plotKey), findsOneWidget);
    });
  });

  group('absent data draws nothing', () {
    testWidgets('a metric with no readings has no line and says so', (t) async {
      final repo = ExplorerRepo(charts: {
        specOf('resting_hr').chartKey: _pts([0, 1, 2], (i) => 50.0 + i),
      });
      await pumpExplorer(t, repo);
      await tapKey(t, 'explore-range:d7');
      await tapKey(t, 'explore-pick:resting_hr');
      await tapKey(t, 'explore-pick:hrv');
      expect([for (final l in plotPainter(t).lines) l.key], ['resting_hr']);
      expect(find.byKey(const ValueKey('explore-empty:hrv')), findsOneWidget);
      await scrubAt(t, 1.5 / 7);
      expect(readoutText(t, specOf('hrv').title), '—');
    });

    testWidgets('only empty metrics: no plot at all, an honest empty state',
        (t) async {
      await pumpExplorer(t, ExplorerRepo());
      await tapKey(t, 'explore-pick:hrv');
      expect(find.byKey(ExplorerView.plotKey), findsNothing);
      expect(find.byKey(const ValueKey('explore-no-data')), findsOneWidget);
      expect(chip('hrv'), findsOneWidget, reason: 'the pick is kept');
    });

    testWidgets('readings that all fall outside the window are not drawn',
        (t) async {
      final repo = ExplorerRepo(charts: {
        specOf('hrv').chartKey: [pt('2026-06-01', 60), pt('2026-06-02', 61)],
      });
      await pumpExplorer(t, repo);
      await tapKey(t, 'explore-range:d7');
      await tapKey(t, 'explore-pick:hrv');
      expect(find.byKey(ExplorerView.plotKey), findsNothing);
      expect(find.byKey(const ValueKey('explore-no-data')), findsOneWidget);
    });
  });
}

