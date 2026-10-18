// Journal items on the Explorer: what is read, how it becomes annotations, and
// how the chart shows them.
//
// Fixed dates only. The pure half builds annotations from rows already read;
// the widget half injects the loader, so no database is opened.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/compute/explorer_series.dart'
    show ExploreBandKind;
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
      // The water total at 08:00 is an aggregate of the other water events,
      // not a sixth thing that happened.
      expect(a.length, 5);
      expect(by[_ts(8 * 60)], isNull);
      expect(by[_ts(9 * 60 + 15)]!.kind, AnnotationKind.moment);
      expect(by[_ts(10 * 60)]!.kind, AnnotationKind.journal);
      expect(by[_ts(11 * 60)]!.kind, AnnotationKind.water);
      expect(by[_ts(14 * 60)]!.kind, AnnotationKind.assumedWater);
      expect(by[_ts(18 * 60)]!.kind, AnnotationKind.workout);
      expect(by[_ts(18 * 60)]!.until, _ts(19 * 60).toDouble());
    });

    group('one real event, one annotation of its true kind', () {
      // `logAssumedWater` writes the assumed_water row AND adds to the day's
      // timed water_ml total; an answered water tap writes the label AND adds
      // to the same total. The total is never a second event.
      List<ChartAnnotation> water({
        List<AssumedGlass> glasses = const [],
        List<MomentLabel> taps = const [],
        Map<String, JournalMetricValue> journal = const {},
      }) =>
          rangeAnnotations(
            from: _day,
            to: _day,
            assumedWater: glasses,
            momentLabels: taps,
            journalByDay: {_day: journal},
          );

      test('an assumed glass is a droplet and nothing else', () {
        final a = water(
          glasses: const [AssumedGlass(date: _day, atMin: 14 * 60, ml: 250)],
          journal: const {
            'water_ml': JournalMetricValue(250, atMinuteOfDay: 14 * 60),
          },
        );
        expect([for (final x in a) x.kind], [AnnotationKind.assumedWater],
            reason: 'no normal-water icon, so no "+1" cluster either');
      });

      test('an answered water tap is one water mark', () {
        final a = water(
          taps: [
            MomentLabel(
                date: _day, hhmm: '11:00', label: 'water', answeredAtMs: 1),
          ],
          journal: const {
            'water_ml': JournalMetricValue(250, atMinuteOfDay: 11 * 60),
          },
        );
        expect([for (final x in a) x.kind], [AnnotationKind.water]);
      });

      test('several glasses and taps are exactly that many marks', () {
        final a = water(
          glasses: const [
            AssumedGlass(date: _day, atMin: 10 * 60, ml: 250),
            AssumedGlass(
                date: _day,
                atMin: 14 * 60,
                ml: 250,
                state: AssumedState.kept),
          ],
          taps: [
            MomentLabel(
                date: _day, hhmm: '11:00', label: 'water', answeredAtMs: 1),
          ],
          journal: const {
            'water_ml': JournalMetricValue(750, atMinuteOfDay: 14 * 60),
          },
        );
        expect(a.length, 3);
        expect(a.where((x) => x.kind == AnnotationKind.assumedWater).length, 2);
        expect(a.where((x) => x.kind == AnnotationKind.water).length, 1);
      });

      test('a removed latest glass leaves no water mark at its old slot', () {
        // removeAssumedWater subtracts the ml but keeps the row's at_min, so a
        // surviving total still points at the REMOVED 15:00 slot.
        final a = water(
          glasses: const [AssumedGlass(date: _day, atMin: 10 * 60, ml: 250)],
          journal: const {
            'water_ml': JournalMetricValue(250, atMinuteOfDay: 15 * 60),
          },
        );
        expect([for (final x in a) x.at], [_ts(10 * 60).toDouble()]);
        expect(a.single.kind, AnnotationKind.assumedWater);
      });

      test('a total with no event behind it is not a mark', () {
        expect(
            water(journal: const {
              'water_ml': JournalMetricValue(500, atMinuteOfDay: 8 * 60),
            }),
            isEmpty);
      });
    });

    test('an unfinished workout is a point at its start, never a made-up end',
        () {
      // end_ts is NULL while a session is live (or was never closed). The only
      // thing known is when it began; shading to "now" would claim it is still
      // going, so it stays a point mark.
      final a = rangeAnnotations(
        from: _day,
        to: _day,
        sessions: [
          {'start_ts': _ts(18 * 60), 'end_ts': null, 'type': 'running'},
        ],
      );
      expect(a.single.kind, AnnotationKind.workout);
      expect(a.single.at, _ts(18 * 60).toDouble());
      expect(a.single.until, isNull);
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

  group('napAnnotations', () {
    test('a detected nap is a range of kind nap on its day', () {
      final a = napAnnotations(_day, {
        'day_start': _start,
        'naps': [
          {'start': _ts(14 * 60), 'end': _ts(14 * 60 + 40), 'duration_min': 40},
        ],
      });
      expect(a.length, 1);
      expect(a.single.kind, AnnotationKind.nap);
      expect(a.single.id, '$_day/nap:${_ts(14 * 60)}');
      expect(a.single.at, _ts(14 * 60).toDouble());
      expect(a.single.until, _ts(14 * 60 + 40).toDouble());
    });

    test('no naps, or a timeline without them, make nothing', () {
      expect(napAnnotations(_day, {'day_start': _start, 'naps': const []}),
          isEmpty);
      expect(napAnnotations(_day, const {}), isEmpty);
    });

    test('only naps: sleep, sessions and the rest of the timeline are not read',
        () {
      final a = napAnnotations(_day, {
        'day_start': _start,
        'sleep': [
          {'onset_ts': _ts(-60), 'wake_ts': _ts(420)},
        ],
        'sessions': [
          {'start_ts': _ts(1020), 'end_ts': _ts(1080), 'type': 'running'},
        ],
      });
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
        List<ChartAnnotation> items,
        {ExplorerRepo? over}) async {
      final calls = <(String, String)>[];
      await pumpExplorer(t, over ?? repo(),
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

    testWidgets('a day shows its items at their minute', (t) async {
      await openDay(t, [
        _item('w', AnnotationKind.water, 9 * 60, label: 'Drank water'),
        _item('m', AnnotationKind.moment, 15 * 60),
      ]);
      expect(find.byKey(ChartAnnotationLane.iconKey('w')), findsOneWidget);
      expect(find.byKey(ChartAnnotationLane.iconKey('m')), findsOneWidget);
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

    List<AnnotationLine> lines(WidgetTester t) => (t
            .widget<CustomPaint>(find.byKey(ChartAnnotationLane.linesKey))
            .painter as AnnotationLinesPainter)
        .lines;

    testWidgets(
        'a workout is an orange dumbbell range with dashed edges, not a band '
        'with a legend entry', (t) async {
      await openDay(t, [
        _item('run', AnnotationKind.workout, 18 * 60, untilMinute: 19 * 60),
      ],
          over: ExplorerRepo(timelines: {
            _day: {
              'date': _day,
              'day_start': _start,
              'hr': [
                for (var m = 480; m < 540; m++) {'t': _ts(m), 'v': 60 + (m - 480)},
              ],
              // The same workout the band used to be drawn from.
              'sessions': [
                {'start_ts': _ts(18 * 60), 'end_ts': _ts(19 * 60)},
              ],
            },
          }));
      expect(t.widget<AnnotationIcon>(find.byKey(ChartAnnotationLane.iconKey('run'))).kind,
          AnnotationKind.workout);
      expect(annotationColor(AnnotationKind.workout), C.orange);
      expect(annotationIcon(AnnotationKind.workout), LucideIcons.dumbbell);
      final shade = find.byKey(ChartAnnotationLane.shadeKey('run'));
      expect(shade, findsOneWidget);
      expect(t.widget<ColoredBox>(shade).color.withValues(alpha: 1).toARGB32(),
          C.orange.toARGB32());
      expect(lines(t).where((l) => l.id == 'run' || l.id == 'run:end'),
          hasLength(2),
          reason: 'both ends are dashed lines');
      expect([for (final b in plotPainter(t).bands) b.kind],
          isNot(contains(ExploreBandKind.workout)));
      expect(find.text('Workout'), findsNothing,
          reason: 'the Workout legend entry went with the band');
    });

    testWidgets('a nap is an indigo bed range, not a band', (t) async {
      final nap = '$_day/nap:${_ts(14 * 60)}';
      await pumpExplorer(
          t,
          ExplorerRepo(timelines: {
            _day: {
              'date': _day,
              'day_start': _start,
              'hr': [
                for (var m = 480; m < 540; m++) {'t': _ts(m), 'v': 60 + (m - 480)},
              ],
              'naps': [
                {'start': _ts(14 * 60), 'end': _ts(14 * 60 + 40), 'duration_min': 40},
              ],
            },
          }),
          today: '2026-10-04');
      await tapKey(t, 'explore-scale:day');
      await tapKey(t, 'explore-day-prev');
      await tapKey(t, 'explore-pick:hr');
      await settle(t);
      expect(t.widget<AnnotationIcon>(find.byKey(ChartAnnotationLane.iconKey(nap))).kind,
          AnnotationKind.nap);
      expect(annotationColor(AnnotationKind.nap), C.indigo);
      expect(annotationIcon(AnnotationKind.nap), LucideIcons.bedDouble);
      expect(find.byKey(ChartAnnotationLane.shadeKey(nap)), findsOneWidget);
      expect(lines(t).where((l) => l.id == nap || l.id == '$nap:end'),
          hasLength(2));
      expect(plotPainter(t).bands, isEmpty,
          reason: 'a nap used to be drawn as a sleep-coloured band');
    });

    testWidgets(
        'with only Calories picked, the day\'s workouts and naps are still '
        'drawn: annotations do not depend on which metrics are selected',
        (t) async {
      final nap = '$_day/nap:${_ts(14 * 60)}';
      final repo = ExplorerRepo(
        timelines: {
          _day: {
            'date': _day,
            'day_start': _start,
            'naps': [
              {'start': _ts(14 * 60), 'end': _ts(14 * 60 + 40), 'duration_min': 40},
            ],
          },
        },
        calorieCurves: {
          _day: {
            'minutes': [
              for (var m = 600; m < 606; m++)
                {'t': _ts(m), 'total': 3.0, 'active': 2.0, 'basal': 1.0},
            ],
          },
        },
      );
      await pumpExplorer(t, repo,
          today: '2026-10-04',
          annotationLoader: (_, _) async =>
              [_item('run', AnnotationKind.workout, 18 * 60, untilMinute: 19 * 60)]);
      await tapKey(t, 'explore-scale:day');
      await tapKey(t, 'explore-day-prev');
      await tapKey(t, 'explore-pick:calories');
      await settle(t);
      expect(find.byKey(ChartAnnotationLane.iconKey('run')), findsOneWidget,
          reason: 'the workout does not wait for a band to exist');
      expect(find.byKey(ChartAnnotationLane.shadeKey('run')), findsOneWidget);
      expect(find.byKey(ChartAnnotationLane.iconKey(nap)), findsOneWidget,
          reason: 'the nap lives in the timeline, which calories alone never read');
    });

    testWidgets('a timeline that cannot be read does not break a calories chart',
        (t) async {
      final repo = _NoTimelineRepo(calorieCurves: {
        _day: {
          'minutes': [
            for (var m = 600; m < 606; m++)
              {'t': _ts(m), 'total': 3.0, 'active': 2.0, 'basal': 1.0},
          ],
        },
      });
      await pumpExplorer(t, repo, today: '2026-10-04');
      await tapKey(t, 'explore-scale:day');
      await tapKey(t, 'explore-day-prev');
      await tapKey(t, 'explore-pick:calories');
      await settle(t);
      expect(find.byKey(const ValueKey('explore-retry')), findsNothing);
      expect(plotLine(t, 'calories').runs, isNotEmpty);
    });

    testWidgets('an unfinished workout is a point mark with no shade and no '
        'end edge', (t) async {
      await openDay(t, [
        _item('live', AnnotationKind.workout, 18 * 60),
      ]);
      expect(find.byKey(ChartAnnotationLane.iconKey('live')), findsOneWidget,
          reason: 'it used to be dropped on the assumption a band existed');
      expect(find.byKey(ChartAnnotationLane.shadeKey('live')), findsNothing);
      expect(lines(t).map((l) => l.id), ['live']);
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

/// A repository whose day timeline cannot be read; everything else works.
class _NoTimelineRepo extends ExplorerRepo {
  _NoTimelineRepo({super.calorieCurves});
  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async =>
      throw StateError('timeline unreadable');
}
