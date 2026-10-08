// The metric-detail hero: algorithm-version marks are always on; journal
// annotations (water, moments, symptoms, meals, ...) sit behind a toggle chip
// that is OFF by default and costs nothing (no read) until it is turned on.
//
// Every date is fixed and the clock is a fake one (package:clock) — the screen
// counts its day slots back from "today", and nothing here reads the system
// time. The chip's label is localised in every shipped language.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/explorer_harness.dart' show providers;

/// "Now" for every test: noon on 2026-10-04. A 30-day window is then
/// 2026-09-05 .. 2026-10-04, slot 0 .. 29.
final _now = DateTime(2026, 10, 4, 12);
const _from = '2026-09-05', _to = '2026-10-04';

int _noon(int m, int d) =>
    DateTime(2026, m, d, 12).millisecondsSinceEpoch ~/ 1000;

MetricData _data() => MetricData(
      daysAvailable: 40,
      series: [
        for (var i = 0; i < 30; i++)
          (t: _noon(9, 5 + i), v: 58.0 + (i % 3)),
      ],
      // 2026-09-20 is 14 days behind today: slot 15, mark half a slot left.
      algoBreaks: [_noon(9, 20)],
    );

ChartAnnotation _water() => ChartAnnotation(
      id: 'jw',
      kind: AnnotationKind.water,
      at: DateTime(2026, 10, 1, 9).millisecondsSinceEpoch / 1000,
      label: 'Drank water',
    );

const _algoId = 'algo:14';

void _test(String name, Future<void> Function(WidgetTester t) body) =>
    testWidgets(name, (t) => withClock(Clock.fixed(_now), () => body(t)));

Future<List<(String, String)>> _open(
  WidgetTester t, {
  Future<List<ChartAnnotation>> Function(String, String)? loader,
}) async {
  t.view.physicalSize = const Size(390 * 3, 1400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final calls = <(String, String)>[];
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: MetricDetail(
        'resting_hr',
        data: _data(),
        initialRange: 30,
        annotationLoader: (a, b) {
          calls.add((a, b));
          return (loader ?? (_, _) async => [_water()])(a, b);
        },
      ),
    ),
  ));
  await t.pumpAndSettle();
  return calls;
}

Finder get _chip => find.byKey(MetricDetail.journalToggleKey);
bool _on(WidgetTester t) => t.widget<Semantics>(_chip).properties.selected ?? false;
Finder _icon(String id) => find.byKey(ChartAnnotationLane.iconKey(id));

