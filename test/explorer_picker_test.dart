// 8AH, RED. The Explorer's picker: up to four metrics, one scale at a time,
// chips to remove, colours from the metric's own MetricSpec.
//
// ASSUMED API: see test/support/explorer_harness.dart (ExplorerView, its keys,
// ExplorePlotPainter) and test/explorer_series_test.dart
// (kExploreMaxMetrics, kExploreIntraday), plus
// lib/ui2/screens/metric_catalogue.dart: kMetricCatalogue, the Trends
// catalogue moved out of health_screen.dart so there is ONE list.
//   Picker chips:  ValueKey('explore-pick:<MetricSpec key>')   (daily)
//                  ValueKey('explore-pick:<kExploreIntraday key>') (day)
//   Chosen chips:  ValueKey('explore-chip:<key>'), text = the metric's title;
//                  tapping one removes it.
//   A daily metric whose MetricSpec has `suppress` (skin temperature) is not
//   offered in the daily picker: it must not be charted.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/explorer_series.dart';
import 'package:openstrap_edge/ui2/screens/explorer.dart';
import 'package:openstrap_edge/ui2/screens/metric_catalogue.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart' show specOf;

import 'support/explorer_harness.dart';

ExplorerRepo _repo() => ExplorerRepo(charts: {
      for (final k in const [
        'readiness',
        'resting_hr',
        'hrv',
        'steps',
        'stress',
        'sleep',
      ])
        specOf(k).chartKey: [for (final (i, d) in kWeek.indexed) pt(d, 40.0 + i)],
    });

