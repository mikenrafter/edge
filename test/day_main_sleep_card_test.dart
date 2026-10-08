// The Day timeline's heart-rate card: the night is an ANNOTATION, not a band.
//
// Before: the night (and naps) were a blue "Asleep" band behind the curve, with
// an "Asleep" legend entry and an "Asleep" scrub key. Now:
//   * no band, no legend entry, no scrub key -- but a night still counts as
//     MEASURED time (`DayGraph.unmeasured` never shades a gap over it);
//   * the MAIN sleep is a chart annotation of kind `mainSleep` (moon, its own
//     colour), a range from onset to wake, labelled
//     "Main sleep <start> to <end>" in local clock times (the onset is usually
//     the previous evening; only the clock time is shown);
//   * with nothing focused its label is the lane's default label; a focus
//     (tap, scrub) replaces it, and moving away brings it back;
//   * no night => no annotation and no label (never fabricated); a nap keeps
//     only its own nap annotation.
//
// "Main" is the LONGEST valid sleep entry (wake after onset), the earliest onset
// on a tie. `getDayTimeline` only ever sends one entry today; the rule makes a
// future second entry unambiguous. Other entries stay in the written list and
// are not on the chart.
//
// Fixed local timestamps only (never DateTime.now()). The suite runs with
// TZ=UTC, so DST days are built as 1500- / 1380-slot graphs directly.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show clockOfTs;
import 'package:openstrap_edge/ui2/ui2.dart';

const _date = '2026-09-30';
final int _start = DateTime(2026, 9, 30).millisecondsSinceEpoch ~/ 1000;
int _ts(int h, [int m = 0]) =>
    DateTime(2026, 9, 30, h, m).millisecondsSinceEpoch ~/ 1000;

/// The night: 23:10 the evening before, up at 06:40.
final int _onset = DateTime(2026, 9, 29, 23, 10).millisecondsSinceEpoch ~/ 1000;
final int _wake = _ts(6, 40);
const _nightLabel = 'Main sleep 11:10 PM to 6:40 AM';

Map<String, dynamic> _timeline({
  List<Map<String, dynamic>>? sleep,
  List<Map<String, dynamic>> naps = const [],
  List<Map<String, dynamic>> sessions = const [],
  List<Map<String, dynamic>>? hr,
}) =>
    {
      'date': _date,
      'day_start': _start,
      'hr': hr ??
          [
            for (var m = 0; m < 1440; m += 5)
              {'t': _start + m * 60, 'v': 60 + m % 40},
          ],
      'sleep': sleep ??
          [
            {'onset_ts': _onset, 'wake_ts': _wake},
          ],
      'naps': naps,
      'sessions': sessions,
    };

List<Map<String, dynamic>> get _nap => [
      {'start': _ts(14), 'end': _ts(14, 40), 'duration_min': 40},
    ];

ChartAnnotation? _main(List<ChartAnnotation> a) {
  final m = a.where((x) => x.kind == AnnotationKind.mainSleep).toList();
  expect(m.length, lessThanOrEqualTo(1), reason: 'at most one main sleep');
  return m.isEmpty ? null : m.single;
}

/// The main-sleep annotation, or a readable failure when none was produced.
ChartAnnotation _mainSleep(List<ChartAnnotation> a) =>
    _main(a) ??
    (throw TestFailure('no mainSleep annotation among '
        '${[for (final x in a) '${x.kind.name}:${x.label}']}'));

List<double?> _curve(int slots) =>
    [for (var i = 0; i < slots; i++) 60.0 + (i % 40)];

