// The Day timeline's heart-rate card carries the day's labelled things.
//
// "The HR graph that shows sleeping doesn't include the labels from the day. It
// should." The list under the graph is built from `List<Moment>`, and
// `dayAnnotations` already turns the logged ones into `ChartAnnotation`s in the
// epoch-seconds domain; the card has to draw the SAME things through the shared
// annotation lane. Nothing is invented: no annotations, or a day whose start is
// unknown, draws no lane at all.
//
// Fixed local timestamps only (never DateTime.now()). The suite runs with
// TZ=UTC, so a 25 h fall-back day is built directly as a 1500-slot graph: the
// domain is `dayStart + slots * 60`, never 86400.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _date = '2026-09-30';
final int _start = DateTime(2026, 9, 30).millisecondsSinceEpoch ~/ 1000;
int _ts(int h, [int m = 0]) =>
    DateTime(2026, 9, 30, h, m).millisecondsSinceEpoch ~/ 1000;

/// A heart-rate curve over [slots] minutes, so the card exists.
List<double?> _curve(int slots) =>
    [for (var i = 0; i < slots; i++) 60.0 + (i % 40)];

DayGraph _graph({int slots = 1440, int? dayStart}) =>
    DayGraph(hr: _curve(slots), dayStart: dayStart);

ChartAnnotation _mark(String id, AnnotationKind k, int at,
        {int? until, String? label}) =>
    ChartAnnotation(
        id: id,
        kind: k,
        at: at.toDouble(),
        until: until?.toDouble(),
        label: label ?? id);

/// One of each logged kind, an arm's length apart (4 h is ~50 px on a phone, so
/// no two icons cluster).
Map<String, dynamic> get _timeline => {
      'date': _date,
      'day_start': _start,
      'hr': [
        for (var m = 0; m < 1440; m += 5) {'t': _start + m * 60, 'v': 60 + m % 40},
      ],
      'naps': [
        {'start': _ts(14), 'end': _ts(14, 40), 'duration_min': 40},
      ],
      'sessions': [
        {'start_ts': _ts(18), 'end_ts': _ts(19), 'type': 'running'},
      ],
      // The night is the MAIN-SLEEP annotation (a range, moon icon); there is
      // no Asleep band any more. It is not a logged thing, but it is marked.
      'sleep': [
        {'onset_ts': _start - 3600, 'wake_ts': _ts(6, 30)},
      ],
    };

List<Moment> get _moments => dayMoments(
      timeline: _timeline,
      momentLabels: [
        MomentLabel(date: _date, hhmm: '02:00', label: 'water', answeredAtMs: 1),
        MomentLabel(date: _date, hhmm: '06:00', label: 'other', answeredAtMs: 1),
        MomentLabel(
            date: _date, hhmm: '10:00', label: 'symptom', answeredAtMs: 1),
      ],
      journal: const {
        'caffeine_mg': JournalMetricValue(80, atMinuteOfDay: 22 * 60),
      },
    );

