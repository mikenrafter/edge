// Journal items on the Explorer: what is read, how it becomes annotations, and
// how the chart shows them.
//
// Fixed dates only. The pure half builds annotations from rows already read;
// the widget half injects the loader, so no database is opened.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/ui2/screens/explorer.dart';
import 'package:openstrap_edge/ui2/screens/explorer_annotations.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart' show specOf;
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/explorer_harness.dart';

const _day = '2026-10-03';
final int _start = localDayStartSec(_day)!;
final int _end = localDayEndSec(_day)!;
int _ts(int minute) => _start + minute * 60;

ChartAnnotation _item(String id, AnnotationKind k, int minute,
        {int? untilMinute, String? label}) =>
    ChartAnnotation(
        id: id,
        kind: k,
        at: _ts(minute).toDouble(),
        until: untilMinute == null ? null : _ts(untilMinute).toDouble(),
        label: label ?? id);

void main() {
  group('rangeAnnotations', () {
    test('every source becomes its own kind, on its own minute', () {
      final a = rangeAnnotations(
        from: '2026-10-03',
        to: '2026-10-04',
        sessions: [
          {'start_ts': _ts(18 * 60), 'end_ts': _ts(19 * 60), 'type': 'running'},
        ],
        momentLabels: [
          MomentLabel(date: _day, hhmm: '09:15', label: 'other', answeredAtMs: 1),
          MomentLabel(date: _day, hhmm: '11:00', label: 'water', answeredAtMs: 1),
        ],
        assumedWater: const [
          AssumedGlass(date: _day, atMin: 14 * 60, ml: 250),
        ],
        journalByDay: const {
          _day: {
            'water_ml': JournalMetricValue(500, atMinuteOfDay: 8 * 60),
            'caffeine': JournalMetricValue(1, atMinuteOfDay: 10 * 60),
            // No time: not placed anywhere.
            'alcohol': JournalMetricValue(2),
          },
        },
      );
      final by = {for (final x in a) x.at.toInt(): x};
      expect(a.length, 6);
      expect(by[_ts(8 * 60)]!.kind, AnnotationKind.water);
      expect(by[_ts(9 * 60 + 15)]!.kind, AnnotationKind.moment);
      expect(by[_ts(10 * 60)]!.kind, AnnotationKind.journal);
      expect(by[_ts(11 * 60)]!.kind, AnnotationKind.water);
      expect(by[_ts(14 * 60)]!.kind, AnnotationKind.assumedWater);
      expect(by[_ts(18 * 60)]!.kind, AnnotationKind.workout);
      expect(by[_ts(18 * 60)]!.until, _ts(19 * 60).toDouble());
    });

    test('days outside from..to are left out', () {
      final a = rangeAnnotations(
        from: '2026-10-03',
        to: '2026-10-03',
        momentLabels: [
          MomentLabel(
              date: '2026-10-02', hhmm: '09:15', label: 'other', answeredAtMs: 1),
          MomentLabel(
              date: '2026-10-04', hhmm: '09:15', label: 'other', answeredAtMs: 1),
        ],
      );
      expect(a, isEmpty);
    });

    test('the same minute on two days gives two different ids', () {
      final a = rangeAnnotations(
        from: '2026-10-03',
        to: '2026-10-04',
        momentLabels: [
          MomentLabel(date: _day, hhmm: '09:15', label: 'other', answeredAtMs: 1),
          MomentLabel(
              date: '2026-10-04', hhmm: '09:15', label: 'other', answeredAtMs: 1),
        ],
      );
      expect(a.length, 2);
      expect({for (final x in a) x.id}.length, 2);
    });

    test('nothing read, nothing made up', () {
      expect(rangeAnnotations(from: _day, to: _day), isEmpty);
    });

    test('a skipped moment (no label) is not an annotation', () {
      final a = rangeAnnotations(
        from: _day,
        to: _day,
        momentLabels: [
          MomentLabel(date: _day, hhmm: '09:15', label: null, answeredAtMs: 1),
        ],
      );
      expect(a, isEmpty);
    });
  });

  group('in the Explorer', () {
    setUpAll(() async {
      await initPrefs();
      await loadType();
    });
    setUp(clearPrefs);

    ExplorerRepo repo() => ExplorerRepo(timelines: {
          _day: {
            'date': _day,
            'day_start': _start,
            'hr': [
              for (var m = 480; m < 540; m++) {'t': _ts(m), 'v': 60 + (m - 480)},
            ],
          },
        });

    Future<List<(String, String)>> openDay(WidgetTester t,
        List<ChartAnnotation> items) async {
      final calls = <(String, String)>[];
      await pumpExplorer(t, repo(),
          today: '2026-10-04',
          annotationLoader: (a, b) async {
            calls.add((a, b));
            return items;
          });
      await tapKey(t, 'explore-scale:day');
      await tapKey(t, 'explore-day-prev');
      await tapKey(t, 'explore-pick:hr');
      await settle(t);
      return calls;
    }

    testWidgets('a day shows its items at their minute, except what is a band',
        (t) async {
      await openDay(t, [
        _item('w', AnnotationKind.water, 9 * 60, label: 'Drank water'),
        _item('m', AnnotationKind.moment, 15 * 60),
        _item('run', AnnotationKind.workout, 18 * 60, untilMinute: 19 * 60),
      ]);
      expect(find.byKey(ChartAnnotationLane.iconKey('w')), findsOneWidget);
      expect(find.byKey(ChartAnnotationLane.iconKey('m')), findsOneWidget);
      expect(find.byKey(ChartAnnotationLane.iconKey('run')), findsNothing,
          reason: 'workouts are already a shaded band with a legend entry');
      final plot = t.getRect(find.byKey(ExplorerView.plotKey));
      final lane = t.getRect(find.byKey(ChartAnnotationLane.laneKey));
      expect(lane.left, moreOrLessEquals(plot.left, epsilon: .5));
      final cp = t.widget<CustomPaint>(find.byKey(ChartAnnotationLane.linesKey));
      final line = (cp.painter as AnnotationLinesPainter)
          .lines
          .firstWhere((l) => l.id == 'w');
      expect(line.x,
          moreOrLessEquals(plot.width * (9 * 60 * 60) / (_end - _start), epsilon: .5));
    });

    testWidgets('scrubbing near an item bolds it; far from every item does not',
        (t) async {
      await openDay(t, [
        _item('w', AnnotationKind.water, 9 * 60, label: 'Drank water'),
      ]);
      final plot = t.getRect(find.byKey(ExplorerView.plotKey));
      final x9 = plot.width * (9 * 60 * 60) / (_end - _start);
      await t.tapAt(Offset(plot.left + x9 + 20, plot.center.dy));
      await t.pump();
      expect(t.widget<AnnotationIcon>(find.byKey(ChartAnnotationLane.iconKey('w'))).bold,
          isTrue,
          reason: '20 px away is inside the reach of two icons');
      expect(find.text('Drank water'), findsOneWidget);
      await t.tapAt(Offset(plot.left + x9 + 150, plot.center.dy));
      await t.pump();
      expect(t.widget<AnnotationIcon>(find.byKey(ChartAnnotationLane.iconKey('w'))).bold,
          isFalse,
          reason: '150 px away is out of reach: nearest-however-far is not used here');
      expect(find.text('Drank water'), findsNothing);
    });

    testWidgets('a loader that fails leaves the lines and no lane', (t) async {
      await pumpExplorer(t, repo(),
          today: '2026-10-04',
          annotationLoader: (_, _) async => throw StateError('no store'));
      await tapKey(t, 'explore-scale:day');
      await tapKey(t, 'explore-day-prev');
      await tapKey(t, 'explore-pick:hr');
      expect(plotLine(t, 'hr').runs, isNotEmpty);
      expect(find.byKey(ChartAnnotationLane.laneKey), findsNothing);
    });

    testWidgets('no items, no lane and no extra height', (t) async {
      await openDay(t, const []);
      expect(find.byKey(ChartAnnotationLane.laneKey), findsNothing);
    });

    testWidgets('the loader is asked for the shown day, again for another',
        (t) async {
      final calls = await openDay(t, const []);
      expect(calls.last, (_day, _day));
      await tapKey(t, 'explore-day-prev');
      expect(calls.last, ('2026-10-02', '2026-10-02'));
    });

    testWidgets('the daily scale puts a day\'s items in the middle of its slot',
        (t) async {
      final r = ExplorerRepo(charts: {
        specOf('resting_hr').chartKey: [
          for (final d in kWeek) pt(d, 55),
        ],
      });
      final calls = <(String, String)>[];
      await pumpExplorer(t, r, annotationLoader: (a, b) async {
        calls.add((a, b));
        // Thursday 1 Oct at 09:00 local.
        return [
          ChartAnnotation(
              id: 'w',
              kind: AnnotationKind.water,
              at: DateTime(2026, 10, 1, 9).millisecondsSinceEpoch / 1000,
              label: 'Drank water'),
        ];
      });
      await tapKey(t, 'explore-range:d7');
      await tapKey(t, 'explore-pick:resting_hr');
      await settle(t);
      expect(calls.last, ('2026-09-28', '2026-10-04'));
      final plot = t.getRect(find.byKey(ExplorerView.plotKey));
      final cp = t.widget<CustomPaint>(find.byKey(ChartAnnotationLane.linesKey));
      final line = (cp.painter as AnnotationLinesPainter).lines.single;
      // 1 Oct is the fourth day of seven: slot 3, plotted at (3 + .5) / 7.
      expect(line.x, moreOrLessEquals(plot.width * 3.5 / 7, epsilon: .5));
    });
  });
}
