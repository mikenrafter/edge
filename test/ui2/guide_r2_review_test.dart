// Focused design regressions for structural review R1-R5. No catalogue or raster audit.
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_dim.dart';
import 'package:openstrap_edge/ui2/guides/guide_routes.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/skeleton/unit_paint.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import '../support/guide_text.dart';

const _target = ValueKey('review-target');
const _skeleton = ValueKey('review-skeleton');
const _dimmed = ValueKey('review-dimmed');

class _ScrollPage {
  final bool lazy;
  _ScrollPage({this.lazy = false});
  final scroll = ScrollController();
  final dim = GuideDimController();
  final nav = GlobalKey<NavigatorState>();
  final routes = GuideRouteObserver();
  late GuideRun run;
  late OverlayEntry entry;
  int dimTaps = 0, skeletonTaps = 0;

  Future<void> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 780);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(GuideDimScope(controller: dim, child: MaterialApp(
      navigatorKey: nav, navigatorObservers: [routes], scrollBehavior: const GuideScrollBehavior(),
      theme: buildTheme(Brightness.light), localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Stack(children: [
        Positioned(top: 16, left: 16, child: Pressable(key: _target, onTap: () {}, child: const Text('Target'))),
        Positioned(top: 80, left: 16, right: 16, bottom: 0, child: lazy ? ListView.builder(controller: scroll, itemCount: 100, itemExtent: 100,
          cacheExtent: 0, itemBuilder: (_, i) => Pressable(key: i == 0 ? _skeleton : i == 80 ? const ValueKey('lazy-target') : null,
            onTap: () => skeletonTaps++, child: Text('Item $i')))
          : SingleChildScrollView(controller: scroll,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Pressable(key: _skeleton, onTap: () => skeletonTaps++, child: const Surface(child: Text('Nearby'))),
            const SizedBox(height: 44),
            Pressable(key: _dimmed, onTap: () => dimTaps++, child: const Surface(child: Text('Different'))),
            const Text('Loose paragraph'),
            const SizedBox(height: 1400),
          ]))),
      ])))));
    await t.pump();
    final target = GuideTarget.key(lazy ? const ValueKey('lazy-target') : _target);
    final guide = Guide(id: 'review', title: fnText((_) => 'Review'), start: GuideStart.today,
      variants: [GuideVariant(steps: [GuideStep(id: 'target', target: target, anchor: GuideTarget.key(_target),
        action: lazy ? GuideAction.scrollThenTap : GuideAction.tap, caption: fnText((_) => 'Tap Target.'))])]);
    run = GuideRun(guide: guide, variant: guide.variants.single);
    entry = OverlayEntry(builder: (_) => LiveGuideOverlay(run: run, navigatorKey: nav, routes: routes,
      onExit: run.exit, onBackToGuide: () {}));
    nav.currentState!.overlay!.insert(entry);
    for (var i = 0; i < (lazy ? 2 : 12); i++) { await t.pump(Duration(milliseconds: lazy ? 0 : 100)); }
    addTearDown(() { if (entry.mounted) entry.remove(); run.dispose(); scroll.dispose(); dim.dispose(); });
  }
}

class _LooseLooks implements GuideLooseLooks {
  @override
  GuideUnitLook? lookOf(BuildContext unit) => null;
  @override
  GuideUnitLook? looseLookOf(RenderParagraph paragraph) => GuideUnitLook.dim;
}

