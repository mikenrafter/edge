// Pilot day-timeline, spec §4 through the real screen and a real database
// (the APK2 review rig): Keep / Discard staged until Save, Cancel applies
// nothing, Discard -> Restore round trip, staged decisions survive a new
// detection, the draft comes back with "N unsaved changes", the list and the
// scrub line follow each other, and the review emphasis.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/ui2/day_timeline/activities_timeline.dart';
import 'package:openstrap_edge/ui2/day_timeline/pilot_flags.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_chart.dart';
import 'package:openstrap_edge/ui2/screens/day_review.dart';

import '../support/apk2_review_harness.dart';
import '../support/as_of_recalc_fakes.dart' show settle;

void main() {
  setUp(() {
    DayTimelinePilot.debugOverride[DayTimelinePilot.activities] = true;
    DayReviewController.debugClearDrafts();
  });
  tearDown(() {
    DayTimelinePilot.debugOverride.clear();
    DayReviewController.debugClearDrafts();
  });

  ActivitiesTimelineState body(WidgetTester t) =>
      t.state<ActivitiesTimelineState>(find.byType(ActivitiesTimeline));
  String unsaved(WidgetTester t) =>
      t.widget<Text>(find.byKey(ActivitiesSaveBar.countKey)).data!;

  testWidgets('Keep and Discard are staged until Save; Save writes them', (t) async {
    final rig = await Apk2Rig.create(t);
    await rig.mount(t, size: const Size(412, 1000));
    expect(find.byType(ActivitiesTimeline), findsOneWidget);
    final before = await rig.snapshot(t);
    await apk2Tap(t, apk2Keep(apk2NapA));
    await apk2Tap(t, apk2Discard(apk2WorkoutA));
    await t.pump();
    expect(unsaved(t), '2 unsaved changes');
    expect((await rig.snapshot(t))['activity_suggestions'], before['activity_suggestions'],
        reason: 'staged, not written');
    await apk2Tap(t, find.byKey(ActivitiesSaveBar.saveKey));
    await settle(t);
    expect(await rig.status(t, apk2NapA), ActivityReviewStatus.confirmed);
    expect(await rig.status(t, apk2WorkoutA), ActivityReviewStatus.discarded);
    expect(unsaved(t), 'No changes');
  });

  testWidgets('Cancel explains itself and writes nothing', (t) async {
    final rig = await Apk2Rig.create(t);
    await rig.mount(t, size: const Size(412, 1000));
    final before = await rig.snapshot(t);
    await apk2Tap(t, apk2Discard(apk2NapA));
    await apk2Tap(t, apk2Keep(apk2WorkoutB));
    await apk2Tap(t, find.byKey(ActivitiesSaveBar.cancelKey));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('activities-cancel-dialog')), findsOneWidget);
    expect(find.textContaining('Nothing is deleted'), findsOneWidget);
    await apk2Tap(t, find.byKey(const ValueKey('activities-cancel-confirm')));
    await settle(t);
    expect(unsaved(t), 'No changes');
    expect(await rig.snapshot(t), before);
  });

  testWidgets('a discarded item is never deleted, and Restore brings it back', (t) async {
    final rig = await Apk2Rig.create(t);
    await rig.mount(t, size: const Size(412, 1000));
    await apk2Tap(t, apk2Discard(apk2NapB));
    await apk2Tap(t, find.byKey(ActivitiesSaveBar.saveKey));
    await settle(t);
    expect(await rig.status(t, apk2NapB), ActivityReviewStatus.discarded);
    // Hidden by default; "Only discarded" shows it with Restore.
    const restoreId = 'discarded:activity:apk2-nap-b';
    expect(find.byKey(ActivitiesTimeline.restoreKey(restoreId)), findsNothing);
    await apk2Tap(t,find.byKey(ActivitiesTimeline.filterButtonKey));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('activity-kind:discarded')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('activity-kind:pending')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('activity-kind:saved')));
    await t.pumpAndSettle();
    Navigator.of(t.element(find.text('Show activities'))).pop();
    await t.pumpAndSettle();
    expect(find.byKey(ActivitiesTimeline.restoreKey(restoreId)), findsOneWidget);
    await apk2Tap(t, find.byKey(ActivitiesTimeline.restoreKey(restoreId)));
    await t.pump();
    expect(unsaved(t), '1 unsaved change');
    expect(await rig.status(t, apk2NapB), ActivityReviewStatus.discarded, reason: 'staged');
    await apk2Tap(t, find.byKey(ActivitiesSaveBar.saveKey));
    await settle(t);
    expect(await rig.status(t, apk2NapB), ActivityReviewStatus.pending);
    await apk2Tap(t,find.byKey(ActivitiesTimeline.filterButtonKey));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('activity-kind:pending')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('activity-kind:saved')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('activity-kind:discarded')));
    await t.pumpAndSettle();
    Navigator.of(t.element(find.text('Show activities'))).pop();
    await settle(t);
    expect(apk2Keep(apk2NapB), findsOneWidget, reason: 'back for review');
  });

  testWidgets('staged decisions survive a new detection arriving', (t) async {
    final rig = await Apk2Rig.create(t);
    await rig.mount(t, size: const Size(412, 1000));
    await apk2Tap(t, apk2Keep(apk2NapA));
    await apk2Tap(t, apk2Discard(apk2WorkoutB));
    final review = body(t).widget.review!;
    // A sync adds a new detection on the same day.
    await t.runAsync(() => rig.store.reconcile(ActivityKind.workout, [
          {'id': 'apk2-workout-c', 'start_ts': apk2At(20), 'end_ts': apk2At(20, 45),
            'sport': 'cycling'},
        ]));
    await t.runAsync(review.load);
    await settle(t);
    expect(review.needsReview('activity:apk2-workout-c'), isTrue);
    expect(review.choice('activity:apk2-workout-c'), isNull);
    expect(review.choice(apk2NapA), isTrue);
    expect(review.choice(apk2WorkoutB), isFalse);
    expect(unsaved(t), '2 unsaved changes');
  });

  testWidgets('leaving keeps the draft: "N unsaved changes" on return, no prompt', (t) async {
    final rig = await Apk2Rig.create(t);
    await rig.mount(t, size: const Size(412, 1000));
    final before = await rig.snapshot(t);
    await apk2Tap(t, apk2Keep(apk2NapA));
    await apk2Tap(t, apk2Discard(apk2WorkoutA));
    await rig.navigator.currentState!.maybePop();
    await settle(t);
    expect(find.byType(ActivitiesTimeline), findsNothing, reason: 'no exit prompt');
    expect(await rig.snapshot(t), before, reason: 'a draft, not a save');
    await apk2Tap(t, find.text('Open breakdown'));
    await settle(t);
    expect(unsaved(t), '2 unsaved changes');
    expect(body(t).widget.review!.choice(apk2WorkoutA), isFalse);
  });

  testWidgets('scrubbing scrolls the list to the nearest item; tapping an item glides the line',
      (t) async {
    final rig = await Apk2Rig.create(t);
    await rig.mount(t, size: const Size(412, 900));
    final s = body(t);
    final chart = t.getRect(find.byKey(DayTimelineChart.chartKey));
    Offset at(int ts) => Offset(
        chart.left + 44 + s.controller.view.fraction(ts.toDouble()) * (chart.width - 52),
        chart.top + 100);
    // Scrub to 18:40 (the second workout).
    final g = await t.startGesture(at(apk2At(17)));
    await g.moveTo(at(apk2At(18, 5)));
    await t.pump();
    await g.up();
    await settle(t);
    expect(s.focus, apk2WorkoutB);
    final list = t.getRect(find.byKey(ActivitiesTimeline.listKey));
    final item = t.getRect(find.byKey(ActivitiesTimeline.itemKey(apk2WorkoutB)));
    expect(list.overlaps(item), isTrue, reason: 'scrolled into the viewport');

    // Tap the first nap's row: the line glides to it.
    await t.ensureVisible(find.byKey(ActivitiesTimeline.itemKey(apk2NapA)));
    // The row's title line (its middle holds the Keep / Discard buttons).
    await t.tapAt(t.getRect(find.byKey(ActivitiesTimeline.itemKey(apk2NapA))).topLeft +
        const Offset(24, 14));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    final mid = s.controller.scrub!;
    await settle(t);
    expect(s.controller.scrub, apk2At(11));
    expect(mid, isNot(apk2At(11)), reason: 'it glides, it does not jump');
  });

  testWidgets('scrolling the list moves the line', (t) async {
    final rig = await Apk2Rig.create(t);
    await rig.mount(t, size: const Size(412, 760));
    final s = body(t);
    s.controller.setScrub(apk2At(0).toDouble());
    await t.pump();
    final list = find.byKey(ActivitiesTimeline.listKey);
    await t.drag(list, const Offset(0, -400));
    await settle(t);
    expect(s.controller.scrub, isNot(apk2At(0).toDouble()));
    expect(s.focus, isNotNull);
    final focused = s.items.firstWhere((x) => x.id == s.focus);
    expect(s.controller.scrub, focused.moment.at.toDouble());
  });

  testWidgets('review emphasis while items await review, none after', (t) async {
    final rig = await Apk2Rig.create(t);
    await rig.mount(t, size: const Size(412, 1000));
    final s = body(t);
    expect(s.emphasis, containsAll(apk2ActivityIds));
    for (final id in apk2MixedIds) {
      if (find.byKey(ValueKey('apk2-review-keep:$id')).evaluate().isEmpty) continue;
      await apk2Tap(t, apk2Keep(id));
    }
    await t.pump();
    expect(s.emphasis, isNull);
  });
  // WHY: CLAIM(sleep-editor-stable-text). Chart glides must not rebuild the
  // day list's text each frame, restarting row layout and async children.
  testWidgets('zoom animation leaves day list Text widgets and scroll offset unchanged', (t) async {
    final rig = await Apk2Rig.create(t);
    await rig.mount(t, size: const Size(412, 1000));
    final s = body(t);
    final texts = find.descendant(of: find.byKey(ActivitiesTimeline.listKey), matching: find.byType(Text));
    final before = t.widgetList<Text>(texts).toList();
    expect(before, isNotEmpty);
    final offset = s.list.offset;
    s.controller.zoomAt(s.controller.view.center);
    await t.pump();
    await t.pump(const Duration(milliseconds: 350));
    final during = t.widgetList<Text>(texts).toList();
    expect(during.length, before.length);
    for (var i = 0; i < before.length; i++) {
      expect(identical(before[i], during[i]), isTrue,
          reason: 'Day-list text $i rebuilt during a zoom frame');
    }
    expect(s.list.offset, offset);
    await t.pumpAndSettle();
  });

}
