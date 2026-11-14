import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import '../support/guide_r2_fixture.dart';

void main() {
  // WHY: P2/P9 protect the purple component's background, not just its glyphs.
  // # catches: opaque per-line erase fills, duplicate dim layers, or text-only dim.
  testWidgets('r2 dim is one translucent whole coloured component with no erase', (t) async {
    final f = R2Fixture();
    await f.pump(t);
    final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    final rect = t.getRect(find.byKey(r2Quiet));
    final shapes = overlay.paintedShapes.where((s) => s.rect.overlaps(rect.deflate(1))).toList();
    expect(shapes.map((s) => s.kind.name), ['dim'], reason: 'one layer; no per-line surface/bar/erase');
    expect(shapes.single.rect, rect, reason: 'includes purple padding/background');
    expect(shapes.single.color!.a, inExclusiveRange(0, 1), reason: 'light dim must preserve original content');
  });

  // WHY: a diagnostic plan can claim dim while the painter still erases it.
  // # catches: painting only glyphs or painting opaque scaffold over purple.
  testWidgets('r2 dim changes coloured padding pixels without erasing the component', (t) async {
    final f = R2Fixture();
    await f.pump(t);
    final rect = t.getRect(find.byKey(r2Quiet));
    Future<List<int>> sample() async {
      final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(r2Capture));
      return (await t.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          final i = ((rect.top + 8).toInt() * image.width + rect.left.toInt() + 24) * 4;
          return [for (var c = 0; c < 4; c++) bytes.getUint8(i + c)];
        } finally { image.dispose(); }
      }))!;
    }
    final guided = await sample();
    f.entry!.remove();
    await t.pump();
    final plain = await sample();
    expect(plain, [112, 64, 160, 255], reason: 'positive control: sample is purple component padding');
    expect(guided, isNot(plain), reason: 'the whole background receives dim');
    expect(guided[3], 255, reason: 'composited onto an opaque app');
    expect(guided.take(3).toSet().length, greaterThan(1), reason: 'translucency retains purple, not a grey erase');
  });

  // WHY: P7 offers an alternative action, not merely a readable label.
  // # catches: consuming alsoTap for paint only while omitting shield holes.
  // proves: CLAIM(overlay-pass-through).
  testWidgets('r2 declared alternative is legible and its pointer reaches the real control', (t) async {
    final f = R2Fixture(declarations: true);
    await f.pump(t);
    final rect = t.getRect(find.byKey(r2Alternative));
    await t.tapAt(rect.center);
    await t.pump();
    expect(f.alternatives, 1, reason: 'actual callback observed, never called by the test');
    final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    expect(overlay.paintedShapes.where((s) => s.rect.overlaps(rect.deflate(1))), isEmpty);
  });

  // WHY: P8 asks the user to read the named details.
  // # catches: ignoring alsoRead and keeping only the primary target.
  testWidgets('r2 caption details stay legible', (t) async {
    final f = R2Fixture(declarations: true);
    await f.pump(t);
    final rect = t.getRect(find.byKey(r2Details));
    final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    expect(overlay.paintedShapes.where((s) => s.rect.overlaps(rect.deflate(1))), isEmpty);
  });

  // WHY: off-path r2 decision dims all page components, including their boxes.
  // # catches: step==null disables the painter and leaves the entire page full colour.
  testWidgets('r2 off path dims content and non-return chrome', (t) async {
    final f = R2Fixture();
    await f.pump(t);
    await f.elsewhere(t);
    expect(find.byKey(GuideStepCard.offPathKey), findsOneWidget);
    final rect = t.getRect(find.byKey(r2Other));
    final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    expect(overlay.paintedShapes.where((s) => s.kind.name == 'dim' && s.rect.overlaps(rect)), isNotEmpty);
    final title = t.getRect(find.text('Elsewhere'));
    expect(overlay.paintedShapes.any((s) => s.kind.name == 'dim' && s.rect.overlaps(title)), isTrue,
      reason: 'only back arrow, not the entire NavBar, is exempt off path');
  });

  // WHY: amendment A/C keeps dimmed controls interactive even off path.
  // # catches: keeping a shield that absorbs off-path dimmed controls.
  testWidgets('r2 off path dimmed controls and route-back arrow still work', (t) async {
    final f = R2Fixture();
    await f.pump(t);
    await f.elsewhere(t);
    await t.tapAt(t.getRect(find.byKey(r2Other)).center);
    await t.pump();
    expect(f.others, 1, reason: 'one real tap, one real callback');
    await t.tapAt(const Offset(24, 28));
    await f.frames(t);
    expect(find.text('Elsewhere'), findsNothing, reason: 'real NavBar back returns to step');
  });

  // WHY: the explicit return action is the other full-colour off-path escape.
  // # catches: dim/shield covers Back to the guide or swallows its tap.
  testWidgets('r2 off path Back to the guide remains tappable', (t) async {
    final f = R2Fixture();
    await f.pump(t);
    await f.elsewhere(t);
    await t.tap(find.byKey(GuideStepCard.backToGuideKey));
    await f.frames(t);
    expect(f.returns, 1);
    expect(find.byKey(GuideStepCard.offPathKey), findsNothing);
  });
}