void main() {
  group('the journal toggle', () {
    _test('is a chip on the hero, off by default, and nothing is read for it',
        (t) async {
      final calls = await _open(t);
      expect(_chip, findsOneWidget);
      expect(_on(t), isFalse);
      expect(calls, isEmpty, reason: 'off means no read at all');
      expect(_icon('jw'), findsNothing);
    });

    _test('the algorithm-version mark is on whether the chip is or not',
        (t) async {
      await _open(t);
      expect(_icon(_algoId), findsOneWidget);
      await t.tap(_chip);
      await t.pumpAndSettle();
      expect(_icon(_algoId), findsOneWidget);
      await t.tap(_chip);
      await t.pumpAndSettle();
      expect(_icon(_algoId), findsOneWidget);
    });

    _test('turning it on reads the window\'s days and draws the marks',
        (t) async {
      final calls = await _open(t);
      await t.tap(_chip);
      await t.pumpAndSettle();
      expect(_on(t), isTrue);
      expect(calls, [(_from, _to)]);
      expect(_icon('jw'), findsOneWidget);
      expect(t.widget<AnnotationIcon>(_icon('jw')).kind, AnnotationKind.water);
    });

    _test('a mark sits on its day\'s slot of the 30-slot hero', (t) async {
      await _open(t);
      await t.tap(_chip);
      await t.pumpAndSettle();
      final lane = t.getRect(find.byKey(ChartAnnotationLane.laneKey));
      final lines = (t
              .widget<CustomPaint>(find.byKey(ChartAnnotationLane.linesKey))
              .painter as AnnotationLinesPainter)
          .lines;
      // 2026-10-01 is slot 26 of 0..29: where the line chart plots that day.
      expect(lines.firstWhere((l) => l.id == 'jw').x,
          moreOrLessEquals(lane.width * 26 / 29, epsilon: .5));
    });

    _test('turning it off removes the marks and keeps the algorithm mark',
        (t) async {
      await _open(t);
      await t.tap(_chip);
      await t.pumpAndSettle();
      await t.tap(_chip);
      await t.pumpAndSettle();
      expect(_on(t), isFalse);
      expect(_icon('jw'), findsNothing);
      expect(_icon(_algoId), findsOneWidget);
    });

    _test('a reader that fails leaves the chart as it was', (t) async {
      await _open(t, loader: (_, _) async => throw StateError('no store'));
      await t.tap(_chip);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(_icon('jw'), findsNothing);
      expect(_icon(_algoId), findsOneWidget);
    });
  });

  group('a read superseded by a revision reload never commits', () {
    // A LIVE screen (no injected data): a derive/import ticks
    // insightsRevision, the screen re-reads, and the journal read that was in
    // flight for the same window must neither suppress the fresh one nor
    // overwrite it when it lands late.
    ChartAnnotation mark(String id, int day) => ChartAnnotation(
        id: id,
        kind: AnnotationKind.water,
        at: DateTime(2026, 10, day, 9).millisecondsSinceEpoch / 1000,
        label: id);

    Future<(AppState, List<Completer<List<ChartAnnotation>>>)> live(
        WidgetTester t) async {
      t.view.physicalSize = const Size(390 * 3, 1400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final app = AppState.forTesting()..repo = _LiveRepo();
      addTearDown(app.dispose);
      final reads = <Completer<List<ChartAnnotation>>>[];
      await t.pumpWidget(providers(
        app,
        MetricDetail('calories', initialRange: 30, annotationLoader: (_, _) {
          final c = Completer<List<ChartAnnotation>>();
          reads.add(c);
          return c.future;
        }),
      ));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      return (app, reads);
    }

    Future<void> bump(WidgetTester t, AppState app) async {
      app.insightsRevision.value++;
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    _test('a reload while a read is in flight starts a fresh read, and the '
        'old one landing first does not win', (t) async {
      final (app, reads) = await live(t);
      await t.tap(_chip);
      await t.pump();
      expect(reads, hasLength(1));
      await bump(t, app);
      expect(reads, hasLength(2),
          reason: 'the in-flight read is superseded, not waited on');
      reads[0].complete([mark('old', 1)]);
      await t.pump();
      reads[1].complete([mark('new', 2)]);
      await t.pump();
      await t.pump();
      expect(_icon('old'), findsNothing);
      expect(_icon('new'), findsOneWidget);
    });

    _test('the old read landing after the new one changes nothing', (t) async {
      final (app, reads) = await live(t);
      await t.tap(_chip);
      await t.pump();
      await bump(t, app);
      expect(reads, hasLength(2));
      reads[1].complete([mark('new', 2)]);
      await t.pump();
      await t.pump();
      reads[0].complete([mark('old', 1)]);
      await t.pump();
      await t.pump();
      expect(_icon('old'), findsNothing);
      expect(_icon('new'), findsOneWidget);
      expect(reads, hasLength(2), reason: 'no third read');
    });
  });

  group('the toggle describes only what the reader loads', () {
    test('no source the loader does not read is claimed', () {
      final m = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
      final d = ((m['@metricDetailJournalMarksToggle']
              as Map<String, dynamic>)['description'] as String)
          .toLowerCase();
      // loadAnnotations reads workouts, marked moments (incl. water taps),
      // symptoms, assumed water and timed journal fields. Not meals or doses.
      expect(d, isNot(contains('meal')));
      expect(d, isNot(contains('dose')));
      expect(d, contains('workout'));
    });
  });

  group('the chip\'s label is localised', () {
    test('every shipped language has it, non-empty', () {
      final arbs = Directory('lib/l10n')
          .listSync()
          .whereType<File>()
          .where((f) => RegExp(r'app_\w+\.arb$').hasMatch(f.path))
          .toList();
      expect(arbs.map((f) => f.uri.pathSegments.last).toSet(),
          containsAll(['app_en.arb', 'app_de.arb', 'app_es.arb', 'app_fr.arb', 'app_hi.arb']));
      for (final f in arbs) {
        final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final v = m['metricDetailJournalMarksToggle'];
        expect(v is String && v.trim().isNotEmpty, isTrue,
            reason: '${f.path} has no metricDetailJournalMarksToggle');
      }
    });
  });
}

/// Just enough repository for a live MetricDetail('calories').
class _LiveRepo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) async =>
      {
        'points': [
          for (var i = 0; i < 30; i++)
            {'t': _noon(9, 5 + i), 'v': 2000.0 + i},
        ],
      };

  @override
  Future<List<String>> availableDays() async =>
      [for (var i = 0; i < 40; i++) 'd$i'];
}
