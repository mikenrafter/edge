import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/gestures/moment_review_service.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/apk2_keys.dart';
import 'support/apk2_review_harness.dart';
import 'support/as_of_recalc_fakes.dart' show settle;
import 'support/flutter_errors.dart';
import 'support/moment_review_fakes.dart' show reviewNow;
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

Future<void> _editMarks(WidgetTester t) async {
  await apk2Show(t, apk2MarkA);
  await apk2Tap(t, apk2Key('day-review-label:$apk2MarkA'));
  expect(find.byType(MomentReviewEditor), findsOneWidget);
}

Future<void> _answer(WidgetTester t, String plain, String choice) =>
    apk2Tap(t, apk2Key('moment-choice:$plain:$choice'));

Future<void> _dayArrow(WidgetTester t, String label) => apk2Tap(t,
    find.byWidgetPredicate((w) => w is Pressable && w.semanticLabel == label));

void main() {
  pinProcessTimeZone('America/Denver');

  testWidgets('saved marks stay answered after changing days and returning', (t) async {
    final semantics = t.ensureSemantics();
    final errors = captureFlutterErrors();
    final r = await Apk2Rig.create(t);
    await r.mount(t, marked: true);
    await apk2Show(t, apk2MarkA);
    await apk2Tap(t, apk2Keep(apk2MarkA));
    await apk2Tap(t, apk2Key(apk2Save));
    await _dayArrow(t, 'Next day');
    await _dayArrow(t, 'Previous day');
    expect(apk2Row(apk2MarkA), findsOneWidget);
    await _showRow(t, apk2MarkA);
    expect(apk2Keep(apk2MarkA), findsNothing);
    expect(apk2Discard(apk2MarkA), findsNothing);
    expect(apk2PageIds().contains(apk2MarkA), isFalse);
    final labels = (await t.runAsync(() => LocalDb.momentLabels(date: apk2Day)))!;
    expect(labels.singleWhere((l) => l.hhmm == '09:15').label, 'other');
    expect(errors, isEmpty);
    expect(t.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('editor undo removes the outer batch decision and its label', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    await r.mount(t, marked: true);
    await _editMarks(t);
    await _answer(t, '2026-10-06 09:15', 'meal');
    await _answer(t, '2026-10-06 10:05', 'meal');
    await apk2Tap(t, apk2Key('review-save'));
    await _editMarks(t);
    await apk2Tap(t, apk2Key('moment-undo:2026-10-06 09:15'));
    await apk2Tap(t, apk2Key('review-save'));
    await apk2Show(t, apk2MarkA);
    expect(apk2Selected(t, apk2Keep(apk2MarkA)), isFalse);
    expect(find.descendant(of: apk2Row(apk2MarkA),
        matching: find.text('Meal')), findsNothing);
    await apk2Tap(t, apk2Key(apk2Save));
    final labels = (await t.runAsync(() => LocalDb.momentLabels(date: apk2Day)))!;
    expect(labels.where((l) => l.hhmm == '09:15'), isEmpty);
    expect(labels.singleWhere((l) => l.hhmm == '10:05').label, 'meal');
    semantics.dispose();
  });

  testWidgets('moment editor pairs pending marks across midnight in one batch', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    final service = MomentReviewService();
    addTearDown(service.dispose);
    const late = PendingMoment(date: apk2Day, hhmm: '23:50');
    const early = PendingMoment(date: apk2NewerDay, hhmm: '00:20');
    await t.runAsync(() async {
      await LocalDb.putJournal(apk2Day, '["moment 23:50"]', '');
      await LocalDb.putJournal(apk2NewerDay, '["moment 00:20"]', '');
    });
    await r.mount(t, screen: MomentFollowUpScreen(preloaded: const [late, early],
        preloadedAssumed: const [], service: service, now: reviewNow));
    await apk2Show(t, 'moment:${late.key}');
    await apk2Tap(t, apk2Key('day-review-label:moment:${late.key}'));
    await _answer(t, late.key, 'nap');
    await apk2Tap(t, apk2Key('moment-pair:${late.key}'));
    await apk2Tap(t, apk2Key('moment-pair-target:${late.key}:${early.key}'));
    await apk2Tap(t, apk2Key('review-save'));
    await apk2Show(t, 'moment:${late.key}');
    await apk2Tap(t, apk2Key('day-review-label:moment:${late.key}'));
    await apk2Tap(t, apk2Key('moment-undo:${late.key}'));
    await t.binding.handlePopRoute();
    await settle(t);
    expect(apk2Key(apk2Save), findsNothing);
    await apk2Show(t, 'moment:${late.key}');
    await apk2Tap(t, apk2Key('day-review-label:moment:${late.key}'));
    await _answer(t, late.key, 'nap');
    await apk2Tap(t, apk2Key('moment-pair:${late.key}'));
    await apk2Tap(t, apk2Key('moment-pair-target:${late.key}:${early.key}'));
    await apk2Tap(t, apk2Key('review-save'));
    expect((await r.snapshot(t))['sleep_nap'], isEmpty);
    await apk2Tap(t, apk2Key(apk2Save));
    final after = await r.snapshot(t);
    expect(after['sleep_nap'], hasLength(1));
    expect(after['sleep_nap']!.single['start_ts'], apk2At(23, 50));
    expect(after['sleep_nap']!.single['end_ts'], apk2At(24, 20));
    final labels = (await t.runAsync(() => LocalDb.momentLabels()))!;
    expect(labels.singleWhere((l) => l.key == late.key).label, 'nap');
    expect(labels.singleWhere((l) => l.key == early.key).label, 'nap');
    semantics.dispose();
  });

  testWidgets('back from moment editor hands queued answers to the day batch', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    await r.mount(t, marked: true);
    await _editMarks(t);
    await _answer(t, '2026-10-06 09:15', 'meal');
    await t.binding.handlePopRoute();
    await settle(t);
    expect(find.byType(MomentReviewEditor), findsNothing);
    await apk2Show(t, apk2MarkA);
    expect(apk2Selected(t, apk2Keep(apk2MarkA)), isTrue);
    expect(apk2Enabled(t, apk2Key(apk2Save)), isTrue);
    expect(await r.snapshot(t), before);
    await apk2Tap(t, apk2Key(apk2Save));
    final labels = (await t.runAsync(() => LocalDb.momentLabels(date: apk2Day)))!;
    expect(labels.singleWhere((l) => l.hhmm == '09:15').label, 'meal');
    semantics.dispose();
  });

  testWidgets('undoing every editor answer then Back clears the batch', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    await r.mount(t, marked: true);
    await _editMarks(t);
    await _answer(t, '2026-10-06 09:15', 'meal');
    await apk2Tap(t, apk2Key('review-save'));
    await _editMarks(t);
    await apk2Tap(t, apk2Key('moment-undo:2026-10-06 09:15'));
    await t.binding.handlePopRoute();
    await settle(t);
    await apk2Show(t, apk2MarkA);
    expect(apk2Selected(t, apk2Keep(apk2MarkA)), isFalse);
    expect(apk2Key(apk2Save), findsNothing);
    expect(find.descendant(of: apk2Row(apk2MarkA),
        matching: find.text('Meal')), findsNothing);
    expect(await r.snapshot(t), before);
    semantics.dispose();
  });

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
    expect(apk2PageIds(), apk2ActivityIds);
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
    expect(find.descendant(of: apk2Row(apk2MarkA),
        matching: find.textContaining('09:15')), findsWidgets);
    expect(apk2Keep(apk2MarkA), findsOneWidget);
    expect(apk2Discard(apk2MarkA), findsOneWidget);
    await apk2Show(t, apk2MarkB);
    expect(find.descendant(of: apk2Row(apk2MarkB),
        matching: find.textContaining('10:05')), findsWidgets);
    expect(apk2Keep(apk2MarkB), findsOneWidget);
    expect(apk2Discard(apk2MarkB), findsOneWidget);
  });

  testWidgets('an answered item has no Keep, Discard or reason line, '
      'and the list offers nothing to press on it', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    await r.mount(t);
    await _showRow(t, apk2Answered);
    expect(apk2Keep(apk2Answered), findsNothing);
    expect(apk2Discard(apk2Answered), findsNothing);
    expect(apk2Key('day-review-label:$apk2Answered'), findsNothing);
    expect(find.descendant(of: apk2Row(apk2Answered),
        matching: find.byType(Pressable)), findsNothing);
    expect(find.text('Already reviewed'), findsNothing);
    expect(find.text('No review needed'), findsNothing);
    expect(apk2Key(apk2Save), findsNothing);
    expect(await r.snapshot(t), before);
    // Disposed in the body: the binding checks handles before teardowns run.
    semantics.dispose();
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
    expect(find.descendant(of: apk2Row(apk2MarkA),
        matching: find.textContaining('Other')), findsWidgets);
    expect(find.descendant(of: apk2Row(apk2MarkA),
        matching: find.textContaining('09:15')), findsWidgets);
    expect(find.descendant(of: apk2Row(apk2MarkA),
        matching: find.textContaining('Felt dizzy while standing up.')), findsOneWidget);
    expect(await r.snapshot(t), before);
  });
}
