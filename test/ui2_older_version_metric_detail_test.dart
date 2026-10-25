// RULES B.2 on the metric detail screen (strain, TRIMP, active energy):
// MetricData.load -> pointsOf must keep the flag, and the headline, the
// "latest" line and the selected-day readout (visible and spoken) must show it.
// getChart points carry only the VERSION, so these notes are asserted without
// the reason sentence (see the report: reason on chart points is a data-side
// gap).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/older_version_fixtures.dart';

Future<void> _pump(WidgetTester t, String key, List<Map<String, dynamic>> pts,
    {String? window}) async {
  t.view.physicalSize = const Size(390 * 3, 1800 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final d = await MetricData.load(
      OlderRepo(charts: {specOf(key).chartKey: pts}), key,
      journal: false);
  await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: MetricDetail(key, data: d))));
  await t.pumpAndSettle();
  if (window != null) {
    await t.tap(find.text(window));
    await t.pumpAndSettle();
  }
}

Finder get _slider => find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.slider == true);

Future<void> _scrubCenter(WidgetTester t) async {
  await t.tapAt(t.getCenter(_slider));
  await t.pumpAndSettle();
}

void main() {
  for (final key in const ['strain', 'trimp', 'calories']) {
    group(key, () {
      testWidgets('Today is an older value: headline asterisk and note',
          (t) async {
        final h = t.ensureSemantics();
        await _pump(t, key, series(10, flagged: {0}));
        expect(olderMark('headline'), findsOneWidget);
        expect(find.textContaining(kNoteV104), findsWidgets);
        expect(olderNote('readout'), findsOneWidget);
        expect(find.bySemanticsLabel(kSpoken), findsWidgets);
        h.dispose();
      });

      testWidgets('Today is current: no marker', (t) async {
        await _pump(t, key, series(10, flagged: {4}));
        expect(anyOlderMarker(), findsNothing);
      });
    });
  }

  group('a 7 day window', () {
    testWidgets('an average over a flagged day is flagged, latest is not',
        (t) async {
      // Mixed versions are never averaged silently.
      await _pump(t, 'strain', series(10, flagged: {3}), window: '7 days');
      expect(olderMark('headline'), findsOneWidget);
      expect(olderMark('latest'), findsNothing, reason: 'today is current');
    });

    testWidgets('the latest reading is flagged when it is the older one',
        (t) async {
      await _pump(t, 'strain', series(10, flagged: {0}), window: '7 days');
      expect(olderMark('latest'), findsOneWidget);
      expect(olderMark('headline'), findsOneWidget);
    });

    testWidgets('a trailing gap: "latest" is the last real reading and takes '
        'its flag from THAT day', (t) async {
      // Today has no row; yesterday (older) is the latest reading.
      await _pump(t, 'strain', series(10, flagged: {1}, gaps: {0}),
          window: '7 days');
      expect(olderMark('latest'), findsOneWidget);
      expect(olderNote('latest'), findsNothing, reason: 'one strip, deduped');
      expect(t.widget<Text>(olderNote('readout')).data, contains(kNoteV104));
    });

    testWidgets('a trailing gap with a current latest reading: no flag on it '
        'even when today would be flagged elsewhere', (t) async {
      await _pump(t, 'strain', series(10, flagged: {5}, gaps: {0}),
          window: '7 days');
      expect(olderMark('latest'), findsNothing);
      expect(olderMark('headline'), findsOneWidget, reason: 'the average spans it');
    });

    testWidgets('a window with no flagged day has no marker', (t) async {
      await _pump(t, 'strain', series(10, flagged: {9}), window: '7 days');
      expect(anyOlderMarker(), findsNothing);
    });

    testWidgets('selecting a flagged day: readout asterisk, note, spoken',
        (t) async {
      final h = t.ensureSemantics();
      await _pump(t, 'strain', series(10, flagged: {3}), window: '7 days');
      await _scrubCenter(t);
      expect(olderMark('readout'), findsOneWidget);
      expect(olderNote('selected'), findsNothing,
          reason: 'a scrub never adds a reason row');
      final said = t.getSemantics(_slider).value;
      expect(said, contains('older calculation'));
      h.dispose();
    });

    testWidgets('selecting a current day beside a flagged one: no marker',
        (t) async {
      final h = t.ensureSemantics();
      await _pump(t, 'strain', series(10, flagged: {0, 1}), window: '7 days');
      await _scrubCenter(t);
      expect(olderMark('readout'), findsNothing);
      expect(t.getSemantics(_slider).value, isNot(matches(kSpoken)));
      h.dispose();
    });

    testWidgets('selecting a gap day: no value, no marker', (t) async {
      final h = t.ensureSemantics();
      await _pump(t, 'strain', series(10, flagged: {0}, gaps: {3}),
          window: '7 days');
      await _scrubCenter(t);
      expect(olderMark('readout'), findsNothing);
      expect(t.getSemantics(_slider).value, isNot(matches(kSpoken)));
      h.dispose();
    });
  });
}
