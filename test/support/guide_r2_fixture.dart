import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_routes.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'guide_text.dart';

const r2Target = ValueKey('r2-target');
const r2Alternative = ValueKey('r2-alternative');
const r2Quiet = ValueKey('r2-quiet');
const r2Details = ValueKey('r2-details');
const r2Other = ValueKey('r2-other');
const r2Capture = ValueKey('r2-capture');

// Test-side selector supplies real laid-out target boxes to the new interface.
// It does not replace the overlay's planning, painting or shield.
class R2Content implements GuideContent {
  final List<Key> keys;
  const R2Content(this.keys);
  @override
  List<TargetFound> resolve(Element root, AppLocalizations l) => [
    for (final key in keys)
      if (GuideTarget.key(key).resolve(root, l) case final TargetFound found) found,
  ];
}

class R2Fixture {
  final navKey = GlobalKey<NavigatorState>();
  final routes = GuideRouteObserver();
  final targetTop = ValueNotifier<double>(100);
  final Guide guide;
  late GuideRun run;
  final bool lookalike;
  OverlayEntry? entry;
  int targets = 0, alternatives = 0, others = 0, exits = 0, returns = 0;
  R2Fixture({bool declarations = false, this.lookalike = false}) : guide = Guide(id: 'r2-fixture', look: GuideLook.dim,
    title: fnText((_) => 'Fixture'), start: GuideStart.today, variants: [GuideVariant(steps: [
      GuideStep(id: 'target', target: GuideTarget.key(r2Target), anchor: GuideTarget.key(r2Target),
        action: GuideAction.tap, caption: fnText((_) => 'Tap Target or Alternative. Check the details.'),
        alsoTap: declarations ? [const R2Content([r2Alternative])] : const [],
        alsoRead: declarations ? [const R2Content([r2Details])] : const []),
    ])], footers: [GuideFooter(kind: GuideFooterKind.missingTarget,
      title: fnText((_) => 'Missing?'), body: fnText((_) => 'Details help.'))]);

  Widget get home => Scaffold(body: ValueListenableBuilder<double>(
    valueListenable: targetTop, builder: (_, y, _) => Stack(children: [
      const Positioned(top: 8, left: 16, right: 16, child: ScreenTitle('Fixture title')),
      Positioned(top: y, left: 16, right: 16, child: Pressable(key: r2Target,
        onTap: () => targets++, child: const Surface(child: Text('Target')))),
      const Positioned(top: 220, left: 16, right: 16, child: Surface(key: r2Quiet,
        color: Color(0xff7040a0), child: Text('Quiet information', style: TextStyle(color: Colors.white)))),
      Positioned(top: 310, left: 16, right: 16, child: Pressable(key: r2Alternative,
        onTap: () => alternatives++, child: Surface(child: Text(lookalike ? 'Target option' : 'Alternative')))),
      const Positioned(top: 390, left: 16, right: 16, child: Section('Details', Surface(child: Text('Read this context')), key: r2Details)),
    ])));

  Future<void> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 780);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(RepaintBoundary(key: r2Capture, child: MaterialApp(
      navigatorKey: navKey, navigatorObservers: [routes], theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales, locale: const Locale('en'), home: home)));
    await t.pump();
    await start(t);
    addTearDown(() { if (entry?.mounted ?? false) entry!.remove(); run.dispose(); targetTop.dispose(); });
  }
  Future<void> start(WidgetTester t) async {
    run = GuideRun(guide: guide, variant: guide.variants.single);
    entry = OverlayEntry(builder: (_) => LiveGuideOverlay(run: run, navigatorKey: navKey,
      routes: routes, onExit: () => exits++, onBackToGuide: () { returns++; navKey.currentState!.pop(); }));
    navKey.currentState!.overlay!.insert(entry!);
    await frames(t);
  }
  Future<void> restart(WidgetTester t) async {
    entry!.remove();
    await t.pump();
    run.dispose();
    await start(t);
  }
  Future<void> frames(WidgetTester t) async {
    for (var i = 0; i < 12; i++) { await t.pump(const Duration(milliseconds: 100)); }
  }
  Future<void> elsewhere(WidgetTester t) async {
    navKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: Column(children: [
      const NavBar('Elsewhere'),
      Pressable(key: r2Other, onTap: () => others++, child: const Surface(child: Text('Other action'))),
    ]))));
    await frames(t);
  }
}