void main() {
  setUpAll(() async {
    await initPrefs();
  });
  setUp(clearPrefs);

  testWidgets('opens with nothing chosen and says what to do, not a chart',
      (t) async {
    await pumpExplorer(t, _repo());
    expect(find.byType(ExplorerView), findsOneWidget);
    expect(find.byKey(ExplorerView.plotKey), findsNothing);
    for (final c in kMetricCatalogue) {
      for (final r in c.rows) {
        expect(chip(r.key), findsNothing);
      }
    }
  });

  testWidgets('the daily picker offers every Trends catalogue row it can chart',
      (t) async {
    await pumpExplorer(t, _repo());
    var offered = 0;
    for (final c in kMetricCatalogue) {
      for (final r in c.rows) {
        final charted = specOf(r.key).suppress == null;
        expect(pick(r.key).evaluate().length, charted ? 1 : 0,
            reason: '${r.key}: ${charted ? 'offered' : 'suppressed, not offered'}');
        if (charted) offered++;
      }
    }
    expect(offered, greaterThanOrEqualTo(20));
    expect(pick('skin_temp'), findsNothing,
        reason: 'its spec says there is no trend to draw');
  });

  testWidgets('picking adds a chip with the metric title and reads its chart',
      (t) async {
    final repo = _repo();
    await pumpExplorer(t, repo);
    await tapKey(t, 'explore-pick:readiness');
    expect(chip('readiness'), findsOneWidget);
    expect(
        find.descendant(
            of: chip('readiness'), matching: find.text(specOf('readiness').title)),
        findsOneWidget);
    expect(repo.chartCalls, contains(specOf('readiness').chartKey),
        reason: 'readiness is read under its chartKey, not its catalogue key');
  });

  testWidgets('picking the same metric twice does not add it twice',
      (t) async {
    await pumpExplorer(t, _repo());
    await tapKey(t, 'explore-pick:hrv');
    await tapKey(t, 'explore-pick:hrv');
    expect(chip('hrv').evaluate().length, lessThanOrEqualTo(1));
  });

  testWidgets('four are fine; a fifth is refused with a message', (t) async {
    final repo = _repo();
    await pumpExplorer(t, repo);
    for (final k in ['resting_hr', 'hrv', 'steps', 'stress']) {
      await tapKey(t, 'explore-pick:$k');
    }
    expect(kExploreMaxMetrics, 4);
    for (final k in ['resting_hr', 'hrv', 'steps', 'stress']) {
      expect(chip(k), findsOneWidget);
    }
    expect(find.text(ExplorerView.limitMessage), findsNothing,
        reason: 'no scolding before the limit is hit');

    final before = repo.chartCalls.length;
    await tapKey(t, 'explore-pick:sleep');
    expect(chip('sleep'), findsNothing);
    expect(find.text(ExplorerView.limitMessage), findsOneWidget);
    expect(ExplorerView.limitMessage, contains('4'));
    expect(repo.chartCalls.length, before, reason: 'a refused pick reads nothing');
    expect(plotPainter(t).lines.length, 4);
  });

  testWidgets('tapping a chip removes the metric, and the line, and frees a slot',
      (t) async {
    await pumpExplorer(t, _repo());
    for (final k in ['resting_hr', 'hrv', 'steps', 'stress']) {
      await tapKey(t, 'explore-pick:$k');
    }
    await tapKey(t, 'explore-chip:hrv');
    expect(chip('hrv'), findsNothing);
    expect([for (final l in plotPainter(t).lines) l.key],
        isNot(contains('hrv')));
    expect(plotPainter(t).lines.length, 3);

    await tapKey(t, 'explore-pick:sleep');
    expect(chip('sleep'), findsOneWidget);
    expect(find.text(ExplorerView.limitMessage), findsNothing);
  });

  testWidgets('removing the last metric removes the plot', (t) async {
    await pumpExplorer(t, _repo());
    await tapKey(t, 'explore-pick:hrv');
    expect(find.byKey(ExplorerView.plotKey), findsOneWidget);
    await tapKey(t, 'explore-chip:hrv');
    expect(find.byKey(ExplorerView.plotKey), findsNothing);
  });

  testWidgets('each line is drawn in its own MetricSpec colour', (t) async {
    await pumpExplorer(t, _repo());
    for (final k in ['resting_hr', 'hrv', 'steps', 'stress']) {
      await tapKey(t, 'explore-pick:$k');
    }
    for (final k in ['resting_hr', 'hrv', 'steps', 'stress']) {
      expect(plotLine(t, k).color, specOf(k).color, reason: k);
    }
  });

  testWidgets('chips keep the order the metrics were picked in', (t) async {
    await pumpExplorer(t, _repo());
    for (final k in ['steps', 'hrv', 'resting_hr']) {
      await tapKey(t, 'explore-pick:$k');
    }
    final xs = [for (final k in ['steps', 'hrv', 'resting_hr']) t.getTopLeft(chip(k))];
    // Wrapped chips may share a row (x grows) or start a new one (y grows).
    for (var i = 1; i < xs.length; i++) {
      final later = xs[i].dy > xs[i - 1].dy ||
          (xs[i].dy == xs[i - 1].dy && xs[i].dx > xs[i - 1].dx);
      expect(later, isTrue, reason: 'chip $i is after chip ${i - 1}');
    }
  });

  group('the day scale', () {
    testWidgets('offers the six intraday metrics and not the daily list',
        (t) async {
      await pumpExplorer(t, _repo());
      await tapKey(t, 'explore-scale:day');
      for (final s in kExploreIntraday) {
        expect(pick(s.key), findsOneWidget, reason: s.key);
      }
      expect(pick('steps'), findsNothing);
      expect(pick('readiness'), findsNothing);
    });

    testWidgets('has its own four-metric limit and its own chips', (t) async {
      await pumpExplorer(t, _repo());
      await tapKey(t, 'explore-pick:hrv');
      await tapKey(t, 'explore-scale:day');
      expect(chip('hrv'), findsNothing,
          reason: 'the daily pick is not an intraday pick');
      for (final k in ['hr', 'hrv', 'resp', 'activity']) {
        await tapKey(t, 'explore-pick:$k');
      }
      await tapKey(t, 'explore-pick:calories');
      expect(chip('calories'), findsNothing);
      expect(find.text(ExplorerView.limitMessage), findsOneWidget);
      // Back to daily: the daily pick is still there.
      await tapKey(t, 'explore-scale:daily');
      expect(chip('hrv'), findsOneWidget);
    });

    testWidgets('intraday chips take their colour from the matching MetricSpec',
        (t) async {
      final day = ExplorerRepo(timelines: {
        kToday: {
          'day_start': DateTime(2026, 10, 4).millisecondsSinceEpoch ~/ 1000,
          'date': kToday,
          'hr': [
            {'t': DateTime(2026, 10, 4, 8).millisecondsSinceEpoch ~/ 1000, 'v': 60},
            {'t': DateTime(2026, 10, 4, 8, 1).millisecondsSinceEpoch ~/ 1000, 'v': 61},
          ],
        },
      });
      await pumpExplorer(t, day);
      await tapKey(t, 'explore-scale:day');
      await tapKey(t, 'explore-pick:hr');
      final src = kExploreIntraday.singleWhere((s) => s.key == 'hr');
      expect(plotLine(t, 'hr').color, specOf(src.specKey).color);
    });
  });
}
