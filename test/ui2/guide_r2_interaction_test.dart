import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/app.dart' show AppMainShell;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/activity/picker.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
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
    // turn the rest of Activity into anonymous controls and mascot blocks.
    // # catches: treating every tappable control as a skeleton candidate.
    if (id == 'log-past-workout') {
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
        final outside = overlay.paintedShapes.where((s) => s.kind.name != 'dim' && !r2Contains(row.inflate(1), s.rect));
        expect(outside, isEmpty, reason: 'B: only Overview/History look-alikes may be skeleton');
        expect(overlay.paintedShapes.where((s) => s.kind.name == 'erase'), isEmpty,
          reason: 'no scaffold erase patches on the purple start banner');
        for (final box in visible) {
          expect(overlay.paintedShapes.any((s) => s.kind.name == 'dim' && r2Contains(s.rect, box)), isTrue,
            reason: 'whole distant component must dim: $box');
        }
      } finally { await disposeR2(t, m); }
    });

    }

    // WHY: amendment A requires the dimmed Start card to perform its normal
    // action; the guide recovers by showing the off-path card.
    // # catches: shield swallowing the tap, redirecting it to History, or
    // synthesizing a second tap instead of letting the real gesture through.
    // proves: CLAIM(overlay-pass-through).
    testWidgets('r2 $id painted Start card opens the picker and goes off path', (t) async {
      final m = await pumpR2Scene(t, r2Scenes.firstWhere((s) => s.guide == id && s.step == 'open-history'));
      try {
        await settleLiveGuide(t, frames: 18);
        await t.tap(find.text(r2Locale.workoutStartSessionLabel));
        await settleLiveGuide(t, frames: 16);
        expect(find.byType(ActivityPicker), findsOneWidget, reason: 'normal Start-card navigation happened');
        expect(m.run.state, isA<GuideOffPath>());
        expect(find.byKey(GuideStepCard.offPathKey), findsOneWidget);
      } finally { await disposeR2(t, m); }
    });
  }

  // WHY: passing input through must preserve the exact real callback count.
  // # catches: forwarding a synthetic tap in addition to the original pointer,
  // or absorbing the dimmed control's original tap.
  testWidgets('r2 dimmed control receives exactly one callback per real tap', (t) async {
    final f = R2Fixture();
    await f.pump(t);
    await t.tapAt(t.getRect(find.byKey(r2Alternative)).center);
    await t.pump();
    expect(f.alternatives, 1);
    expect(f.targets, 0, reason: 'no redirect to the highlighted control');
    await t.tapAt(t.getRect(find.byKey(r2Alternative)).center);
    await t.pump();
    expect(f.alternatives, 2);
  });

  // WHY: amendment C defaults to no blocking even for the remaining skeleton
  // look-alikes. A label sharing Target is a plausible competing control.
  // # catches: removing only the dim shield while retaining skeleton hit blocking.
  testWidgets('r2 skeleton look-alike receives the original tap exactly once', (t) async {
    final f = R2Fixture(lookalike: true);
    await f.pump(t);
    final box = t.getRect(find.byKey(r2Alternative));
    final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    expect(overlay.paintedShapes.any((s) => s.kind.name != 'dim' && s.rect.overlaps(box)), isTrue,
      reason: 'positive control: this test actually taps a skeleton look-alike');
    await t.tapAt(box.center);
    await t.pump();
    expect(f.alternatives, 1);
    expect(f.targets, 0);
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
}
