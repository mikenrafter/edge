// WHY: accordion headers are navigation. A collapsed body must be a user-tapped
// hop, never a missing target or an input dead end (owner's Sleep repro).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/activity/picker.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_navigation.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';

import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import '../support/guide_text.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';


import '../support/bundled_fonts.dart';
import '../support/guide_r2_scenes.dart';
import '../support/guide_r7_scenes.dart';
import '../support/guide_search.dart';
import '../support/live_guide_harness.dart';
import '../support/skeleton_fixture.dart' show skLoadAppFonts;

int _unrelatedTaps = 0;
const _target = ValueKey('accordion-test-action');
GuideRun _run(WidgetTester t) => t.widget<LiveGuideOverlay>(find.byType(LiveGuideOverlay)).run;
LiveGuideOverlayState _overlay(WidgetTester t) => t.state(find.byType(LiveGuideOverlay));
Guide _guide() => Guide(id: 'accordion-test', title: fnText((_) => 'Accordion test'), start: GuideStart.sleep,
  variants: [GuideVariant(steps: [GuideStep(id: 'action', node: GuideNode.sleep,
    target: GuideTarget.key(_target), anchor: GuideTarget.key(_target),
    action: GuideAction.tap, caption: fnText((_) => 'Tap the action.'))])]);

Future<LiveGuideApp> _fixture(WidgetTester t, {bool nested = false, bool lazy = false, bool collapsed = true, Locale locale = const Locale('en')}) async {
  _unrelatedTaps = 0;
  Widget body = Pressable(key: _target, onTap: () {}, child: const Text('The action'));
  if (lazy) { final child = body; body = Builder(builder: (_) => child); }
  if (nested) body = SettingsAccordion('Inner', initiallyExpanded: false, children: [body]);
  final app = await pumpLiveGuideApp(t, locale: locale, size: r2Size,
    home: GuideLocation(node: GuideNode.sleep, child: Scaffold(body: SafeArea(child: SingleChildScrollView(
      child: Column(children: [const SizedBox(height: 80),
        SettingsAccordion('Outer', initiallyExpanded: !collapsed, children: [body]),
        for (var i = 0; i < 5; i++) Surface(child: Pressable(onTap: () => _unrelatedTaps++, child: Text('Unrelated $i'))),
        SettingsAccordion('Elsewhere', initiallyExpanded: false, children: const [Text('Other content')]),
      ]))))));
  expect(find.byKey(_target), collapsed ? findsNothing : findsOneWidget);
  final guide = _guide();
  final run = GuideRun(guide: guide, variant: guide.variants.single);
  final entry = OverlayEntry(builder: (_) => LiveGuideOverlay(run: run, navigatorKey: app.navigatorKey,
    routes: app.runner.routes, onExit: run.exit, onBackToGuide: () {}));
  app.navigator.overlay!.insert(entry);
  addTearDown(() { if (entry.mounted) entry.remove(); run.dispose(); });
  await settleMovingGuide(t);
  return app;
}

Future<void> _expand(WidgetTester t, String title) async {
  await t.tap(find.text(title));
  await settleMovingGuide(t);
}

