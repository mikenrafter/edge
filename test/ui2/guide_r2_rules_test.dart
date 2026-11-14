import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_catalogue.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/guides/tree_geometry.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import '../support/bundled_fonts.dart';
import '../support/skeleton_fixture.dart' show skLoadAppFonts;
import '../support/guide_r2_manifest.dart';
import '../support/guide_r2_scenes.dart';
import '../support/live_guide_harness.dart';

void main() {
  setUpAll(() async {
    await loadFonts();
    await skLoadAppFonts();
    await r2OpenDb('guide_r2_rules.db');
  });
  tearDownAll(LocalDb.close);

  // WHY: a deleted fixture must fail before a vacuous every-step guard passes.
  // # catches: adding a catalogue step without adding a real-shell scene.
  // proves: CLAIM(guide-covered).
  test('r2 scenes cover all eight guides and every step exactly once', () {
    expect(r2Scenes.map((s) => s.id).toList()..sort(), [
      for (final e in kGuideCatalogue) for (final v in e.guide.variants)
        for (final s in v.steps) '${e.guide.id}/${s.id}',
    ]..sort());
    expect(r2Scenes.length, 22);
    expect(r2Scenes.map((s) => s.guide).toSet().length, 8);
  });

  // WHY: only the three owner-selected pilots change appearance. An omitted
  // opt-in silently changes another guide or leaves a pilot on the old look.
  // # catches: making dim the default or accidentally opting in a fourth guide.
  test('r2 only the three pilots opt into dim; other five keep skeleton', () {
    for (final entry in kGuideCatalogue) {
      expect(entry.guide.look, r2Pilots.contains(entry.guide.id) ? GuideLook.dim : GuideLook.skeleton,
        reason: entry.guide.id);
    }
    final source = r2Guide('start-workout');
    expect(Guide(id: 'default', title: source.title, start: source.start, variants: source.variants).look,
      GuideLook.skeleton);
  });

  for (final scene in r2Scenes) {
    if (r2Pilots.contains(scene.guide)) {
    // WHY: r2 P1–P5/P7–P9 apply to every pilot step.
    // # catches: blanket skeletonization, per-line dim/erase, missed kept section,
    // hidden caption context or a shape on chrome/blank scaffold.
    // proves: CLAIM(kept-untouched), CLAIM(guide-covered).
    testWidgets('r2 P1-P9 manifest guard ${scene.id}', (t) async {
      final m = await pumpR2Scene(t, scene);
      try {
        await settleLiveGuide(t, frames: 18);
        expect(m.run.currentStep?.id, scene.step, reason: 'fixture must show the intended live step');
        final manifest = r2Manifest(t, m, scene);
        await r2WriteManifest(t, scene, manifest);
        expect(manifest['units'], isNotEmpty, reason: 'positive control: the real page supplies classified units');
        expect(manifest['violations'], isEmpty, reason: '${scene.id}: P1-P9 independent component oracle');
      } finally { await disposeR2(t, m); }
    });

    }

    // WHY: P6 must explain target absence at intermediate scroll offsets as
    // well as at the final reveal destination; card safety is a per-frame rule.
    // # catches: drawing a clipped outline for an offscreen target, no marker
    // during discovery, or card/dim/skeleton covering the visible target.
    // proves: CLAIM(card-never-covers-target), CLAIM(overlay-reveal).
    testWidgets('r2 visibility at every reached scroll offset ${scene.id}', (t) async {
      final m = await pumpR2Scene(t, scene);
      final violations = <String>[];
      final offsets = <String>{};
      final observations = <Map<String, Object?>>[];
      try {
        for (var frame = 0; frame < 22; frame++) {
          await settleLiveGuide(t, frames: 1);
          final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
          final page = m.app.runner.routes.page!;
          final positions = [for (final e in builtElements(page))
            if (e is StatefulElement && e.state is ScrollableState)
              (e.state as ScrollableState).position.pixels];
          offsets.add(positions.toString());
          final target = overlay.targetRect;
          final visible = target != null && r2Contains(Offset.zero & r2Size, target);
          final marker = find.byKey(LiveGuideOverlay.scrollMarkerKey);
          final cardFinder = find.byKey(GuideStepCard.cardKey);
          final frameCard = cardFinder.evaluate().isEmpty ? null : t.getRect(cardFinder);
          observations.add({'frame': frame, 'offsets': positions,
            'target': target == null ? null : r2Rect(target),
            'revealProgress': overlay.revealProgress,
            'marker': marker.evaluate().isEmpty ? null : r2Rect(t.getRect(marker)),
            'card': frameCard == null ? null : r2Rect(frameCard)});
          // The original progressive reveal intentionally delays the outline.
          // Once it completes, every position must satisfy the full invariant.
          if (overlay.revealProgress < 1 && visible) continue;
          if (!visible && r2Pilots.contains(scene.guide)) {
            if (find.byKey(LiveGuideOverlay.scrollMarkerKey).evaluate().isEmpty) {
              violations.add('frame $frame offsets=$positions: offscreen/unbuilt target has no scroll marker');
            } else if (target != null) {
              final rotation = t.widget<RotatedBox>(marker).quarterTurns % 4;
              final expectedDirection = target.top < 0 ? 3 : 1;
              if (rotation != expectedDirection) {
                violations.add('frame $frame: scroll arrow points away from target $target');
              }
            }
          } else if (visible) {
            final outline = find.byKey(LiveGuideOverlay.outlineKey);
            if (outline.evaluate().isEmpty || !r2Contains(t.getRect(outline), target)) {
              violations.add('frame $frame offsets=$positions: target not fully outlined');
            }
            if (frameCard?.overlaps(target) ?? false) violations.add('frame $frame: card covers target');
            if (overlay.paintedShapes.any((s) => s.rect.overlaps(target.deflate(.5)))) {
              violations.add('frame $frame: painted placeholder/dim covers target');
            }
          }
        }
        final file = File('build/guides-r2/${scene.guide}/${scene.step}.scroll.json');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
          'guide': scene.guide, 'step': scene.step, 'observations': observations, 'violations': violations}));
        expect(m.run.currentStep?.id, scene.step);
        expect(offsets, isNotEmpty, reason: 'observed the live page, including non-scroll pages');
        expect(violations, isEmpty, reason: scene.id);
      } finally { await disposeR2(t, m); }
    });

    // WHY: pushed pages still need the shell tab strip as chrome and bounds.
    // # catches: defaultSkeletonChrome searching only the top route subtree.
    testWidgets('r2 chrome finds shell tabs on ${scene.id}', (t) async {
      final m = await pumpR2Scene(t, scene);
      try {
        await settleLiveGuide(t, frames: 18);
        final tab = t.getRect(r2Tabs(hidden: true));
        final page = m.app.runner.routes.page!;
        final root = laidOutBox(page)!;
        final localTab = tab.shift(-root.localToGlobal(Offset.zero));
        final chrome = defaultSkeletonChrome(page);
        expect(chrome.any((r) => r2Contains(r, localTab)), isTrue,
          reason: 'P4: shell tabs must be found from every top page');
        final card = t.getRect(find.byKey(GuideStepCard.cardKey));
        expect(card.overlaps(tab), isFalse, reason: 'card bounds must stop above shell tabs');
      } finally { await disposeR2(t, m); }
    });

    // WHY: gesture wiring must obey tab bounds on every page, not just a
    // correctly configured pure placement helper.
    // # catches: drag clamping to the full viewport on pushed pages, or x drift.
    // proves: CLAIM(card-never-covers-target).
    testWidgets('r2 dragged card stays above tabs on ${scene.id}', (t) async {
      final m = await pumpR2Scene(t, scene);
      try {
        await settleLiveGuide(t, frames: 18);
        final initial = t.getRect(find.byKey(GuideStepCard.cardKey));
        for (final dy in [-180.0, 2000.0, -2000.0]) {
          final before = t.getRect(find.byKey(GuideStepCard.cardKey));
          await t.dragFrom(Offset(before.right - 7, before.center.dy), Offset(60, dy));
          await settleLiveGuide(t, frames: 2);
          final card = t.getRect(find.byKey(GuideStepCard.cardKey));
          final tabs = t.getRect(r2Tabs(hidden: true));
          expect(card.left, initial.left);
          expect(card.width, initial.width);
          expect(card.top, greaterThanOrEqualTo(0));
          expect(card.bottom, lessThanOrEqualTo(tabs.top), reason: scene.id);
          final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
          final target = overlay.targetRect!;
          expect(card.overlaps(target), isFalse);
          expect(card.overlaps(t.getRect(find.byKey(LiveGuideOverlay.tapPillKey))), isFalse);
        }
      } finally { await disposeR2(t, m); }
    });

    if (scene.shell) {
      for (var tab = 0; tab < 4; tab++) {
        // WHY: every shell step must permit every tab tap, including a re-tap;
        // the owner's r2 decision makes that deliberate navigation off path.
        // # catches: shield absorbs a tab, card hides it, or route matching
        // silently resumes a step instead of showing the off-path card.
        // proves: CLAIM(overlay-pass-through).
        testWidgets('r2 tab $tab navigates off path from ${scene.id}', (t) async {
          final m = await pumpR2Scene(t, scene);
          try {
            await settleLiveGuide(t, frames: 18);
            final rect = t.getRect(r2Tab(tab));
            expect(t.getRect(find.byKey(GuideStepCard.cardKey)).overlaps(rect), isFalse);
            await t.tapAt(rect.center);
            await settleLiveGuide(t, frames: 12);
            expect(m.run.state, isA<GuideOffPath>(), reason: 'tab $tab from ${scene.id}');
            expect(find.byKey(GuideStepCard.offPathKey), findsOneWidget);
            final widget = t.widget(r2Tab(tab));
            final selected = find.descendant(of: find.byWidget(widget), matching: find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.selected == true));
            expect(selected, findsOneWidget, reason: 'the actual tab changed, not just the guide card');
          } finally { await disposeR2(t, m); }
        });
      }
    }
  }
}