Future<void> _pumpCard(WidgetTester t, DayGraph g,
    {List<ChartAnnotation> annotations = const []}) async {
  t.view.physicalSize = const Size(1170, 6000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: Builder(
        builder: (c) => SingleChildScrollView(
          child: dayGraphCard(c, g, annotations: annotations) ??
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

Map<String, double> _lineX(WidgetTester t) => {
      for (final l in (t
              .widget<CustomPaint>(find.byKey(ChartAnnotationLane.linesKey))
              .painter as AnnotationLinesPainter)
          .lines)
        l.id: l.x,
    };

DayLanes _dayLanes(WidgetTester t) => t
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((c) => c.painter)
    .whereType<DayLanes>()
    .single;

Future<void> _scrubAt(WidgetTester t, double x) async {
  final lane = t.getRect(_lane);
  await t.tapAt(
      Offset(lane.left + x, lane.top + ChartAnnotationLane.header + 100));
  await t.pump();
}

void main() {
  group('the main sleep as an annotation', () {
    test('one mainSleep annotation: onset to wake, with the exact label', () {
      final ann = dayAnnotations(dayMoments(timeline: _timeline()));
      final m = _mainSleep(ann);
      expect(m.kind, AnnotationKind.mainSleep);
      expect(m.at, _onset.toDouble());
      expect(m.until, _wake.toDouble());
      expect(m.label, _nightLabel);
      expect(m.label, 'Main sleep ${clockOfTs(_onset)} to ${clockOfTs(_wake)}');
      expect(ann.map((a) => a.id).toSet().length, ann.length,
          reason: 'ids stay unique');
    });

    test('only clock times, whatever day the onset was on', () {
      // Onset after midnight, same calendar day as the wake.
      final m = _mainSleep(dayAnnotations(dayMoments(
          timeline: _timeline(sleep: [
        {'onset_ts': _ts(0, 25), 'wake_ts': _ts(7, 5)},
      ]))));
      expect(m.label, 'Main sleep 12:25 AM to 7:05 AM');
      expect(m.label, isNot(contains('29')));
      expect(m.label, isNot(contains('Sep')));
    });

    test('the written list still says "Asleep" with its duration, once',
        () {
      final moments = dayMoments(timeline: _timeline());
      final rows = moments.where((m) => m.title == 'Asleep').toList();
      expect(rows, hasLength(1));
      expect(rows.single.at, _onset);
      expect(rows.single.until, _wake);
      expect(rows.single.annotationKind, AnnotationKind.mainSleep);
    });

    test('the label is localized: every locale words it and keeps both clocks',
        () {
      for (final code in ['en', 'de', 'es', 'fr', 'hi', 'zh']) {
        final l = lookupAppLocalizations(Locale(code));
        final m = _mainSleep(
            dayAnnotations(dayMoments(timeline: _timeline(), l: l))
          );
        expect(m.label,
            l.dayTimelineMainSleep(clockOfTs(_onset), clockOfTs(_wake)),
            reason: code);
        expect(m.label, contains(clockOfTs(_onset)), reason: code);
        expect(m.label, contains(clockOfTs(_wake)), reason: code);
      }
      expect(lookupAppLocalizations(const Locale('en')).dayTimelineMainSleep('A', 'B'),
          'Main sleep A to B');
    });

    group('absent is absent', () {
      for (final (name, sleep) in <(String, Object?)>[
        ('no sleep key at all', null),
        ('an empty list', <Map<String, dynamic>>[]),
        ('no wake', [
          {'onset_ts': _onset}
        ]),
        ('no onset', [
          {'wake_ts': _wake}
        ]),
        ('a null wake', [
          {'onset_ts': _onset, 'wake_ts': null}
        ]),
        ('wake before onset', [
          {'onset_ts': _wake, 'wake_ts': _onset}
        ]),
        ('zero length', [
          {'onset_ts': _onset, 'wake_ts': _onset}
        ]),
        ('not a map', ['night']),
      ]) {
        test(name, () {
          final tl = _timeline();
          if (sleep == null) {
            tl.remove('sleep');
          } else {
            tl['sleep'] = sleep;
          }
          final ann = dayAnnotations(dayMoments(timeline: tl));
          expect(_main(ann), isNull,
              reason: 'no valid night => no main sleep, no invented one');
          expect(ann.where((a) => a.label.startsWith('Main sleep')), isEmpty);
        });
      }
    });

    group('which entry is "main"', () {
      test('the longest valid one; the others are in the list, not on the '
          'chart', () {
        final tl = _timeline(sleep: [
          {'onset_ts': _ts(1), 'wake_ts': _ts(2)},
          {'onset_ts': _onset, 'wake_ts': _wake},
          {'onset_ts': _ts(23, 59), 'wake_ts': _ts(23, 30)}, // backwards
        ]);
        final moments = dayMoments(timeline: tl);
        final ann = dayAnnotations(moments);
        expect(_mainSleep(ann).at, _onset.toDouble());
        expect(_mainSleep(ann).label, _nightLabel);
        expect(ann.where((a) => a.kind == AnnotationKind.mainSleep),
            hasLength(1));
        expect(moments.where((m) => m.title == 'Asleep').length, greaterThan(1),
            reason: 'every entry keeps its row in the written list');
        expect(
            moments
                .where((m) => m.title == 'Asleep' && m.at == _ts(1))
                .single
                .annotationKind,
            isNull,
            reason: 'a shorter entry is not on the chart');
      });

      test('on a tie the earlier onset', () {
        final tl = _timeline(sleep: [
          {'onset_ts': _ts(3), 'wake_ts': _ts(5)},
          {'onset_ts': _ts(1), 'wake_ts': _ts(3)},
        ]);
        expect(_mainSleep(dayAnnotations(dayMoments(timeline: tl))).at,
            _ts(1).toDouble());
      });
    });

    group('a nap is not a night', () {
      test('a nap keeps only its nap annotation (no priority, same label)',
          () {
        final ann = dayAnnotations(dayMoments(
            timeline: _timeline(sleep: const [], naps: _nap)));
        expect([for (final a in ann) a.kind], [AnnotationKind.nap]);
        expect(ann.single.label, 'Nap');
        expect(ann.single.at, _ts(14).toDouble());
        expect(ann.single.until, _ts(14, 40).toDouble());
      });

      test('with a night as well: one of each, the nap unchanged', () {
        final ann = dayAnnotations(dayMoments(timeline: _timeline(naps: _nap)));
        expect(ann.map((a) => a.kind).toList()..sort((a, b) => a.index - b.index),
            [AnnotationKind.nap, AnnotationKind.mainSleep]);
        final nap = ann.singleWhere((a) => a.kind == AnnotationKind.nap);
        expect(nap.label, 'Nap');
        expect(nap.at, _ts(14).toDouble());
      });
    });
  });

  group('no band, but the night is still measured time', () {
    test('DayGraph keeps the span: a night is not an unmeasured gap', () {
      final g = dayGraph(_timeline(hr: [
        {'t': _ts(12), 'v': 70},
      ]));
      expect(g.rest, hasLength(1), reason: 'the span is still known');
      // Midnight to 06:40 is the night; the rest of the day has one reading.
      expect(g.unmeasured, [(400, 720), (721, 1440)]);
      expect(g.unmeasured.first.$1, 400,
          reason: 'the gap starts where the night ends');
    });

    test('a nap is measured time too', () {
      final g = dayGraph(_timeline(sleep: const [], naps: _nap, hr: [
        {'t': _ts(12), 'v': 70},
      ]));
      expect(g.unmeasured, [(0, 720), (721, 840), (880, 1440)]);
    });

    testWidgets('no rest band is painted; the gaps do not cover the night',
        (t) async {
      final tl = _timeline(naps: _nap, hr: [
        {'t': _ts(12), 'v': 70},
        {'t': _ts(12, 1), 'v': 71},
      ]);
      await _pumpCard(t, dayGraph(tl),
          annotations: dayAnnotations(dayMoments(timeline: tl)));
      final lanes = _dayLanes(t);
      expect(lanes.rest, isEmpty,
          reason: 'neither the night nor the nap is a blue band any more');
      expect(lanes.gaps, isNotEmpty);
      for (final (a, b) in lanes.gaps) {
        expect(b <= 400 / 1440 + 1e-9 || a >= 400 / 1440 - 1e-9, isTrue,
            reason: 'no gap shading across the night ($a-$b)');
      }
    });

    testWidgets('no "Asleep" legend entry or scrub key, before or during a '
        'scrub; the other keys are untouched', (t) async {
      final tl = _timeline(sessions: [
        {'start_ts': _ts(18), 'end_ts': _ts(19), 'type': 'running'},
      ]);
      await _pumpCard(t, dayGraph(tl),
          annotations: dayAnnotations(dayMoments(timeline: tl)));
      expect(find.text('Asleep'), findsNothing);
      expect(find.byKey(const ValueKey('chart-key-cell:Asleep')), findsNothing);
      expect(find.text('Workout'), findsOneWidget);
      expect(find.text('Heart rate (bpm)'), findsOneWidget);
      await _scrubAt(t, t.getRect(_lane).width * .2);
      expect(find.text('Asleep'), findsNothing);
      expect(find.byKey(const ValueKey('chart-key-cell:Asleep')), findsNothing);
    });
  });

  group('on the card', () {
    late List<ChartAnnotation> ann;
    late ChartAnnotation? nightOrNull;
    String nightId() => (nightOrNull ?? _mainSleep(ann)).id;
    late DayGraph graph;

    Map<String, dynamic> withWater() => _timeline();

    setUp(() {
      graph = dayGraph(withWater());
      ann = [
        ...dayAnnotations(dayMoments(timeline: withWater())),
        ChartAnnotation(
            id: 'water-noon',
            kind: AnnotationKind.water,
            at: _ts(12).toDouble(),
            label: 'Drank water'),
      ];
      nightOrNull = _main(ann);
    });

    testWidgets('the night is a moon icon and a shaded range, in its own kind',
        (t) async {
      await _pumpCard(t, graph, annotations: ann);
      expect(_icon(nightId()), findsOneWidget);
      expect(t.widget<AnnotationIcon>(_icon(nightId())).kind,
          AnnotationKind.mainSleep);
      expect(find.descendant(
              of: _icon(nightId()),
              matching: find.byIcon(annotationIcon(AnnotationKind.mainSleep))),
          findsOneWidget);
      expect(_shade(nightId()), findsOneWidget);
      final lane = t.getRect(_lane);
      // The onset is before the day: no dashed line there; the wake is on it.
      expect(_lineX(t).containsKey(nightId()), isFalse,
          reason: 'a cut start gets no dashed line');
      expect(_lineX(t)['${nightId()}:end'],
          moreOrLessEquals(lane.width * (400 * 60) / (1440 * 60), epsilon: .5));
    });

    testWidgets('nothing focused: the label slot says "Main sleep ..." and no '
        'icon is bold', (t) async {
      await _pumpCard(t, graph, annotations: ann);
      expect(_label(t), _nightLabel);
      for (final a in ann) {
        expect(t.widget<AnnotationIcon>(_icon(a.id)).bold, isFalse,
            reason: a.id);
      }
    });

    testWidgets('tapping another item replaces it; moving away brings it back',
        (t) async {
      await _pumpCard(t, graph, annotations: ann);
      await t.tap(_icon('water-noon'));
      await t.pump();
      expect(_label(t), 'Drank water');
      expect(t.widget<AnnotationIcon>(_icon('water-noon')).bold, isTrue);
      // A scrub far from every item (21:00; reach is 48 px) un-pins it.
      await _scrubAt(t, t.getRect(_lane).width * 21 / 24);
      expect(_label(t), _nightLabel);
    });

    testWidgets('tapping the night itself focuses it (bold) with the same '
        'label', (t) async {
      await _pumpCard(t, graph, annotations: ann);
      await t.tap(_icon(nightId()));
      await t.pump();
      expect(_label(t), _nightLabel);
      expect(t.widget<AnnotationIcon>(_icon(nightId())).bold, isTrue);
    });

    testWidgets('scrubbing inside the night focuses it', (t) async {
      await _pumpCard(t, graph, annotations: ann);
      await _scrubAt(t, t.getRect(_lane).width * 3 / 24);
      expect(t.widget<AnnotationIcon>(_icon(nightId())).bold, isTrue);
      expect(_label(t), _nightLabel);
    });

    testWidgets('a crowd of moments inside the night is clustered around its '
        'icon, never into it', (t) async {
      final crowd = [
        for (var i = 0; i < 8; i++)
          ChartAnnotation(
              id: 'w$i',
              kind: AnnotationKind.water,
              at: (_ts(0, 5) + i * 300).toDouble(),
              label: 'w$i'),
      ];
      await _pumpCard(t, graph, annotations: [...ann, ...crowd]);
      expect(_icon(nightId()), findsOneWidget);
      expect(find.byKey(ChartAnnotationLane.moreKey(nightId())), findsNothing,
          reason: 'no +n on the main sleep');
      final badges = find.byWidgetPredicate((w) =>
          w.key is ValueKey &&
          '${(w.key as ValueKey).value}'.startsWith('annotation-more:'));
      expect(badges, findsWidgets, reason: 'the crowd did cluster');
      expect(_label(t), _nightLabel);
    });

    testWidgets('no night: no main-sleep icon and no default label',
        (t) async {
      final tl = _timeline(sleep: const []);
      final a = [
        ...dayAnnotations(dayMoments(timeline: tl)),
        ChartAnnotation(
            id: 'water-noon',
            kind: AnnotationKind.water,
            at: _ts(12).toDouble(),
            label: 'Drank water'),
      ];
      await _pumpCard(t, dayGraph(tl), annotations: a);
      expect(_lane, findsOneWidget);
      expect(find.byWidgetPredicate(
              (w) => w is AnnotationIcon && w.kind == AnnotationKind.mainSleep),
          findsNothing);
      expect(_label(t), isNull, reason: 'nothing focused, nothing said');
    });

    testWidgets('a nap alone: only its own icon, and no default label',
        (t) async {
      final tl = _timeline(sleep: const [], naps: _nap);
      final a = dayAnnotations(dayMoments(timeline: tl));
      await _pumpCard(t, dayGraph(tl), annotations: a);
      expect(find.byType(AnnotationIcon), findsOneWidget);
      expect(t.widget<AnnotationIcon>(find.byType(AnnotationIcon)).kind,
          AnnotationKind.nap);
      expect(_label(t), isNull);
    });

    testWidgets('night and nap: two icons, each of its own kind; the label '
        'is the night\'s', (t) async {
      final tl = _timeline(naps: _nap);
      final a = dayAnnotations(dayMoments(timeline: tl));
      await _pumpCard(t, dayGraph(tl), annotations: a);
      expect(
          [
            for (final i in t.widgetList<AnnotationIcon>(
                find.byType(AnnotationIcon)))
              i.kind
          ]..sort((x, y) => x.index - y.index),
          [AnnotationKind.nap, AnnotationKind.mainSleep]);
      expect(_label(t), _nightLabel);
    });
  });

  group('a 25-hour fall-back day', () {
    // The domain is dayStart + slots * 60: 25 h = 1500 slots. A night that ends
    // in the 25th hour keeps its wake line inside the plot; on a 24 h domain it
    // would run off the edge.
    testWidgets('a night ending at 24:30 puts its wake line at 24.5/25 of the '
        'plot, and its label shows', (t) async {
      final onset = _start + 23 * 3600;
      final wake = _start + 24 * 3600 + 30 * 60;
      final a = dayAnnotations(dayMoments(
          timeline: _timeline(sleep: [
        {'onset_ts': onset, 'wake_ts': wake},
      ])));
      final m = _mainSleep(a);
      await _pumpCard(t, DayGraph(hr: _curve(1500), dayStart: _start),
          annotations: a);
      final lane = t.getRect(_lane);
      expect(_lineX(t)['${m.id}:end']!,
          moreOrLessEquals(lane.width * (24.5 * 3600) / (1500 * 60), epsilon: .5));
      expect(_lineX(t)[m.id]!,
          moreOrLessEquals(lane.width * (23 * 3600) / (1500 * 60), epsilon: .5));
      expect(_label(t), 'Main sleep ${clockOfTs(onset)} to ${clockOfTs(wake)}');
      expect(_icon(m.id), findsOneWidget);
    });
  });

  group('a 23-hour spring-forward day', () {
    testWidgets('a night ending at 22:30 ends at 22.5/23 of the plot',
        (t) async {
      final a = dayAnnotations(dayMoments(
          timeline: _timeline(sleep: [
        {'onset_ts': _start - 3600, 'wake_ts': _start + 22 * 3600 + 1800},
      ])));
      final m = _mainSleep(a);
      await _pumpCard(t, DayGraph(hr: _curve(1380), dayStart: _start),
          annotations: a);
      final lane = t.getRect(_lane);
      expect(_lineX(t)['${m.id}:end']!,
          moreOrLessEquals(lane.width * (22.5 * 3600) / (1380 * 60), epsilon: .5));
      expect(_label(t), isNotNull);
    });

    testWidgets('a night running past 23 h is cut at the edge: shaded to it, '
        'no wake line at a wrong place', (t) async {
      final a = dayAnnotations(dayMoments(
          timeline: _timeline(sleep: [
        {'onset_ts': _start + 21 * 3600, 'wake_ts': _start + 23 * 3600 + 1800},
      ])));
      final m = _mainSleep(a);
      await _pumpCard(t, DayGraph(hr: _curve(1380), dayStart: _start),
          annotations: a);
      expect(_shade(m.id), findsOneWidget);
      expect(_lineX(t).containsKey('${m.id}:end'), isFalse,
          reason: 'on a 24 h domain this wake would be inside; here it is not');
      expect(_icon(m.id), findsOneWidget);
    });
  });
}
