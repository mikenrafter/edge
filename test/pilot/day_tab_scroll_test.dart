import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/pilot/timeline_policy.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show SubTabs;
import 'package:openstrap_edge/ui2/scroll_quiet.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import '../support/apk2_review_harness.dart';
import '../support/pilot_shots.dart';
import '../support/skeleton_fixture.dart' show skLoadAppFonts;

// Owner m301: "when rapidly scrolling on the day timeline, it will sometimes
// switch tabs. ... we should not be doing that."
void main() {
  setUpAll(skLoadAppFonts);
  PilotTimelineTab shown(WidgetTester t) =>
      PilotTimelineTab.values[t.widget<SubTabs>(find.byType(SubTabs)).index];

  // WHY / CLAIM(day-tab-stays): only a deliberate tap on a tab (or a different
  // day) changes the Pending / Saved / Discarded tab. Scrolling the page,
  // however fast and wherever the finger starts, never does, and never moves
  // the tab strip out from under the next touch.
  // CATCHES: a tab switched or reset by a scroll, a fling ending, a scrub that
  // pins the readout, or a header that changes height while the page scrolls.
  testWidgets('fast scrolling never switches or moves the pilot day timeline tabs', (t) async {
    final rig = await Apk2Rig.create(t);
    await PilotFlags.set(PilotFlag.timelines, true);
    await rig.mount(t, size: const Size(390, 844), screen: const ScrollQuietListener(child: DayTimelineScreen(day: apk2Day)));
    final first = shown(t);
    final strip = t.getRect(find.byType(SubTabs));
    final chart = t.getRect(find.byKey(const ValueKey('pilot-timeline-plot')));
    final page = find.byKey(const ValueKey('pilot-day-list'));
    final rng = Random(301);
    final seen = <String>[], strips = <Rect>[];
    void sample() {
      if (find.byType(SubTabs).evaluate().isEmpty) {
        seen.add('gone');
        return;
      }
      seen.add(shown(t).name);
      strips.add(t.getRect(find.byType(SubTabs)));
    }
    for (var i = 0; i < 60; i++) {
      if (i % 5 == 0) {
        // A hand scrub on the chart pins the readout; the next scroll unpins it.
        final g = await t.startGesture(chart.center);
        await t.pump(const Duration(milliseconds: 400));
        sample();
        await g.up();
        await t.pump(const Duration(milliseconds: 50));
      }
      final list = t.getRect(page);
      // Any start on the page (or anywhere below the chart), any direction,
      // with a thumb's sideways drift. Moves past touch slop are never taps.
      final from = Offset(20 + rng.nextDouble() * 350,
          rng.nextInt(4) == 0 ? strip.top + rng.nextDouble() * 700
              : list.top + rng.nextDouble() * list.height);
      final drift = (rng.nextDouble() - .5) * 140;
      final dy = (rng.nextBool() ? -1 : 1) * (120 + rng.nextDouble() * 500);
      final fling = t.flingFrom(from, Offset(drift, dy), 2500 + rng.nextDouble() * 6000);
      await fling;
      for (var frame = 0; frame < 6; frame++) {
        await t.pump(Duration(milliseconds: 16 + rng.nextInt(90)));
        sample();
      }
    }
    await t.pumpAndSettle();
    sample();
    expect(seen.toSet(), {first.name}, reason: 'tab history $seen');
    expect(strips.toSet(), {strip}, reason: 'the tab strip stayed where it was');
    expect(t.takeException(), null);
  });

  // WHY / CLAIM(day-tab-stays, scroll-tap-quiet) [owner m348]: the touch that
  // stops a fling is not a choice of tab, and neither is a tap 150 ms after the
  // page stopped; a tap 250 ms after it is. CATCHES: dropping every tab tap,
  // none, or the old page-local 450 ms window.
  testWidgets('a tab tap during a fling or 150 ms after it is dropped; at 250 ms it works', (t) async {
    final rig = await Apk2Rig.create(t);
    await PilotFlags.set(PilotFlag.timelines, true);
    await rig.mount(t, size: const Size(390, 844), screen: const ScrollQuietListener(child: DayTimelineScreen(day: apk2Day)));
    final first = shown(t);
    final other = PilotTimelineTab.values.firstWhere((v) => v != first);
    final tab = find.byKey(ValueKey('pilot-tab:${other.name}'));
    final list = t.getRect(find.byKey(const ValueKey('pilot-day-list')));
    await t.flingFrom(list.center, const Offset(0, -260), 4000);
    await t.pump(const Duration(milliseconds: 60));
    await t.tap(tab);
    await t.pump(const Duration(milliseconds: 30));
    expect(shown(t), first, reason: 'the stopping touch is not a tab tap');
    // A second fling, run until the page stops moving (16 ms frames: other
    // animations keep frames coming past the last movement, so "no frame
    // scheduled" is not the end of the scroll), then a tap 150 ms later.
    await t.flingFrom(list.center, const Offset(0, 260), 4000);
    final position = t.state<ScrollableState>(find.descendant(
        of: find.byKey(const ValueKey('pilot-day-list')),
        matching: find.byType(Scrollable))).position;
    for (var i = 0; i < 600 && (i == 0 || position.isScrollingNotifier.value); i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    await t.pump(const Duration(milliseconds: 150));
    await t.tap(tab);
    await t.pump(const Duration(milliseconds: 30));
    expect(shown(t), first, reason: 'within 200 ms of the scroll');
    await t.pump(const Duration(milliseconds: 250));
    await t.tap(tab);
    await t.pumpAndSettle();
    expect(shown(t), other, reason: 'a tap on the settled page switches');
    expect(t.takeException(), null);
  });

  // Review artifact (CLS_SHOTS_DIR set): the pilot Day timeline and its tabs.
  testWidgets('shot: pilot Day timeline tabs', (t) async {
    final rig = await Apk2Rig.create(t);
    await PilotFlags.set(PilotFlag.timelines, true);
    await rig.mount(t, size: const Size(390, 844),
        screen: pilotShot(const DayTimelineScreen(day: apk2Day)));
    await takePilotShot(t, 'day-timeline-tabs');
  });
}
