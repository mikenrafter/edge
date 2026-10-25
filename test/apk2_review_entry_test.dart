import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/gestures/moment_review_service.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';

import 'support/apk2_keys.dart';
import 'support/apk2_review_harness.dart';
import 'support/as_of_recalc_fakes.dart' show settle;
import 'support/pin_tz.dart';

Future<void> _showRow(WidgetTester t, String id) async {
  expect(apk2Key(apk2List), findsOneWidget);
  final scrollable = find.descendant(of: apk2Key(apk2List),
      matching: find.byType(Scrollable));
  expect(scrollable, findsOneWidget);
  await t.scrollUntilVisible(apk2Row(id), 180, scrollable: scrollable);
  expect(apk2Row(id), findsOneWidget);
  await t.ensureVisible(apk2Row(id));
  await t.pump();
}

void main() {
  pinProcessTimeZone('America/Denver');

  testWidgets('Review on the detected activities card opens the pending day '
      'breakdown instead of the old proposal list', (t) async {
    final r = await Apk2Rig.create(t);
    await r.mount(t, entry: const DetectedActivitiesCard(pendingCount: 4));
    // This is the existing production entry, not a test-only navigation button.
    expect(find.text('Review'), findsOneWidget);
    await apk2Tap(t, find.text('Review'));
    await settle(t);
    expect(find.byType(DayTimelineScreen), findsOneWidget);
    expect(t.widget<DayTimelineScreen>(find.byType(DayTimelineScreen)).day,
        apk2Day, reason: 'the newest derived day has no pending items');
    expect(find.byType(DetectedActivitiesScreen), findsNothing);
    expect(find.byType(ActivityProposalCard), findsNothing);
    expect(apk2Key(apk2Chart), findsOneWidget);
    expect(apk2Key(apk2Tray), findsOneWidget);
    expect(apk2PageIds(), hasLength(3));
  });

  testWidgets('Review activities preserves marked-moment labels, wall times '
      'and notes in the same breakdown list', (t) async {
    final r = await Apk2Rig.create(t);
    await r.mount(t, entry: const DetectedActivitiesCard(pendingCount: 4));
    await apk2Tap(t, find.text('Review'));
    await settle(t);
    expect(find.byType(DayTimelineScreen), findsOneWidget);
    await _showRow(t, apk2Meal);
    expect(find.descendant(of: apk2Row(apk2Meal),
        matching: find.text('Meal')), findsOneWidget);
    expect(find.descendant(of: apk2Row(apk2Meal),
        matching: find.textContaining('08:10')), findsWidgets);
    expect(find.descendant(of: apk2Row(apk2Meal),
        matching: find.textContaining('Lunch packed for the trail.')), findsOneWidget);
    await _showRow(t, apk2Answered);
    expect(find.descendant(of: apk2Row(apk2Answered),
        matching: find.text('Other')), findsOneWidget);
    expect(find.descendant(of: apk2Row(apk2Answered),
        matching: find.textContaining('20:45')), findsWidgets);
    expect(find.descendant(of: apk2Row(apk2Answered),
        matching: find.textContaining(apk2AnswerNote)), findsOneWidget);
  });

  testWidgets('the marked-moment entry uses the breakdown and retains both '
      'pending wall times alongside activity detections', (t) async {
    final r = await Apk2Rig.create(t);
    await r.mount(t, marked: true);
    expect(find.byType(DayTimelineScreen), findsOneWidget);
    expect(apk2Key(apk2Chart), findsOneWidget);
    await apk2Show(t, apk2MarkA);
    expect(find.descendant(of: apk2Item(apk2MarkA),
        matching: find.textContaining('09:15')), findsWidgets);
    expect(apk2Keep(apk2MarkA), findsOneWidget);
    expect(apk2Discard(apk2MarkA), findsOneWidget);
    await apk2Show(t, apk2MarkB);
    expect(find.descendant(of: apk2Item(apk2MarkB),
        matching: find.textContaining('10:05')), findsWidgets);
    expect(apk2Keep(apk2MarkB), findsOneWidget);
    expect(apk2Discard(apk2MarkB), findsOneWidget);
  });

  testWidgets('an answered item retains disabled Keep and Discard controls '
      'and speaks its reason exactly once', (t) async {
    final semantics = t.ensureSemantics();
    addTearDown(semantics.dispose);
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    await r.mount(t);
    await _showRow(t, apk2Answered);
    final keep = apk2Key('$apk2RowKeepPrefix$apk2Answered');
    final discard = apk2Key('$apk2RowDiscardPrefix$apk2Answered');
    expect(apk2Enabled(t, keep), isFalse);
    expect(apk2Enabled(t, discard), isFalse);
    expect(apk2Key('$apk2DisabledReasonPrefix$apk2Answered'), findsOneWidget);
    // The phrase must not be attached separately to BOTH disabled actions.
    expect(find.descendant(of: apk2Row(apk2Answered),
        matching: find.text('Already reviewed')), findsOneWidget);
    expect(apk2SpokenCount(t, 'Already reviewed'), 1);
    await apk2Tap(t, keep);
    await apk2Tap(t, discard);
    expect(apk2Enabled(t, apk2Key(apk2Save)), isFalse);
    expect(await r.snapshot(t), before);
  });

  testWidgets('a marked-moment draft keeps its label, time and typed note '
      'when opened in the day breakdown, without answering it early', (t) async {
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    final service = MomentReviewService();
    addTearDown(service.dispose);
    await service.edit((q) => q.withDecision(
      ReviewKey.moment(const PendingMoment(date: apk2Day, hhmm: '09:15')),
      const ReviewDecision.label(MomentChoice.other,
          note: 'Felt dizzy while standing up.'),
    ));
    await r.mount(t, marked: true, service: service);
    expect(find.byType(DayTimelineScreen), findsOneWidget);
    await apk2Show(t, apk2MarkA);
    expect(find.descendant(of: apk2Item(apk2MarkA),
        matching: find.textContaining('Other')), findsWidgets);
    expect(find.descendant(of: apk2Item(apk2MarkA),
        matching: find.textContaining('09:15')), findsWidgets);
    expect(find.descendant(of: apk2Item(apk2MarkA),
        matching: find.textContaining('Felt dizzy while standing up.')), findsOneWidget);
    expect(await r.snapshot(t), before);
  });
}
