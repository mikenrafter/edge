import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/guides/guide_navigation.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import '../support/guide_text.dart';

void main() {
  // WHY: Activity History is a real destination inside an already-selected tab.
  // proves: CLAIM(guide-navigation-hops).
  // # catches: returning to Activity instead of selecting History.
  test('A: History uses the sub-tab, and a form detour returns through its parent pages', () {
    final local = GuideNavigation.route(GuideNode.activityOverview, GuideNode.activityHistory);
    expect(local.map((h) => h.kind), [GuideHopKind.subTab]);
    expect(local.single.node, GuideNode.activityHistory);
    final deep = GuideNavigation.route(GuideNode.setup, GuideNode.activityHistory);
    expect(deep.map((h) => h.kind), [GuideHopKind.back, GuideHopKind.back, GuideHopKind.subTab]);
    expect(deep.map((h) => h.node), [GuideNode.picker, GuideNode.activityOverview, GuideNode.activityHistory]);
    final two = GuideNavigation.route(GuideNode.workoutSummary, GuideNode.activityOverview);
    expect(two.map((h) => h.kind), [GuideHopKind.back]);
  });

  // WHY: a step may be below its loading parent, but another branch is off path.
  // # catches: anchor-only detection and treating every node under Activity as on path.
  test('A: ancestors are on path; siblings and descendants are not', () {
    expect(GuideNavigation.onPath(GuideNode.today, GuideNode.zones), isTrue);
    expect(GuideNavigation.onPath(GuideNode.dayStrain, GuideNode.zones), isTrue);
    expect(GuideNavigation.onPath(GuideNode.activityOverview, GuideNode.activityHistory), isFalse);
    expect(GuideNavigation.onPath(GuideNode.zones, GuideNode.dayStrain), isFalse);
    expect(GuideNavigation.onPath(GuideNode.health, GuideNode.zones), isFalse);
  });

  // WHY: navigation must exist before a page's anchors/data arrive.
  // # catches: inspecting only target labels or selected shell tabs.
  testWidgets('A: loading Activity root retains its selected History node', (t) async {
    // This lightweight page has the same declared screen identity and real sub-tabs;
    // it deliberately contains none of the guide's anchors or loaded cards.
    await t.pumpWidget(const MaterialApp(home: _LoadingActivity()));
    expect(GuideNavigation.location(t.element(find.byType(_LoadingActivity))), GuideNode.activityHistory);
  });
  // WHY: the state machine must trust the declared loading location before anchors exist.
  // # catches: a correct tree that the run never actually consults.
  testWidgets('A: a loading node is an active step with no anchor', (t) async {
    await t.pumpWidget(const MaterialApp(home: _LoadingActivity()));
    final step = GuideStep(id: 'loading', node: GuideNode.activityHistory,
      target: GuideTarget.key(const ValueKey('not-built-yet')),
      anchor: GuideTarget.key(const ValueKey('also-not-built')),
      action: GuideAction.tap, caption: fnText((_) => 'Wait for History'));
    final guide = Guide(id: 'loading', start: GuideStart.activity, title: fnText((_) => 'Loading'),
      variants: [GuideVariant(steps: [step])]);
    final run = GuideRun(guide: guide, variant: guide.variants.single);
    addTearDown(run.dispose);
    run.observe(t.element(find.byType(_LoadingActivity)), lookupAppLocalizations(const Locale('en')));
    expect(run.state, isA<GuideAtStep>());
    expect(run.currentStep, same(step));
  });

}

class _LoadingActivity extends StatelessWidget {
  const _LoadingActivity();
  @override
  Widget build(BuildContext context) => const GuideLocation(
    node: GuideNode.activityHistory, child: SizedBox.expand());
}
