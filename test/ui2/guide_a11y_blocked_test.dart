// WHY: a guide step lets the pointer through to the target and to DIMMED
// content, and absorbs it on PLACEHOLDER (skeleton) content. Before the pilot
// TalkBack ignored that: its double-tap performs the semantics tap directly,
// so a placeholder card still activated, and the page read in full under the
// step (inventory 6.01).
//
// CLAIM(A11Y-GUIDE-BLOCK): under a guide step a placeholder control has no tap
// action and reads as disabled; a dimmed control keeps its tap; the target
// proxy stays; with the guide gone, every control works again.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Pressable, ScreenTitle, Surface;

import '../support/live_guide_stage.dart';

Future<void> _settleReveal(WidgetTester t) async {
  await t.pump();
  await t.pump();
  await t.pump(kGuideRevealDuration + const Duration(milliseconds: 50));
  await t.pump();
}

SemanticsData _of(WidgetTester t, Key key) =>
    t.getSemantics(find.byKey(key)).getSemanticsData();

bool _overlaps(Iterable<SkeletonShape> shapes, Rect r) =>
    shapes.any((s) => s.rect.overlaps(r.deflate(1)));

void main() {
  testWidgets('placeholder controls cannot be activated by a screen reader; dimmed ones can', (t) async {
    final h = t.ensureSemantics();
    final stage = await pumpLiveStage(t);
    await _settleReveal(t);
    // The window rule (owner, 2026-11-14): the card right above the target's
    // card is dimmed, the cards further away are placeholders.
    await pushStagePage(t, stage, Scaffold(body: ListView(children: [
      const ScreenTitle('Stage home', key: stageHomeTitle),
      Pressable(key: stageElsewhereAction, onTap: () => stage.taps.elsewhere++,
          child: const Surface(child: Text('Far above'))),
      const SizedBox(height: 12),
      Pressable(key: stageOtherAction, onTap: () => stage.taps.otherAction++,
          child: const Surface(child: Text('Next to it'))),
      const SizedBox(height: 12),
      Pressable(key: stageOpenDetails, onTap: () => stage.taps.openDetails++,
          child: const Surface(child: Text('Open details'))),
    ])));
    await _settleReveal(t);
    final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    final shapes = overlay.paintedShapes;
    // Positive controls: the layers are what this test assumes.
    expect(_overlaps(shapes.where((x) => x.kind != SkeletonKind.dim), t.getRect(find.byKey(stageElsewhereAction))), isTrue,
        reason: 'the card two above the target is a placeholder');
    expect(_overlaps(shapes.where((x) => x.kind == SkeletonKind.dim), t.getRect(find.byKey(stageOtherAction))), isTrue,
        reason: 'the card right above the target is dimmed');

    final placeholder = _of(t, stageElsewhereAction);
    expect(placeholder.hasAction(SemanticsAction.tap), isFalse,
        reason: 'base: the semantics tap reached a control the pointer cannot');
    expect(placeholder.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(placeholder.hasFlag(SemanticsFlag.isEnabled), isFalse);
    expect(placeholder.label.contains('Far above'), isFalse,
        reason: 'placeholder content is not read under the step');

    final dimmed = _of(t, stageOtherAction);
    expect(dimmed.hasAction(SemanticsAction.tap), isTrue, reason: 'dimmed controls stay usable, as for the pointer');
    t.binding.pipelineOwner.semanticsOwner!
        .performAction(t.getSemantics(find.byKey(stageOtherAction)).id, SemanticsAction.tap);
    await t.pump();
    expect(stage.taps.otherAction, 1);

    expect(find.byKey(LiveGuideOverlay.targetProxyKey), findsOneWidget, reason: 'the step target stays reachable');

    // Guide gone: the placeholder card is a working button again.
    stage.entry!.remove();
    stage.entry = null;
    stage.dim.clear();
    await t.pump();
    await t.pump();
    expect(_of(t, stageElsewhereAction).hasAction(SemanticsAction.tap), isTrue);
    expect(_of(t, stageElsewhereAction).hasFlag(SemanticsFlag.hasEnabledState), isFalse);
    h.dispose();
  });
}