void main() {
  setUpAll(() async { await loadFonts(); await skLoadAppFonts(); await r2OpenDb('guide_accordion.db'); });

  // catches: treating an unmounted body as absent; painting the hand over its hidden child.
  testWidgets('collapsed target becomes an expand hop, then the real target', (t) async {
    await _fixture(t);
    expect(find.text('Expand Outer'), findsWidgets);
    expect(_run(t).currentStep?.id, 'action');
    final header = t.getRect(find.ancestor(of: find.text('Outer'), matching: find.byType(Pressable)).first);
    expect(_overlay(t).targetRect, header);
    await _expand(t, 'Outer');
    expect(find.text('Expand Outer'), findsNothing);
    expect(_overlay(t).targetRect, t.getRect(find.byKey(_target)));
    expect(_run(t).state, isA<GuideAtStep>(), reason: 'expanding is not completing the final step');
    await t.tap(find.byKey(_target));
    await settleLiveGuide(t);
    expect(_run(t).state, isA<GuideFinished>());
  });

  // catches: only handling the first accordion ancestor or auto-opening both.
  testWidgets('nested collapsed accordions are two separate user hops', (t) async {
    await _fixture(t, nested: true);
    expect(find.text('Expand Outer'), findsWidgets);
    await _expand(t, 'Outer');
    expect(find.text('Expand Inner'), findsWidgets);
    expect(find.byKey(_target), findsNothing);
    await _expand(t, 'Inner');
    expect(_overlay(t).targetRect, t.getRect(find.byKey(_target)));
  });

  // catches: searching only the supplied widget descriptions, missing Builder/custom widget content.
  testWidgets('lazy body resolves behind its closed accordion', (t) async {
    await _fixture(t, lazy: true);
    expect(find.byKey(_target), findsNothing);
    expect(find.text('Expand Outer'), findsWidgets);
    await _expand(t, 'Outer');
    expect(_overlay(t).targetRect, t.getRect(find.byKey(_target)));
  });

  // catches: latching the expanded state after the first reveal.
  testWidgets('collapsing the current target returns to the expand hop', (t) async {
    await _fixture(t, collapsed: false);
    expect(_overlay(t).targetRect, t.getRect(find.byKey(_target)));
    await _expand(t, 'Outer');
    expect(find.text('Expand Outer'), findsWidgets);
    expect(_run(t).state, isA<GuideAtStep>());
    await _expand(t, 'Outer');
    expect(_overlay(t).targetRect, t.getRect(find.byKey(_target)));
  });

  // catches: a hole for only the focused header; a kept label whose parent card still blocks input.
  testWidgets('every header stays tappable while surrounding placeholders block taps', (t) async {
    final app = await _fixture(t, collapsed: false);
    final scroll = t.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await settleLiveGuide(t, frames: 15);
    final header = find.ancestor(of: find.text('Elsewhere'), matching: find.byType(Pressable)).first;
    final plan = app.runner.dim.looks!;
    expect(plan.lookOf(t.element(header)), isNull, reason: 'headers are navigation, including off focus');
    final ink = _overlay(t).layerInk;
    final holes = _overlay(t).layerHoles;
    final unrelated = t.getCenter(find.text('Unrelated 4'));
    expect(ink.any((r) => r.contains(unrelated)), isTrue, reason: 'positive control: ordinary content is blocked');
    expect(holes.any((r) => r.contains(unrelated)), isFalse);
    expect(holes.any((r) => r.contains(t.getCenter(header))), isTrue);
    await t.tapAt(unrelated);
    await settleLiveGuide(t);
    expect(_unrelatedTaps, 0, reason: 'placeholder consumes the actual pointer');
    await t.tap(header);
    await settleLiveGuide(t);
    expect(find.text('Other content'), findsOneWidget);
    expect(_run(t).state, isA<GuideAtStep>());
    _run(t).exit();
    await settleLiveGuide(t);
    await t.tap(find.text('Unrelated 4'));
    expect(_unrelatedTaps, 1, reason: 'positive control: the same real control works once the guide exits');
  });

  // catches: counting just the page Back and forgetting pending nested expansions.
  testWidgets('off-path taps back includes each collapsed accordion', (t) async {
    final app = await _fixture(t, nested: true);
    app.navigator.push(MaterialPageRoute<void>(builder: (_) => const GuideLocation(node: GuideNode.circadian,
      child: Scaffold(body: NavBar('Elsewhere page')))));
    await settleLiveGuide(t, frames: 18);
    expect(find.text(r2Locale.guideTapsBack(3)), findsOneWidget, reason: 'Back + Outer + Inner = three real taps');
    await app.navigator.maybePop();
    await settleMovingGuide(t);
    await _expand(t, 'Outer');
    app.navigator.push(MaterialPageRoute<void>(builder: (_) => const GuideLocation(node: GuideNode.circadian,
      child: Scaffold(body: NavBar('Elsewhere page')))));
    await settleLiveGuide(t, frames: 18);
    expect(find.text(r2Locale.guideTapsBack(2)), findsOneWidget, reason: 'Back + Inner, after Outer opened');
  });

  // catches: the new hop forcing animated motion despite the user preference.
  testWidgets('expand hop uses the static look with reduced motion', (t) async {
    t.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _fixture(t);
    expect(find.text('Expand Outer'), findsWidgets);
    expect(find.byKey(LiveGuideOverlay.handKey), findsNothing);
    expect(find.byKey(LiveGuideOverlay.outlineKey), findsOneWidget);
  });

  // WHY: localized hop labels use the accordion's runtime title in every shipped locale.
  const expansions = {'en': 'Expand Outer', 'de': 'Outer aufklappen', 'es': 'Expandir Outer',
    'fr': 'Développer Outer', 'hi': 'Outer खोलें', 'ru': 'Развернуть Outer', 'zh': '展开Outer'};
  for (final locale in expansions.keys) {
    testWidgets('expand label is localized in $locale', (t) async {
      await _fixture(t, locale: Locale(locale));
      expect(find.text(expansions[locale]!), findsWidgets);
    });
  }

  // WHY: real Sleep wiring must survive the five-card reorganisation; identify
  // the containing accordion structurally, never by its title or remembered id.
  for (final guideId in ['alarm-schedule', 'fix-sleep-times']) {
    testWidgets('$guideId reaches its action with all Sleep accordions collapsed', (t) async {
      final scene = r2Scenes.firstWhere((s) => s.guide == guideId);
      final m = await pumpR2Scene(t, scene, brightness: Brightness.dark);
      try {
        await settleMovingGuide(t);
        final ids = t.widgetList<SettingsAccordion>(find.byType(SettingsAccordion)).map((w) => w.id!).toList().reversed;
        for (final id in ids) {
          await pumpGuideSearch(t, revealTarget(m.app.runner.routes.page!, GuideTarget.key(ValueKey('accordion_$id')), r2Locale));
          final accordion = find.byWidgetPredicate((w) => w is SettingsAccordion && w.id == id);
          expect(accordion, findsOneWidget, reason: 'fixture can reveal section $id');
          final header = find.descendant(of: accordion, matching: find.byType(Pressable)).first;
          await Scrollable.ensureVisible(t.element(header), duration: Duration.zero);
          await t.pump();
          final labels = find.descendant(of: header, matching: find.byType(Semantics)).evaluate()
              .map((e) => (e.widget as Semantics).properties.label ?? '');
          if (labels.any((s) => s.endsWith(', expanded'))) await t.tap(header, warnIfMissed: false);
          await settleLiveGuide(t, frames: 3);
        }
        await settleMovingGuide(t);
        expect(find.byKey(LiveGuideOverlay.tapPillKey), findsOneWidget);
        expect(t.widget<Text>(find.descendant(of: find.byKey(LiveGuideOverlay.tapPillKey), matching: find.byType(Text)).first).data, startsWith('Expand '));
        await t.tapAt(_overlay(t).targetRect!.center);
        await settleMovingGuide(t);
        expect(_overlay(t).targetRect, isNotNull);
        final found = m.run.currentStep!.target.resolve(m.app.runner.routes.page!, r2Locale);
        expect(found, isA<TargetFound>());
      } finally { await disposeR2(t, m); }
    });
  }

  // WHY: picker groups are also accordions. Even its brief settling shield
  // must let a real header tap through. catches: the old full-screen absorber.
  testWidgets('picker accordion headers work during the expansion shield', (t) async {
    final m = await pumpR2Scene(t, r2Scenes.firstWhere((s) => s.id == 'start-workout/choose-activity'));
    try {
      await t.pump();
      for (var frame = 0; frame < 240 && !_overlay(t).isExpanding; frame++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(_overlay(t).isExpanding, isTrue, reason: 'fixture: automatic expansion is settling');
      final label = activityLibrary[1].displayName(t.element(find.byType(ActivityPicker)));
      final header = find.ancestor(of: find.text(label), matching: find.byType(Pressable)).first;
      await t.tap(header);
      await t.pump();
      final rotation = find.descendant(of: header, matching: find.byType(AnimatedRotation));
      expect(t.widget<AnimatedRotation>(rotation).turns, .25, reason: 'real tap expands the second group');
    } finally { await disposeR2(t, m); }
  });

  final out = Platform.environment['GUIDE_ACCORDION_RENDER_DIR'];
  testWidgets('dark alarm evidence before and after expansion', (t) async {
    final capture = GlobalKey();
    final m = await pumpR2Scene(t, r2Scenes.firstWhere((s) => s.id == 'alarm-schedule/open-alarm'),
      brightness: Brightness.dark, captureKey: capture, devicePixelRatio: 2.625);
    try {
      await settleMovingGuide(t);
      final header = find.ancestor(of: find.text('Alarm and body clock'), matching: find.byType(Pressable)).first;
      await t.tap(header);
      await settleMovingGuide(t);
      Future<void> png(String name) async {
        final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(capture));
        await t.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2.625);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$out/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await png('alarm-collapsed');
      await t.tapAt(_overlay(t).targetRect!.center);
      await settleMovingGuide(t);
      await png('alarm-expanded');
    } finally { await disposeR2(t, m); }
  }, skip: out == null);
}
