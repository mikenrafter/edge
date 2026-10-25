import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

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

  /// The chart and its range control are inline in the page: scroll them into
  /// view and they can be hit.
  Future<void> chartControlsReachable(WidgetTester t) async {
    for (final f in [find.byType(ChartScrub), find.byType(RangeSlider)]) {
      expect(f, findsOneWidget);
      await t.ensureVisible(f);
      await t.pump();
      expect(f.hitTestable(), findsOneWidget);
      expect(t.getRect(f).height, greaterThan(0));
    }
  }

  for (final size in [const Size(360, 480), const Size(360, 640),
      const Size(640, 360)]) {
    for (final scale in [1.0, 3.1]) {
      testWidgets('short ${size.width}x${size.height} viewport at ${scale}x '
          'keeps the inline chart, the list and the Save bar usable', (t) async {
        final semantics = t.ensureSemantics();
        final errors = captureFlutterErrors();
        final r = await Apk2Rig.create(t);
        await r.mount(t, size: size, scale: scale);
        final list = t.getRect(apk2Key(apk2List));
        expect(list.height, greaterThanOrEqualTo(size.height * .2));
        await chartControlsReachable(t);
        expect(t.getRect(find.byType(ChartScrub)).height, greaterThan(24));
        await apk2Show(t, apk2NapA);
        await apk2Tap(t, apk2Keep(apk2NapA));
        final bar = t.getRect(apk2Key('apk2-review-savebar'));
        expect(bar.bottom, lessThanOrEqualTo(size.height));
        expect(bar.top, greaterThanOrEqualTo(t.getRect(apk2Key(apk2List)).bottom - 1),
            reason: 'the Save bar sits below the list, not over it');
        await apk2Tap(t, apk2Key(apk2Save));
        expect(await r.status(t, apk2NapA), ActivityReviewStatus.confirmed);
        expect(apk2Key(apk2Save), findsNothing);
        final scroll = t.state<ScrollableState>(_listScroll());
        await t.drag(apk2Key(apk2List), const Offset(0, -200));
        await t.pumpAndSettle();
        expect(scroll.position.pixels, greaterThan(0));
        expect(errors, isEmpty);
        expect(t.takeException(), isNull);
        semantics.dispose();
      });
    }
  }

  testWidgets('a zoom window survives rotating into a short viewport with '
      'its range control still reachable to widen it', (t) async {
    final errors = captureFlutterErrors();
    final r = await Apk2Rig.create(t);
    await r.mount(t);
    final slider = find.byType(RangeSlider);
    // How many chart annotations are drawn at all.
    final marks = find.byWidgetPredicate((w) => w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('annotation-icon:'));
    final whole = marks.evaluate().length;
    expect(whole, greaterThan(1));
    t.widget<RangeSlider>(slider).onChanged!(const RangeValues(540, 600));
    await t.pumpAndSettle();
    final zoomed = marks.evaluate().length;
    expect(zoomed, lessThan(whole), reason: '09:00-10:00 hides the other marks');
    t.view.physicalSize = const Size(640, 360) * 3;
    await t.pumpAndSettle();
    await chartControlsReachable(t);
    final values = t.widget<RangeSlider>(slider).values;
    expect((values.start, values.end), (540.0, 600.0));
    expect(marks.evaluate().length, zoomed);
    t.widget<RangeSlider>(slider).onChanged!(const RangeValues(0, 1440));
    await t.pumpAndSettle();
    expect(marks.evaluate().length, greaterThan(zoomed));
    await t.ensureVisible(marks.first);
    await t.pump();
    expect(marks.hitTestable(), findsWidgets);
    expect(errors, isEmpty);
    expect(t.takeException(), isNull);
  });

  testWidgets('iOS edge swipe confirms staged choices and Stay preserves them', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    await r.mount(t, platform: TargetPlatform.iOS);
    await apk2Show(t, apk2NapA);
    await apk2Tap(t, apk2Keep(apk2NapA));
    await t.dragFrom(const Offset(1, 300), const Offset(280, 0));
    await settle(t);
    expect(apk2Key(apk2LeaveDialog), findsOneWidget);
    await apk2Tap(t, apk2Key(apk2Stay));
    expect(apk2Selected(t, apk2Keep(apk2NapA)), isTrue);
    expect(apk2Enabled(t, apk2Key(apk2Save)), isTrue);
    expect(await r.snapshot(t), before);
    await t.dragFrom(const Offset(1, 300), const Offset(280, 0));
    await settle(t);
    expect(apk2Key(apk2LeaveDialog), findsOneWidget);
    await apk2Tap(t, apk2Key(apk2Leave));
    expect(find.text('Outside breakdown'), findsOneWidget);
    expect(apk2Key(apk2Save), findsNothing);
    expect(await r.snapshot(t), before);
    semantics.dispose();
  });

  for (final scale in [1.0, 3.1]) {
    testWidgets('at 360 pt and ${scale}x, the chart is inline: scrolling the '
        'page carries the chart away with the rows', (t) async {
      final errors = captureFlutterErrors();
      final r = await Apk2Rig.create(t);
      await r.mount(t, scale: scale);
      expect(apk2Key(apk2Chart), findsOneWidget);
      expect(apk2Key(apk2List), findsOneWidget);
      expect(_listScroll(), findsOneWidget);
      expect(find.descendant(of: apk2Key(apk2List),
          matching: apk2Key(apk2Chart)), findsOneWidget,
          reason: 'the chart is inside the scrolling list, not pinned above it');
      final chart = t.getRect(apk2Key(apk2Chart));
      final scroll = t.state<ScrollableState>(_listScroll());
      final initialOffset = scroll.position.pixels;
      await t.drag(apk2Key(apk2List), const Offset(0, -300));
      await t.pumpAndSettle();
      final moved = scroll.position.pixels - initialOffset;
      expect(moved, greaterThan(150));
      expect(t.getRect(apk2Key(apk2Chart)).top, closeTo(chart.top - moved, 1),
          reason: 'the chart moves one-to-one with the page');
      await t.scrollUntilVisible(apk2Row(apk2Answered), 150,
          scrollable: _listScroll());
      await t.ensureVisible(apk2Row(apk2Answered));
      await t.pumpAndSettle();
      _rowStartsInside(t, apk2Row(apk2Answered), apk2Key(apk2List));
      expect(errors, isEmpty, reason: 'includes RenderFlex overflow exceptions');
      expect(t.takeException(), isNull);
    });

    testWidgets('at 360 pt and ${scale}x, tapping a chart annotation reveals '
        'its offscreen row and highlights only that row', (t) async {
      final errors = captureFlutterErrors();
      final r = await Apk2Rig.create(t);
      await r.mount(t, scale: scale);
      final target = apk2Row(apk2Answered);
      final viewport = t.getRect(apk2Key(apk2List));
      final initiallyVisible = target.evaluate().isNotEmpty &&
          t.getRect(target).overlaps(viewport);
      expect(initiallyVisible, isFalse,
          reason: 'the tap must scroll to a row outside the viewport');
      Color? tint(String id) => t.widget<Container>(apk2Row(id)).color;
      expect(tint(apk2Answered), isNull);
      await apk2TapAnnotation(t, 'moment:${apk2At(20, 45)}');
      expect(tint(apk2Answered), isNotNull, reason: 'the tapped row is tinted');
      expect(tint(apk2Meal), isNull, reason: 'no other row is');
      _rowStartsInside(t, target, apk2Key(apk2List));
      expect(errors, isEmpty);
      expect(t.takeException(), isNull);
    });

    testWidgets('at 360 pt and ${scale}x, staged controls, the Save bar and '
        'the leave confirmation fit without overflow', (t) async {
      final semantics = t.ensureSemantics();
      final errors = captureFlutterErrors();
      final r = await Apk2Rig.create(t);
      await r.mount(t, scale: scale);
      expect(apk2Key(apk2Save), findsNothing, reason: 'no bar before staging');
      await apk2Show(t, apk2NapA);
      await apk2Tap(t, apk2Keep(apk2NapA));
      expect(apk2Selected(t, apk2Keep(apk2NapA)), isTrue);
      final bar = t.getRect(apk2Key('apk2-review-savebar'));
      expect(bar.left, greaterThanOrEqualTo(0));
      expect(bar.right, lessThanOrEqualTo(360));
      expect(bar.bottom, closeTo(900, 1), reason: 'the bar belongs at the bottom');
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

    testWidgets('at 360 pt and ${scale}x, a day with nothing to review shifts '
        'nothing when its read completes and shows no Save bar', (t) async {
      final semantics = t.ensureSemantics();
      final errors = captureFlutterErrors();
      final r = await Apk2Rig.create(t, pending: false);
      final gate = Completer<List<ActivitySuggestion>>();
      r.repo.queueGate = gate;
      await r.mount(t, scale: scale);
      expect(apk2Key(apk2List), findsOneWidget);
      expect(apk2Key(apk2Chart), findsOneWidget);
      expect(apk2Key(apk2Save), findsNothing);
      final beforeList = t.getRect(apk2Key(apk2List));
      final beforeChart = t.getRect(apk2Key(apk2Chart));
      final beforeRow = t.getRect(apk2Row(apk2Meal));
      gate.complete([]);
      await settle(t);
      expect(find.text('Breakdown of your day'), findsOneWidget);
      expect(apk2Key(apk2Save), findsNothing);
      expect(apk2PageIds(), isEmpty);
      expect(t.getRect(apk2Key(apk2List)), beforeList);
      expect(t.getRect(apk2Key(apk2Chart)), beforeChart);
      expect(t.getRect(apk2Row(apk2Meal)), beforeRow);
      expect(errors, isEmpty);
      expect(t.takeException(), isNull);
      // Disposed in the body: the binding checks handles before teardowns run.
      semantics.dispose();
    });
  }
}
