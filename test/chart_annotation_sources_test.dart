// Where annotations come from, and how they reach a chart.
//
// The layout (chart_annotation_layout_test.dart) is pure arithmetic; this file
// pins the seams in front of it: the algorithm-version marks keep landing where
// the dotted lines used to, the day timeline's moments become typed
// annotations, and an intraday item reaches a daily chart on its LOCAL day.
//
// Fixed dates only; no test reads the clock. The suite runs under TZ=UTC, so
// the day arithmetic below is built from calendar fields (DateTime(y, m, d,
// h, m)) exactly as production does — never from a day start plus 86400.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/data/nutrition_store.dart';
import 'package:openstrap_edge/gestures/symptom_description.dart'
    show StoredSymptom;
import 'package:openstrap_edge/ui2/chart_annotations.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart'
    show heroAlgoAnnotations;

int _sec(int y, int mo, int d, [int h = 0, int mi = 0]) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

final int _day = _sec(2026, 8, 14);
int _at(int h, [int m = 0]) => _day + h * 3600 + m * 60;

ChartAnnotation _timed(String id, int at,
        {int? until, AnnotationKind kind = AnnotationKind.journal}) =>
    ChartAnnotation(
        id: id,
        kind: kind,
        at: at.toDouble(),
        until: until?.toDouble(),
        label: id);

