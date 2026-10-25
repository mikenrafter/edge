import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';

import 'support/apk2_keys.dart';
import 'support/apk2_review_harness.dart';
import 'support/as_of_recalc_fakes.dart' show settle;
import 'support/flutter_errors.dart';
import 'support/pin_tz.dart';

Finder _listScroll() => find.descendant(of: apk2Key(apk2List),
    matching: find.byType(Scrollable));

void _rowStartsInside(WidgetTester t, Finder item, Finder viewport) {
  expect(item, findsOneWidget);
  expect(viewport, findsOneWidget);
  final a = t.getRect(item);
  final b = t.getRect(viewport);
  expect(a.left, greaterThanOrEqualTo(b.left - 1));
  expect(a.right, lessThanOrEqualTo(b.right + 1));
  expect(a.top, greaterThanOrEqualTo(b.top - 1));
  // At 3.1x a row's note and controls may exceed the viewport's height. Its
  // beginning must be visible below the chart; fitting the entire row would
  // make this a test of a particular row layout instead of scroll-to-item.
  expect(a.top, lessThan(b.bottom - 1));
}

void main() {
  pinProcessTimeZone('America/Denver');

  for (final scale in [1.0, 3.1]) {
    testWidgets('at 360 pt and ${scale}x, scrolling the list moves its rows '
        'while the pinned chart keeps the same viewport rectangle', (t) async {
      final errors = captureFlutterErrors();
      final r = await Apk2Rig.create(t);
      await r.mount(t, scale: scale);
      expect(apk2Key(apk2Chart), findsOneWidget);
      expect(apk2Key(apk2List), findsOneWidget);
      expect(_listScroll(), findsOneWidget);
      final chart = t.getRect(apk2Key(apk2Chart));
      final list = t.getRect(apk2Key(apk2List));
      expect(chart.top, greaterThanOrEqualTo(0));
      expect(chart.bottom, lessThanOrEqualTo(list.top + 1));
      final scroll = t.state<ScrollableState>(_listScroll());
      final initialOffset = scroll.position.pixels;
      await t.drag(apk2Key(apk2List), const Offset(0, -700));
      await t.pumpAndSettle();
      expect(scroll.position.pixels, greaterThan(initialOffset + 150),
          reason: 'a frozen list cannot make this pinned-header test pass');
      expect(t.getRect(apk2Key(apk2Chart)), chart);
      await t.scrollUntilVisible(apk2Row(apk2Answered), 150,
          scrollable: _listScroll());
      await t.ensureVisible(apk2Row(apk2Answered));
      await t.pumpAndSettle();
      _rowStartsInside(t, apk2Row(apk2Answered), apk2Key(apk2List));
      expect(t.getRect(apk2Key(apk2Chart)), chart);
      expect(errors, isEmpty, reason: 'includes RenderFlex overflow exceptions');
      expect(t.takeException(), isNull);
    });

    testWidgets('at 360 pt and ${scale}x, tapping a chart marker reveals '
        'its offscreen row and briefly highlights only that row', (t) async {
      final errors = captureFlutterErrors();
      final r = await Apk2Rig.create(t);
      await r.mount(t, scale: scale);
      expect(apk2Key(apk2List), findsOneWidget);
      final target = apk2Row(apk2Answered);
      final viewport = t.getRect(apk2Key(apk2List));
      final initiallyVisible = target.evaluate().isNotEmpty &&
          t.getRect(target).overlaps(viewport);
      expect(initiallyVisible, isFalse,
          reason: 'the marker must scroll to a row outside the viewport');
      final marker = apk2Key('$apk2MarkerPrefix$apk2Answered');
      expect(marker, findsOneWidget);
      expect(marker.hitTestable(), findsOneWidget);
      expect(apk2Key('$apk2HighlightPrefix$apk2Answered'), findsNothing);
      await t.tap(marker);
      await t.pump();
      expect(apk2Key('$apk2HighlightPrefix$apk2Answered'), findsOneWidget,
          reason: 'highlight starts immediately, before waiting out its timer');
      expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith(apk2HighlightPrefix)),
          findsOneWidget, reason: 'other items must not be highlighted');
      await t.pump(const Duration(milliseconds: 400));
      _rowStartsInside(t, target, apk2Key(apk2List));
      await t.pump(const Duration(seconds: 5));
      expect(apk2Key('$apk2HighlightPrefix$apk2Answered'), findsNothing,
          reason: 'the highlight must clear without another tap');
      expect(errors, isEmpty);
      expect(t.takeException(), isNull);
    });

    testWidgets('at 360 pt and ${scale}x, tray paging, staged controls and '
        'the leave confirmation fit without overflow', (t) async {
      final semantics = t.ensureSemantics();
      final errors = captureFlutterErrors();
      final r = await Apk2Rig.create(t);
      await r.mount(t, scale: scale);
      expect(apk2Key(apk2Tray), findsOneWidget);
      final tray = t.getRect(apk2Key(apk2Tray));
      expect(tray.left, greaterThanOrEqualTo(0));
      expect(tray.right, lessThanOrEqualTo(360));
      expect(tray.bottom, closeTo(900, 1), reason: 'the tray belongs at the bottom');
      await apk2Show(t, apk2NapA);
      await apk2Tap(t, apk2Keep(apk2NapA));
      expect(apk2Selected(t, apk2Keep(apk2NapA)), isTrue);
      await apk2Show(t, apk2WorkoutA);
      await apk2Tap(t, apk2Discard(apk2WorkoutA));
      expect(apk2Enabled(t, apk2Key(apk2Save)), isTrue);
      await t.binding.handlePopRoute();
      await settle(t, n: 8);
      expect(apk2Key(apk2LeaveDialog), findsOneWidget);
      await apk2Tap(t, apk2Key(apk2Stay));
      expect(apk2Enabled(t, apk2Key(apk2Save)), isTrue);
      expect(errors, isEmpty);
      expect(t.takeException(), isNull);
      // Disposed in the body: the binding checks handles before teardowns run.
      semantics.dispose();
    });

    testWidgets('at 360 pt and ${scale}x, normal entry reserves an empty tray '
        'through loading and speaks the empty status once', (t) async {
      final semantics = t.ensureSemantics();
      final errors = captureFlutterErrors();
      final r = await Apk2Rig.create(t, pending: false);
      final gate = Completer<List<ActivitySuggestion>>();
      r.repo.queueGate = gate;
      await r.mount(t, scale: scale);
      expect(apk2Key(apk2Tray), findsOneWidget);
      expect(apk2Key(apk2List), findsOneWidget);
      expect(apk2Key(apk2Chart), findsOneWidget);
      expect(apk2Key(apk2Empty), findsNothing,
          reason: 'waiting for a read must not announce an empty queue');
      final beforeTray = t.getRect(apk2Key(apk2Tray));
      final beforeList = t.getRect(apk2Key(apk2List));
      final beforeChart = t.getRect(apk2Key(apk2Chart));
      gate.complete([]);
      await settle(t);
      expect(apk2Key(apk2Empty), findsOneWidget);
      expect(find.descendant(of: apk2Key(apk2Empty),
          matchRoot: true, matching: find.text('Nothing to review')), findsOneWidget);
      expect(apk2SpokenCount(t, 'Nothing to review'), 1);
      expect(apk2Enabled(t, apk2Key(apk2Save)), isFalse);
      expect(apk2PageIds(), isEmpty);
      expect(t.getRect(apk2Key(apk2Tray)), beforeTray);
      expect(t.getRect(apk2Key(apk2List)), beforeList);
      expect(t.getRect(apk2Key(apk2Chart)), beforeChart);
      expect(errors, isEmpty);
      expect(t.takeException(), isNull);
      // Disposed in the body: the binding checks handles before teardowns run.
      semantics.dispose();
    });
  }
}