Future<void> _view(WidgetTester t) async {
  t.view.physicalSize = const Size(1170, 6000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Future<void> _pumpBody(WidgetTester t, TimelineData d) async {
  await _view(t);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: Builder(
        builder: (c) => ListView(children: timelineBody(c, d)),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

Future<void> _pumpCard(WidgetTester t, DayGraph g,
    {List<ChartAnnotation>? annotations}) async {
  await _view(t);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: Builder(
        builder: (c) => SingleChildScrollView(
          child: dayGraphCard(
                c,
                g,
                annotations: annotations ?? const [],
              ) ??
              const SizedBox(key: ValueKey('no-card')),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

Finder _icon(String id) => find.byKey(ChartAnnotationLane.iconKey(id));
Finder _shade(String id) => find.byKey(ChartAnnotationLane.shadeKey(id));
final _lane = find.byKey(ChartAnnotationLane.laneKey);

String? _label(WidgetTester t) {
  final f = find.byKey(ChartAnnotationLane.labelKey);
  return f.evaluate().isEmpty ? null : t.widget<Text>(f).data;
}

/// The dashed lines the lane will draw, by annotation id.
Map<String, double> _lineX(WidgetTester t) {
  expect(_lane, findsOneWidget, reason: 'the card draws an annotation lane');
  return {
      for (final l in (t
              .widget<CustomPaint>(find.byKey(ChartAnnotationLane.linesKey))
              .painter as AnnotationLinesPainter)
          .lines)
        l.id: l.x,
  };
}

/// Tap the plot [dx] px right of the lane's pixel [x].
Future<void> _scrubAt(WidgetTester t, double x, {double dx = 0}) async {
  expect(_lane, findsOneWidget, reason: 'the card draws an annotation lane');
  final lane = t.getRect(_lane);
  await t.tapAt(Offset(
      lane.left + x + dx, lane.top + ChartAnnotationLane.header + 100));
  await t.pump();
}

void main() {
  group('dayGraph carries the day start the card is annotated over', () {
    test('dayStart is the timeline\'s day_start', () {
      final g = dayGraph({
        'day_start': _start,
        'date': _date,
        'hr': [
          {'t': _start + 3600, 'v': 62},
        ],
      });
      expect(g.dayStart, _start);
      expect(g.hasCurve, isTrue);
    });

    test('an hr override does not change the day start', () {
      final g = dayGraph({
        'day_start': _start,
        'date': _date,
        'hr': const [],
      }, hrOverride: [
        {'t': _start + 3600, 'v': 62},
      ]);
      expect(g.dayStart, _start);
    });

    test('no day_start: unknown, never guessed', () {
      expect(dayGraph({'date': _date}).dayStart, isNull);
      expect(const DayGraph().dayStart, isNull);
    });
  });

  group('dayGraphCard draws the lane only when it has something true to say',
      () {
    testWidgets('annotations + dayStart: an icon per item, at its true x',
        (t) async {
      await _pumpCard(
        t,
        _graph(dayStart: _start),
        annotations: [
          _mark('w', AnnotationKind.water, _ts(12), label: 'Water'),
        ],
      );
      expect(_lane, findsOneWidget);
      expect(_icon('w'), findsOneWidget);
      expect(t.widget<AnnotationIcon>(_icon('w')).kind, AnnotationKind.water);
      final lane = t.getRect(_lane);
      // Noon of a 1440-slot day is the middle of the plot.
      expect(_lineX(t)['w'], moreOrLessEquals(lane.width / 2, epsilon: .5));
    });

    testWidgets('an empty list draws no lane', (t) async {
      await _pumpCard(t, _graph(dayStart: _start));
      expect(find.byKey(const ValueKey('no-card')), findsNothing,
          reason: 'the curve still gets its card');
      expect(_lane, findsNothing);
    });

    testWidgets('an unknown day start draws no lane, however many items',
        (t) async {
      await _pumpCard(
        t,
        _graph(),
        annotations: [_mark('w', AnnotationKind.water, _ts(12))],
      );
      expect(find.byKey(const ValueKey('no-card')), findsNothing);
      expect(_lane, findsNothing);
      expect(_icon('w'), findsNothing);
    });

    testWidgets('no heart-rate curve: still no card at all', (t) async {
      await _pumpCard(
        t,
        const DayGraph(rest: [(0, 60, Colors.blue)], dayStart: 1),
        annotations: [_mark('w', AnnotationKind.water, _ts(12))],
      );
      expect(find.byKey(const ValueKey('no-card')), findsOneWidget);
      expect(_lane, findsNothing);
    });

    testWidgets('items outside the day are not drawn; the one inside is',
        (t) async {
      await _pumpCard(
        t,
        _graph(dayStart: _start),
        annotations: [
          _mark('before', AnnotationKind.water, _start - 3600),
          _mark('inside', AnnotationKind.moment, _ts(9)),
          _mark('after', AnnotationKind.water, _start + 1440 * 60 + 3600),
        ],
      );
      expect(_icon('inside'), findsOneWidget);
      expect(_icon('before'), findsNothing);
      expect(_icon('after'), findsNothing);
    });

    testWidgets('a range is shaded; a point is not', (t) async {
      await _pumpCard(
        t,
        _graph(dayStart: _start),
        annotations: [
          _mark('run', AnnotationKind.workout, _ts(18), until: _ts(19)),
          _mark('w', AnnotationKind.water, _ts(9)),
        ],
      );
      expect(_shade('run'), findsOneWidget);
      expect(_shade('w'), findsNothing);
      expect(_icon('run'), findsOneWidget);
    });
  });

  group('a 25-hour fall-back day', () {
    // The domain is dayStart + slots * 60. A flat 86400 would drop the 25th
    // hour, and lay everything else out on the wrong scale.
    testWidgets('an item in the 25th hour is drawn, on the 1500-slot scale',
        (t) async {
      const hour25 = 24 * 3600 + 30 * 60; // 24:30 into the day
      await _pumpCard(
        t,
        _graph(slots: 1500, dayStart: _start),
        annotations: [
          _mark('late', AnnotationKind.water, _start + hour25, label: 'Late'),
          _mark('past', AnnotationKind.water, _start + 1500 * 60 + 600),
        ],
      );
      expect(_icon('late'), findsOneWidget,
          reason: 'inside the 25 h day, outside a 24 h one');
      expect(_icon('past'), findsNothing);
      final lane = t.getRect(_lane);
      expect(_lineX(t)['late']!,
          moreOrLessEquals(lane.width * hour25 / (1500 * 60), epsilon: .5));
    });

    testWidgets('a 23-hour day ends at 23 h, not 24', (t) async {
      await _pumpCard(
        t,
        _graph(slots: 1380, dayStart: _start),
        annotations: [
          _mark('late', AnnotationKind.water, _start + 22 * 3600 + 1800),
          _mark('past', AnnotationKind.water, _start + 23 * 3600 + 1800),
        ],
      );
      expect(_icon('late'), findsOneWidget);
      expect(_icon('past'), findsNothing,
          reason: 'past the 23 h day, though inside 24 h');
      final lane = t.getRect(_lane);
      expect(_lineX(t)['late']!,
          moreOrLessEquals(lane.width * (22.5 * 3600) / (1380 * 60),
              epsilon: .5));
    });
  });

  group('focus shows the label', () {
    testWidgets('tapping an icon shows that item\'s label', (t) async {
      await _pumpCard(
        t,
        _graph(dayStart: _start),
        annotations: [
          _mark('a', AnnotationKind.water, _ts(6), label: 'Drank water'),
          _mark('b', AnnotationKind.moment, _ts(18), label: 'Felt dizzy'),
        ],
      );
      expect(_label(t), isNull, reason: 'nothing focused, nothing said');
      expect(_icon('b'), findsOneWidget);
      await t.tap(_icon('b'));
      await t.pump();
      expect(_label(t), 'Felt dizzy');
      expect(t.widget<AnnotationIcon>(_icon('b')).bold, isTrue);
    });

    testWidgets('scrubbing near an item focuses it; far from every item '
        'does not (reach 48 px)', (t) async {
      await _pumpCard(
        t,
        _graph(dayStart: _start),
        annotations: [
          _mark('w', AnnotationKind.water, _ts(9), label: 'Drank water'),
        ],
      );
      final x = _lineX(t)['w']!;
      await _scrubAt(t, x, dx: 20);
      expect(_label(t), 'Drank water');
      await _scrubAt(t, x, dx: 150);
      expect(_label(t), isNull,
          reason: '150 px is out of reach: nearest-however-far is not used');
    });
  });

  group('timelineBody: the card shows the same labelled things as the list',
      () {
    testWidgets('water, moment, symptom, journal, workout and nap each get '
        'their icon, of their own kind', (t) async {
      final moments = _moments;
      final ann = dayAnnotations(moments);
      expect(ann.map((a) => a.kind).toSet(), {
        AnnotationKind.water,
        AnnotationKind.moment,
        AnnotationKind.symptom,
        AnnotationKind.journal,
        AnnotationKind.workout,
        AnnotationKind.nap,
        AnnotationKind.mainSleep,
      });
      await _pumpBody(
          t,
          TimelineData(
              day: _date, graph: _graph(dayStart: _start), moments: moments));
      expect(_lane, findsOneWidget);
      for (final a in ann) {
        expect(_icon(a.id), findsOneWidget, reason: '${a.kind.name} ${a.id}');
        expect(t.widget<AnnotationIcon>(_icon(a.id)).kind, a.kind);
      }
      // Exactly those: the night is one of them (main sleep), not a band.
      expect(find.byType(AnnotationIcon), findsNWidgets(ann.length));
    });

    testWidgets('workouts and naps are shaded ranges; points are not',
        (t) async {
      final moments = _moments;
      await _pumpBody(
          t,
          TimelineData(
              day: _date, graph: _graph(dayStart: _start), moments: moments));
      for (final a in dayAnnotations(moments)) {
        final range = a.kind == AnnotationKind.workout ||
            a.kind == AnnotationKind.nap ||
            a.kind == AnnotationKind.mainSleep;
        expect(_shade(a.id), range ? findsOneWidget : findsNothing,
            reason: a.id);
      }
    });

    testWidgets('focusing an item shows its moment title', (t) async {
      final moments = _moments;
      final by = {for (final a in dayAnnotations(moments)) a.kind: a};
      await _pumpBody(
          t,
          TimelineData(
              day: _date, graph: _graph(dayStart: _start), moments: moments));
      expect(_icon(by[AnnotationKind.symptom]!.id), findsOneWidget);
      await t.tap(_icon(by[AnnotationKind.symptom]!.id));
      await t.pump();
      final title =
          moments.firstWhere((m) => m.annotationKind == AnnotationKind.symptom);
      expect(_label(t), title.title);
      expect(_label(t), isNotEmpty);

      // And by scrubbing onto the nap's start.
      final napX = _lineX(t)[by[AnnotationKind.nap]!.id]!;
      await _scrubAt(t, napX, dx: 5);
      expect(
          _label(t),
          moments
              .firstWhere((m) => m.annotationKind == AnnotationKind.nap)
              .title);
    });

    testWidgets('end to end: dayGraph(timeline) feeds the card its day start',
        (t) async {
      final moments = _moments;
      await _pumpBody(
          t,
          TimelineData(
              day: _date, graph: dayGraph(_timeline), moments: moments));
      for (final a in dayAnnotations(moments)) {
        expect(_icon(a.id), findsOneWidget, reason: a.id);
      }
    });

    testWidgets('a day with nothing logged and no night draws no lane',
        (t) async {
      final moments = dayMoments(timeline: {
        'date': _date,
        'day_start': _start,
      });
      expect(dayAnnotations(moments), isEmpty);
      await _pumpBody(
          t,
          TimelineData(
              day: _date, graph: _graph(dayStart: _start), moments: moments));
      expect(_lane, findsNothing);
    });

    testWidgets('a day with only a night: the list says Asleep, the lane '
        'carries just the main-sleep annotation', (t) async {
      final moments = dayMoments(timeline: {
        'date': _date,
        'day_start': _start,
        'sleep': [
          {'onset_ts': _start - 3600, 'wake_ts': _ts(6, 30)},
        ],
      });
      expect([for (final a in dayAnnotations(moments)) a.kind],
          [AnnotationKind.mainSleep]);
      await _pumpBody(
          t,
          TimelineData(
              day: _date, graph: _graph(dayStart: _start), moments: moments));
      expect(find.text('Asleep'), findsWidgets, reason: 'the list still says it');
      expect(_lane, findsOneWidget);
      expect(find.byType(AnnotationIcon), findsOneWidget);
    });

    testWidgets('an unknown day start still lists everything, marks nothing',
        (t) async {
      final moments = _moments;
      await _pumpBody(
          t, TimelineData(day: _date, graph: _graph(), moments: moments));
      expect(find.text('What happened'), findsOneWidget);
      expect(_lane, findsNothing);
      expect(find.byType(AnnotationIcon), findsNothing);
    });
  });
}