void main() {
  group('algorithm-version marks join the annotation system', () {
    // The formula the dotted marks used (metric_detail.dart `marks`): a break
    // `b` days behind today, in a series of n slots, sat at
    // (n - 1 - b - .5) / (n - 1) of the way across.
    double old(int b, int n) => (n - 1 - b - .5) / (n - 1);

    test('each break lands exactly where its dotted line used to', () {
      const n = 30;
      final a = algoBreakAnnotations(
          breakDaysBehind: const [3, 12, 20], seriesLength: n, label: 'Algo');
      expect(a.length, 3);
      for (var i = 0; i < a.length; i++) {
        final b = const [3, 12, 20][i];
        expect(a[i].at / (n - 1), moreOrLessEquals(old(b, n), epsilon: 1e-12));
        expect(a[i].kind, AnnotationKind.algoVersion);
        expect(a[i].until, isNull, reason: 'a boundary, not a span');
        expect(a[i].label, 'Algo');
      }
    });

    test('a break at slot 0, behind the window or in the future is dropped', () {
      const n = 10;
      final a = algoBreakAnnotations(
          breakDaysBehind: const [9, 10, 400, -1, 0],
          seriesLength: n,
          label: 'Algo');
      // 9 -> slot 0: nothing before it to be incomparable with. 10, 400: older
      // than the window. -1: after today. 0 -> today's slot: kept (half a slot
      // left of it).
      expect(a.length, 1);
      expect(a.single.at, n - 1 - 0 - .5);
    });

    test('a one-slot or empty series has no boundary to mark', () {
      expect(
          algoBreakAnnotations(
              breakDaysBehind: const [0], seriesLength: 1, label: 'x'),
          isEmpty);
      expect(
          algoBreakAnnotations(
              breakDaysBehind: const [0], seriesLength: 0, label: 'x'),
          isEmpty);
    });

    test('no breaks, no marks', () {
      expect(
          algoBreakAnnotations(
              breakDaysBehind: const [], seriesLength: 30, label: 'x'),
          isEmpty);
    });

    test('ids are unique and stable across calls', () {
      List<String> ids() => [
            for (final a in algoBreakAnnotations(
                breakDaysBehind: const [3, 12, 20], seriesLength: 30, label: 'x'))
              a.id
          ];
      expect(ids().toSet().length, 3);
      expect(ids(), ids());
    });

    test('a mark keeps its own icon beside a journal item at the same place',
        () {
      final mark = algoBreakAnnotations(
          breakDaysBehind: const [5], seriesLength: 30, label: 'Algo').single;
      final water = ChartAnnotation(
          id: 'water',
          kind: AnnotationKind.water,
          at: mark.at + .01,
          label: 'Water');
      final l = layoutAnnotations(
        annotations: [water, mark],
        scale: const AnnotationScale(
            domainStart: 0, domainEnd: 29, width: 290),
      );
      // Provenance is not an event: it never folds into a journal cluster.
      expect(l.items.length, 2);
      expect([for (final i in l.items) i.more], [0, 0]);
      expect({for (final i in l.items) i.id}, {mark.id, 'water'});
      // ...but it still avoids the other icon: nudged, not overlapped.
      final a = l.items[0], b = l.items[1];
      expect(a.footprintRight, lessThanOrEqualTo(b.iconLeft + 1e-9));
      expect(l.items.firstWhere((i) => i.id == mark.id).x,
          moreOrLessEquals(mark.at * 10, epsilon: 1e-9),
          reason: 'the line stays on the boundary');
    });

    test('two marks close together are two icons, never a +n', () {
      final marks = algoBreakAnnotations(
          breakDaysBehind: const [5, 6], seriesLength: 30, label: 'Algo');
      final l = layoutAnnotations(
        annotations: marks,
        scale: const AnnotationScale(
            domainStart: 0, domainEnd: 29, width: 290),
      );
      expect(l.items.length, 2);
      expect([for (final i in l.items) i.more], [0, 0]);
    });
  });

  group('the metric-detail hero reads its marks from stored stamps', () {
    test('a stamp becomes days behind today, then a slot; no clock is read',
        () {
      // Fake "days behind": stamp 1000 -> 3 days ago, 2000 -> 12, 3000 -> today.
      int? behind(int t) => const {1000: 3, 2000: 12, 3000: 0}[t];
      final a = heroAlgoAnnotations(
        algoBreaks: const [1000, 2000, 3000, 9999],
        seriesLength: 30,
        daysBehind: behind,
        label: 'Algorithm version',
      );
      // 9999 has no day behind (unknown stamp): never invented.
      expect([for (final x in a) x.at], [29 - 3 - .5, 29 - 12 - .5, 29 - 0 - .5]);
      expect(a.every((x) => x.kind == AnnotationKind.algoVersion), isTrue);
    });

    test('a stamp older than the window or at its first slot is dropped', () {
      int? behind(int t) => t == 1 ? 6 : 40;
      final a = heroAlgoAnnotations(
        algoBreaks: const [1, 2],
        seriesLength: 7,
        daysBehind: behind,
        label: 'x',
      );
      expect(a, isEmpty, reason: '6 days behind in 7 slots is slot 0');
    });
  });

  group('the day timeline tags what can be annotated', () {
    Map<String, dynamic> timeline() => {
          'day_start': _day,
          'sleep': [
            {'onset_ts': _day - 3600, 'wake_ts': _at(6, 30)}
          ],
          'naps': [
            {'start': _at(14), 'end': _at(14, 40), 'duration_min': 40}
          ],
          'sessions': [
            {'start_ts': _at(18), 'end_ts': _at(19), 'type': 'football'}
          ],
          'highs': {
            'peak_hr': {'t': _at(18, 30), 'v': 181}
          },
          'events': [
            {'event_id': 7, 'ts': _at(20)}
          ],
        };

    Map<AnnotationKind?, int> kinds(List<Moment> m) {
      final out = <AnnotationKind?, int>{};
      for (final x in m) {
        out[x.annotationKind] = (out[x.annotationKind] ?? 0) + 1;
      }
      return out;
    }

    test('naps and workouts are typed; sleep, extremes and band events are not',
        () {
      final m = dayMoments(timeline: timeline());
      final byTitle = {for (final x in m) x.title: x.annotationKind};
      expect(m.where((x) => x.annotationKind == AnnotationKind.nap).length, 1);
      expect(
          m.where((x) => x.annotationKind == AnnotationKind.workout).length, 1);
      // Facts about the band or arithmetic, not things the wearer logged.
      expect(byTitle['Asleep'], isNull);
      expect(byTitle['Highest heart rate'], isNull);
      expect(byTitle['On the charger'], isNull);
      expect(kinds(m)[null], 3);
    });

    test('a marked moment, a symptom and a water tap each get their own kind',
        () {
      final m = dayMoments(
        timeline: {'day_start': _day},
        momentLabels: [
          MomentLabel(
              date: '2026-08-14', hhmm: '09:15', label: 'other', answeredAtMs: 1),
          MomentLabel(
              date: '2026-08-14', hhmm: '10:30', label: 'symptom', answeredAtMs: 1),
          MomentLabel(
              date: '2026-08-14', hhmm: '11:05', label: 'water', answeredAtMs: 1),
        ],
      );
      expect([for (final x in m) x.annotationKind], [
        AnnotationKind.moment,
        AnnotationKind.symptom,
        AnnotationKind.water,
      ]);
    });

    test('a timed water field is water; any other timed field is journal', () {
      final m = dayMoments(
        timeline: {'day_start': _day},
        journal: const {
          'water_ml': JournalMetricValue(500, atMinuteOfDay: 8 * 60),
          'caffeine': JournalMetricValue(1, atMinuteOfDay: 9 * 60),
        },
        fields: kJournalFields,
      );
      expect({for (final x in m) x.at: x.annotationKind}, {
        _at(8): AnnotationKind.water,
        _at(9): AnnotationKind.journal,
      });
    });

    test('assumed water is its own kind, and a removed glass is not shown', () {
      final m = dayMoments(
        timeline: {'day_start': _day},
        assumedWater: const [
          AssumedGlass(date: '2026-08-14', atMin: 10 * 60, ml: 250),
          AssumedGlass(
              date: '2026-08-14',
              atMin: 12 * 60,
              ml: 250,
              state: AssumedState.kept),
          AssumedGlass(
              date: '2026-08-14',
              atMin: 15 * 60,
              ml: 250,
              state: AssumedState.removed),
        ],
      );
      expect(m.length, 2, reason: 'a tombstone is not something that happened');
      expect({for (final x in m) x.at: x.annotationKind}, {
        _at(10): AnnotationKind.assumedWater,
        _at(12): AnnotationKind.assumedWater,
      });
    });

    test('a timed meal is a journal item; an untimed one is not placed', () {
      final m = dayMoments(timeline: {
        'day_start': _day
      }, meals: [
        FoodEntry(
            id: 'a',
            date: '2026-08-14',
            meal: 'Lunch',
            label: 'Soup',
            atTs: _at(13)),
        const FoodEntry(
            id: 'b', date: '2026-08-14', meal: 'Dinner', label: 'Stew'),
      ]);
      expect(m.length, 1);
      expect(m.single.annotationKind, AnnotationKind.journal);
    });

    test('a symptom keeps its kind when it has a description', () {
      final m = dayMoments(
        timeline: {'day_start': _day},
        momentLabels: [
          MomentLabel(
              date: '2026-08-14', hhmm: '10:30', label: 'symptom', answeredAtMs: 1),
        ],
        symptoms: const <StoredSymptom>[],
      );
      expect(m.single.annotationKind, AnnotationKind.symptom);
    });
  });

  group('dayAnnotations: moments to annotations', () {
    Moment m(String title, int at,
            {int? until, AnnotationKind? kind}) =>
        Moment(
            at: at,
            until: until,
            title: title,
            icon: Icons.circle,
            annotationKind: kind);

    test('a moment with no kind is not an annotation', () {
      expect(dayAnnotations([m('On the charger', _at(20))]), isEmpty);
    });

    test('an end after the start is a range, otherwise a point', () {
      final a = dayAnnotations([
        m('Run', _at(18), until: _at(19), kind: AnnotationKind.workout),
        m('Zero', _at(10), until: _at(10), kind: AnnotationKind.nap),
        m('Backwards', _at(11), until: _at(10), kind: AnnotationKind.nap),
        m('Open', _at(12), kind: AnnotationKind.moment),
      ]);
      final by = {for (final x in a) x.label: x};
      expect(by['Run']!.at, _at(18).toDouble());
      expect(by['Run']!.until, _at(19).toDouble());
      expect(by['Zero']!.until, isNull);
      expect(by['Backwards']!.until, isNull);
      expect(by['Backwards']!.at, _at(11).toDouble(),
          reason: 'the start is known, the nonsense end is not used');
      expect(by['Open']!.until, isNull);
    });

    test('two equal-looking moments get two different ids', () {
      final a = dayAnnotations([
        m('Water', _at(9), kind: AnnotationKind.water),
        m('Water', _at(9), kind: AnnotationKind.water),
      ]);
      expect(a.length, 2);
      expect({for (final x in a) x.id}.length, 2);
    });

    test('ids do not change between calls', () {
      List<String> ids() => [
            for (final x in dayAnnotations([
              m('Water', _at(9), kind: AnnotationKind.water),
              m('Run', _at(18), until: _at(19), kind: AnnotationKind.workout),
            ]))
              x.id
          ];
      expect(ids(), ids());
    });
  });

  group('dailyAnnotations: an intraday item on a daily chart', () {
    const days = [
      '2026-08-10',
      '2026-08-11',
      '2026-08-12',
      '2026-08-13',
      '2026-08-14',
      '2026-08-15',
      '2026-08-16',
    ];

    test('a point is on its local day\'s slot, however late in the day', () {
      final a = dailyAnnotations([
        _timed('early', _sec(2026, 8, 12, 0, 5)),
        _timed('late', _sec(2026, 8, 12, 23, 55)),
        _timed('next', _sec(2026, 8, 13, 0, 5)),
      ], days);
      expect({for (final x in a) x.id: x.at}, {
        'early': 2.0,
        'late': 2.0,
        'next': 3.0,
      });
      expect(a.every((x) => x.until == null), isTrue);
    });

    test('a range inside one day is that day\'s point', () {
      final a = dailyAnnotations([
        _timed('run', _sec(2026, 8, 14, 18),
            until: _sec(2026, 8, 14, 19), kind: AnnotationKind.workout),
      ], days);
      expect(a.single.at, 4.0);
      expect(a.single.until, isNull);
      expect(a.single.kind, AnnotationKind.workout);
    });

    test('a range across days spans its first slot to its last', () {
      final a = dailyAnnotations([
        _timed('trip', _sec(2026, 8, 11, 22),
            until: _sec(2026, 8, 13, 7), kind: AnnotationKind.review),
      ], days);
      expect(a.single.at, 1.0);
      expect(a.single.until, 3.0);
    });

    test('a range that runs past the window keeps its visible part honest', () {
      final a = dailyAnnotations([
        _timed('long', _sec(2026, 8, 15, 20),
            until: _sec(2026, 8, 18, 6), kind: AnnotationKind.review),
      ], days);
      // Starts on slot 5; its end is off the chart, so it runs to the last
      // slot rather than being cut to a point.
      expect(a.single.at, 5.0);
      expect(a.single.until, 6.0);
    });

    test('items outside the window are dropped, not clamped onto an edge', () {
      final a = dailyAnnotations([
        _timed('old', _sec(2026, 8, 9, 12)),
        _timed('future', _sec(2026, 8, 17, 12)),
      ], days);
      expect(a, isEmpty);
    });

    test('nothing in, nothing out; no labels, nothing', () {
      expect(dailyAnnotations(const [], days), isEmpty);
      expect(dailyAnnotations([_timed('x', _day)], const []), isEmpty);
    });

    test('several items on one day share its slot and keep their identity', () {
      final a = dailyAnnotations([
        _timed('a', _sec(2026, 8, 14, 8), kind: AnnotationKind.water),
        _timed('b', _sec(2026, 8, 14, 9), kind: AnnotationKind.water),
        _timed('c', _sec(2026, 8, 14, 21), kind: AnnotationKind.symptom),
      ], days);
      expect([for (final x in a) x.id], ['a', 'b', 'c']);
      expect({for (final x in a) x.at}, {4.0});
      expect([for (final x in a) x.kind],
          [AnnotationKind.water, AnnotationKind.water, AnnotationKind.symptom]);
    });

    test('a day with no data of its own is still a day with an item', () {
      // The labels say nothing about whether the metric derived that day; the
      // journal entry is real either way. No item is invented for the others.
      final a = dailyAnnotations([_timed('a', _sec(2026, 8, 13, 12))], days);
      expect(a.length, 1);
      expect(a.single.at, 3.0);
    });
  });
}
