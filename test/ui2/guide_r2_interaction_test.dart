import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart' show kSkeletonReach;
import 'package:openstrap_edge/app.dart' show AppMainShell;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/activity/picker.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import '../support/live_guide_stage.dart';
import '../support/guide_r2_scroll_fixture.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import '../support/guide_r2_fixture.dart';
import '../support/guide_r2_manifest.dart';
import '../support/guide_r2_scenes.dart';
import '../support/live_guide_harness.dart';

void main() {
  setUpAll(() => r2OpenDb('guide_r2_interaction.db'));
  tearDownAll(LocalDb.close);

  for (final id in ['log-past-workout', 'delete-workout']) {
    // WHY: amendment B names these screenshots: a small History target cannot
    // turn the rest of Activity into anonymous controls and mascot blocks. Structural
    // r2: both History guides (log-past-workout and delete-workout) share the page.
    // # catches: treating every tappable control as a skeleton candidate.
    testWidgets('r2 $id open-history has zero skeleton outside its sub-tab group', (t) async {
      final m = await pumpR2Scene(t, r2Scenes.firstWhere((s) => s.guide == id && s.step == 'open-history'));
      try {
        await settleLiveGuide(t, frames: 18);
        final row = t.getRect(find.ancestor(of: find.text(r2Locale.workoutTabHistory),
          matching: find.byType(SubTabs)).first);
        final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
        final start = find.ancestor(of: find.text(r2Locale.workoutStartSessionLabel),
          matching: find.byWidgetPredicate((w) => w is Pressable && w.onTap != null)).first;
        final quick = find.byWidgetPredicate((w) => w.runtimeType.toString() == 'WorkoutQuickTile').first;
        final units = <Rect>[t.getRect(start), t.getRect(quick)];
        for (final label in [r2Locale.homeSteps, r2Locale.nutritionTitle]) {
          units.add(t.getRect(find.ancestor(of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is Pressable && w.onTap != null)).first));
        }
        final visible = units.map((r) => r.intersect(Offset.zero & r2Size)).toList();
        expect(visible.every((r) => !r.isEmpty), isTrue, reason: 'all four named components are actually visible');
        final outside = overlay.paintedShapes.where((s) => s.kind.name != 'dim' && !r2Contains(row.inflate(kSkeletonReach + 1), s.rect));
        expect(outside, isEmpty, reason: 'B (falloff): skeleton only on controls within kSkeletonReach of the sub-tab row');
        expect(overlay.paintedShapes.where((s) => s.kind.name == 'erase'), isEmpty,
          reason: 'no scaffold erase patches on the purple start banner');
        for (final box in visible) {
          expect(overlay.paintedShapes.any((s) => s.kind.name == 'dim' && r2Contains(s.rect, box)), isTrue,
            reason: 'whole distant component must dim: $box');
        }
      } finally { await disposeR2(t, m); }
    });

    // WHY: input per layer holds for EVERY guide (structural r2): the Start card is a
    // LARGE unit, so it is dimmed (clickable) rather than skeleton (blocked); its tap
    // navigates for real, once, and the run goes off path. The old rule kept
    // delete-workout on blocking legacy skeletons.
    // # catches: a legacy-look guide that still blocks dimmed content, a large card
    // skeletonized and therefore dead, or W2 redirect.
    // proves: CLAIM(overlay-pass-through).
    testWidgets('r2 $id painted Start card opens the picker and goes off path', (t) async {
      final m = await pumpR2Scene(t, r2Scenes.firstWhere((s) => s.guide == id && s.step == 'open-history'));
      try {
        await settleLiveGuide(t, frames: 18);
        await t.tap(find.text(r2Locale.workoutStartSessionLabel));
        await settleLiveGuide(t, frames: 16);
        expect(find.byType(ActivityPicker), findsOneWidget, reason: 'dimmed Start-card navigation happened');
        expect(m.run.state, isA<GuideOffPath>());
        expect(find.byKey(GuideStepCard.offPathKey), findsOneWidget);
      } finally { await disposeR2(t, m); }
    });
  }

  // WHY: passing input through must preserve the exact real callback count.
  // # catches: W2 redirected advance, forwarding a synthetic tap in addition to the original pointer,
  // or absorbing the dimmed control's original tap.
  testWidgets('r2 dimmed control receives exactly one callback per real tap', (t) async {
    final f = R2Fixture();
    await f.pump(t);
    await t.tapAt(t.getRect(find.byKey(r2Alternative)).center);
    await t.pump(const Duration(milliseconds: 400));
    expect(f.alternatives, 1);
    expect(f.targets, 0, reason: 'no redirect to the highlighted control');
    expect(f.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0), reason: 'T1/W2: wrong tap never advances');
    await t.tapAt(t.getRect(find.byKey(r2Alternative)).center);
    await t.pump(const Duration(milliseconds: 400));
    expect(f.alternatives, 2);
    expect(f.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0));
  });

  // WHY: owner reversal requires skeleton look-alikes to block taps.
  // # catches: W2 redirected advance, or passing skeleton input through as dim.
  testWidgets('r2 skeleton look-alike blocks tap and preserves run', (t) async {
    final f = R2Fixture(lookalike: true);
    await f.pump(t);
    final box = t.getRect(find.byKey(r2Alternative));
    final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    expect(overlay.paintedShapes.any((s) => s.kind.name != 'dim' && s.rect.overlaps(box)), isTrue,
      reason: 'positive control: this test actually taps a skeleton look-alike');
    await t.tapAt(box.center);
    await t.pump(const Duration(milliseconds: 400));
    expect(f.alternatives, 0);
    expect(f.targets, 0);
    expect(f.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0), reason: 'T1/W2');
  });

  // WHY: amendment A includes real scrolling through dimmed content. Observe
  // drag-origin updates even if automatic target reveal later moves it back.
  // # catches: a full-page shield that passes isolated taps but swallows drags.
  testWidgets('r2 dimmed content passes a drag to the real Activity scrollable', (t) async {
    var dragDistance = 0.0;
    final app = await pumpLiveGuideApp(t, size: r2Size, home: NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollUpdateNotification && n.dragDetails != null && n.metrics.axis == Axis.vertical) {
          dragDistance += n.scrollDelta!.abs();
        }
        return false;
      }, child: const AppMainShell()));
    try {
      await app.runner.start(r2Guide('log-past-workout'), band: null);
      await settleLiveGuide(t, frames: 18);
      final control = find.ancestor(of: find.text(r2Locale.workoutStartSessionLabel),
        matching: find.byWidgetPredicate((w) => w is Pressable && w.onTap != null)).first;
      dragDistance = 0;
      await t.dragFrom(t.getRect(control).center, const Offset(0, -140));
      expect(dragDistance, greaterThan(20), reason: 'real scroll updates caused by this pointer drag');
      expect(find.byType(ActivityPicker), findsNothing, reason: 'a drag must not be duplicated as a tap');
    } finally {
      app.runner.exit();
      await t.pumpWidget(const SizedBox());
      app.dispose();
      await t.pump();
    }
  });
  for (final gesture in ['tap', 'long press', 'double tap']) {
    // WHY: owner reversal of W3 blocks all activation gestures on skeletons
    // without advancing or finishing the run.
    // # catches: replaying taps, or blocking only single taps but leaking long/double press.
    testWidgets('r2 skeleton look-alike blocks $gesture', (t) async {
      final f = R2Fixture(lookalike: true);
      await f.pump(t);
      final box = t.getRect(find.byKey(r2Alternative));
      final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
      expect(overlay.paintedShapes.any((s) => s.kind.name != 'dim' && s.rect.overlaps(box)), isTrue);
      switch (gesture) {
        case 'long press': await t.longPressAt(box.center);
        case 'double tap':
          await t.tapAt(box.center);
          await t.pump(const Duration(milliseconds: 100));
          await t.tapAt(box.center);
        case 'tap': await t.tapAt(box.center);
      }
      await t.pump(const Duration(milliseconds: 400));
      expect(f.longPresses, 0);
      expect(f.doubleTaps, 0);
      expect(f.dragUpdates, 0);
      expect(f.alternatives, 0, reason: 'skeleton activation never reaches the underlying control');
      expect(f.targets, 0);
      expect(f.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0));
    });
  }

  // WHY: D-S9 a normal dimmed control may open a dialog. The guide yields
  // paint and input until it closes, preserving both the dialog and run.
  // # catches: keeping the guide shield/card above a dialog opened off target.
  testWidgets('r2 dimmed dialog opener yields overlay and preserves run', (t) async {
    final base = stageGuide();
    final guide = Guide(id: base.id, title: base.title, start: base.start,
      look: GuideLook.dim, variants: base.variants, footers: base.footers);
    final stage = await pumpLiveStage(t, guide: guide);
    for (var i = 0; i < 12; i++) { await t.pump(const Duration(milliseconds: 100)); }
    await t.tap(find.byKey(stageAskFirst));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byKey(GuideStepCard.cardKey), findsNothing, reason: 'overlay yields to modal');
    expect(find.byKey(LiveGuideOverlay.outlineKey), findsNothing);
    expect(stage.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0));
    await t.tap(find.text('Confirm'));
    await t.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 12; i++) { await t.pump(const Duration(milliseconds: 100)); }
    expect(stage.taps.dialogConfirm, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(GuideStepCard.cardKey), findsOneWidget);
    expect(stage.run.currentStep?.id, 'open');
  });

  // WHY: owner reversal of W3 still permits vertical scroll beginning on a
  // skeleton; otherwise users cannot scroll through P6 placeholders.
  // # catches: using AbsorbPointer over skeletons and swallowing scroll drags.
  testWidgets('r2 vertical drag starting on skeleton scrolls the real page', (t) async {
    final f = R2ScrollFixture();
    await f.pump(t, GuideLook.dim);
    final box = t.getRect(find.byKey(r2ScrollLookalike));
    final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    final shapes = overlay.paintedShapes.where((s) => s.kind.name != 'dim' && s.rect.overlaps(box)).toList();
    expect(shapes, isNotEmpty, reason: 'gesture begins on actual skeleton ink');
    final before = f.controller.offset;
    await t.dragFrom(shapes.first.rect.intersect(box).center, const Offset(0, -100));
    await t.pump(const Duration(milliseconds: 50));
    expect(f.controller.offset, greaterThan(before + 40));
    expect(f.lookalikeTaps, 0, reason: 'scroll does not synthesize activation');
    expect(f.run.state, isA<GuideAtStep>().having((s) => s.index, 'index', 0));
  });

}