void main() {
  // WHY: CLAIM(guide-live-hit-regions): scrolling moves both paint and input even before a plan runs.
  // # catches: cached overlay-coordinate skeleton shapes swallowing a newly arrived dimmed control.
  testWidgets('R1 skeleton hit regions read live boxes before replanning', (t) async {
    final page = _ScrollPage();
    await page.pump(t);
    final overlay = t.state<LiveGuideOverlayState>(find.byType(LiveGuideOverlay));
    final old = t.getRect(find.byKey(_skeleton));
    expect(overlay.paintedShapes.any((s) => s.kind.name == 'surface' && s.rect.overlaps(old)), isTrue);
    final before = overlay.planningCount;
    var sampled = false;
    // This callback runs after layout/paint and before post-frame planning. Dispatch real input there.
    t.binding.addPersistentFrameCallback((_) {
      if (sampled) return;
      sampled = true;
      expect(overlay.planningCount, before);
      final now = t.getRect(find.byKey(_dimmed));
      expect(now.overlaps(old), isTrue, reason: 'dimmed control moved under the former skeleton');
      final point = now.center;
      GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: 71, position: point));
      GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: 71, position: point));
      expect(page.dimTaps, 1, reason: 'exactly one real activation before the planner runs');
    });
    page.scroll.jumpTo(t.getRect(find.byKey(_dimmed)).top - old.top);
    await t.pump(const Duration(milliseconds: 16));
    expect(sampled, isTrue);
    expect(page.skeletonTaps, 0);
  });
  for (final explicitController in [true, false]) {
  // WHY: CLAIM(loose-scroll-repaint): viewport repaint boundaries must not leave loose masks behind.
  // # catches: an outer loose painter relying on plan notifications that equal plans suppress.
  testWidgets('R2 loose foreground repaints with its viewport without a new plan (explicit controller: $explicitController)', (t) async {
    final scroll = ScrollController();
    final dim = GuideDimController();
    addTearDown(scroll.dispose);
    addTearDown(dim.dispose);
    await t.pumpWidget(GuideDimScope(controller: dim, child: MaterialApp(
      scrollBehavior: const GuideScrollBehavior(), home: Scaffold(body: SingleChildScrollView(
        controller: explicitController ? scroll : null, child: const Column(children: [Text('Loose words'), SizedBox(height: 2000)]))))));
    dim.setLooks(_LooseLooks());
    await t.pump();
    final layer = t.renderObject<RenderGuideLoose>(find.byType(GuideLooseLayer));
    final plan = dim.looks;
    expect(layer.debugNeedsPaint, isFalse, reason: 'positive control: settled foreground');
    t.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(20);
    expect(identical(dim.looks, plan), isTrue);
    expect(layer.debugNeedsPaint, isTrue, reason: 'scroll itself invalidates the loose foreground');
    await t.pump();
    expect(layer.debugNeedsPaint, isFalse);
  });

  }

  for (final (name, top, height, label, skeleton) in [
    ('hit padding is outside ink reach', 100.0, 44.0, 'Other', false),
    ('nearby ink is eligible', 80.0, 44.0, 'Other', true),
    ('a distant matching word stays dim', 300.0, 44.0, 'Target option', false),
    ('a tall matching card stays dim', 70.0, 160.0, 'Target option', false),
  ]) {
    // WHY: CLAIM(skeleton-visible-reach): full component bounds paint; visible ink decides eligibility.
    // # catches: expanded hit boxes defining reach, or shared words bypassing reach/large exclusions.
    testWidgets('R3 $name', (t) async {
      const rootKey = ValueKey('policy-page');
      await t.pumpWidget(MaterialApp(home: Scaffold(body: Stack(key: rootKey, children: [
        Positioned(top: 20, left: 0, child: Pressable(key: _target, onTap: () {},
          child: const Text('Target', style: TextStyle(fontSize: 10, height: 1)))),
        Positioned(top: top, left: 0, child: SizedBox(height: height, width: 100,
          child: Pressable(key: _skeleton, onTap: () {}, child: Align(
            alignment: height > 120 ? Alignment.topLeft : Alignment.center,
            child: Text(label, style: const TextStyle(fontSize: 10, height: 1)))))),
      ]))));
      final root = t.element(find.byKey(rootKey));
      final targetBox = t.renderObject<RenderBox>(find.byKey(_target));
      final target = TargetFound(t.getRect(find.byKey(_target)), renderObject: targetBox);
      final plan = planSkeleton(root, keep: [target.rect], dim: DimPolicy.of(root, target));
      final unit = plan.units.singleWhere((u) => u.component?.widget.key == _skeleton);
      expect(unit.skeleton, skeleton);
      if (!skeleton) {
        final shape = plan.shapes.singleWhere((s) => s.section == unit.section);
        expect(shape.kind, SkeletonKind.dim);
        expect(shape.rect, t.getRect(find.byKey(_skeleton)), reason: 'dim still covers the full component');
      }
    });
  }

}
