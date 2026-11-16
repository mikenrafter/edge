// why: permanent regressions for PILOT review R1 S1–S5.
// catches: stored-block bypass, lost drafts, immediate edits, stale readouts, invented stages.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_review.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:openstrap_edge/ui2/day_timeline/activities_timeline.dart';
import 'package:openstrap_edge/ui2/day_timeline/pilot_flags.dart';
import 'package:openstrap_edge/ui2/day_timeline/preview_stager.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_model.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_timeline_editor.dart';
import 'package:openstrap_edge/ui2/screens/day_review.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:openstrap_edge/ui2/charts.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_chart.dart';

import 'support/apk2_review_harness.dart';
import 'support/as_of_recalc_fakes.dart' show settle;
import 'support/day_timeline_fixtures.dart';

class NoSave implements SleepEditSaver {
  @override
  ({Future<void> written, Future<SleepOperationResult> done}) save(
    SleepEditPlan p,
  ) => (
    written: Future.value(),
    done: Future.value(const SleepOperationResult(success: true)),
  );
}

void main() {
  setUp(() {
    DayTimelinePilot.debugOverride[DayTimelinePilot.activities] = true;
    DayReviewController.debugClearDrafts();
  });
  tearDown(() {
    DayTimelinePilot.debugOverride.clear();
    DayReviewController.debugClearDrafts();
  });
  test('R1 missing signals must not fabricate preview stages', () {
    final stages = previewStages(
      domainStart: 0,
      hr: List.filled(60, null),
      movement: List.filled(60, null),
      blocks: [const SleepBlock('main', BlockKind.main, 0, 3600)],
    );
    expect(stages, everyElement(isNull));
  });
  // why: R1 S5. Gaps have no stage and cannot support whole-block totals.
  // catches: clock-based staging in an epoch with no measured signals.
  test('R1 partial gaps stay unknown and totals abstain', () {
    const block = SleepBlock('main', BlockKind.main, 0, 1800);
    final stages = previewStages(
      domainStart: 0,
      hr: [for (var i = 0; i < 30; i++) i < 5 || i >= 20 ? 55.0 : null],
      movement: [for (var i = 0; i < 30; i++) i < 5 ? .9 : null],
      blocks: [block],
    );
    expect(stages, [
      SleepStage.awake,
      null,
      null,
      null,
      SleepStage.deep,
      SleepStage.deep,
    ]);
    final totals = previewTotals(stages, 0, block);
    expect([
      totals.cycles,
      totals.deepMin,
      totals.remMin,
      totals.lightMin,
      totals.wakeUps,
    ], everyElement(isNull));
    // Positive control: fully measured intervals still report measured totals.
    final full = previewTotals(
      [
        SleepStage.light,
        SleepStage.deep,
        SleepStage.rem,
        SleepStage.awake,
        SleepStage.awake,
        SleepStage.light,
      ],
      0,
      block,
    );
    expect(
      [full.deepMin, full.remMin, full.lightMin, full.wakeUps],
      [5, 5, 10, 1],
    );
  });

  testWidgets(
    'R1 an empty night shows unknown totals and no claimed signal match',
    (t) async {
      t.view.physicalSize = const Size(412, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final d = dtNight();
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: SleepTimelineEditor(
            data: SleepEditorData(
              day: d.day,
              domainStart: d.domainStart,
              hr: List.filled(1440, null),
              movement: List.filled(1440, null),
              main: d.main,
            ),
            save: NoSave(),
          ),
        ),
      );
      final p = find.byKey(SleepTimelineEditor.readoutKey);
      expect(
        find.descendant(of: p, matching: find.text('—')),
        findsNWidgets(5),
      );
      expect(find.text('Both ends line up with your signals'), findsNothing);
      expect(
        find.text('No movement recorded to suggest times'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'R1 stored unchanged nap must prevent an overlapping main-window save',
    (t) async {
      final r = await Apk2Rig.create(t);
      await t.runAsync(() async {
        await LocalDb.putNapEdit(
          dayId: apk2Day,
          startTs: apk2At(14),
          endTs: apk2At(14, 30),
          source: 'manual',
        );
        await expectLater(
          writeSleepEdit(
            r.db,
            SleepEditPlan(day: apk2Day, window: (apk2At(0), apk2At(15))),
          ),
          throwsA(isA<SleepEditInvalid>()),
        );
      });
    },
  );
  testWidgets('R1 sleep readout must follow subsequent scrub updates', (
    t,
  ) async {
    ClockFormatController.seed(ClockFormat.h24);
    t.view.physicalSize = const Size(412, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final night = dtNight();
    final hr = List<double?>.filled(1440, 55)..[420] = 63;
    final movement = List<double?>.filled(1440, .05);
    for (var i = 300; i < 305; i++) {
      movement[i] = .9;
    }
    final known = SleepEditorData(
      day: night.day,
      domainStart: night.domainStart,
      hr: hr,
      movement: movement,
      main: night.main,
      naps: night.naps,
    );
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: SleepTimelineEditor(
          data: known,
          save: NoSave(),
          initialScrub: dtAt(300).toDouble(),
        ),
      ),
    );
    final s = t.state<SleepTimelineEditorState>(
      find.byType(SleepTimelineEditor),
    );
    final p = find.byKey(SleepTimelineEditor.readoutKey);
    expect(
      find.descendant(of: p, matching: find.text('SELECTED · 01:00')),
      findsOneWidget,
    );
    final chart = t.getRect(find.byKey(DayTimelineChart.chartKey));
    Offset at(int m) => Offset(
      chart.left +
          44 +
          s.controller.view.fraction(dtAt(m).toDouble()) * (chart.width - 52),
      chart.top + 100,
    );
    for (final minute in [300, 420]) {
      final drag = await t.startGesture(at(minute + 100));
      await drag.moveTo(at(minute));
      await t.pump();
      await drag.up();
      await t.pump();
      expect(
        find.descendant(
          of: p,
          matching: find.text(
            minute == 300 ? 'SELECTED · 01:00' : 'SELECTED · 03:00',
          ),
        ),
        findsOneWidget,
      );
    }
    final d = known;
    expect(
      find.descendant(of: p, matching: find.text('${d.hr[420]!.round()} bpm')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: p,
        matching: find.text('${(d.movement[420]! * 100).round()}%'),
      ),
      findsOneWidget,
    );
    expect(find.descendant(of: p, matching: find.text('REM')), findsOneWidget);
    s.controller.zoomAt(dtAt(420).toDouble());
    await t.pump();
    await t.pump(const Duration(seconds: 2));
    expect(find.byKey(SleepTimelineEditor.resetKey), findsOneWidget);
  });
  testWidgets(
    'R1 marked-moment draft must retain its edited label on return and Save',
    (t) async {
      final r = await Apk2Rig.create(t);
      await r.mount(t, marked: true, size: const Size(412, 1000));
      await apk2Tap(t, apk2Key('day-review-label:$apk2MarkA'));
      await apk2Tap(t, apk2Key('moment-choice:2026-10-06 09:15:meal'));
      await apk2Tap(t, apk2Key('review-save'));
      expect(find.byType(ActivitiesTimeline), findsOneWidget);
      await r.navigator.currentState!.maybePop();
      await settle(t);
      await apk2Tap(t, find.text('Open breakdown'));
      await settle(t);
      expect(
        t.widget<Text>(find.byKey(ActivitiesSaveBar.countKey)).data,
        '1 unsaved change',
      );
      await apk2Tap(t, find.byKey(ActivitiesSaveBar.saveKey));
      await settle(t);
      final labels = (await t.runAsync(
        () => LocalDb.momentLabels(date: apk2Day),
      ))!;
      expect(labels.singleWhere((x) => x.hhmm == '09:15').label, 'meal');
    },
  );
  testWidgets(
    'R1 edits to a saved row must stay staged and Cancel must preserve the original',
    (t) async {
      final r = await Apk2Rig.create(t);
      await r.mount(t, size: const Size(412, 1000));
      final before = await r.snapshot(t);
      await apk2Tap(t, apk2Keep(apk2NapA));
      await apk2Tap(t, apk2Key('day-row-edit:moment:2026-10-06 20:45'));
      await t.enterText(
        apk2Key('moment-note:2026-10-06 20:45'),
        'Changed but not saved in Activities',
      );
      await apk2Tap(t, apk2Key('moment-edit-save'));
      await settle(t);
      final labels = (await t.runAsync(
        () => LocalDb.momentLabels(date: apk2Day),
      ))!;
      expect(
        labels.singleWhere((x) => x.hhmm == '20:45').note,
        apk2AnswerNote,
        reason: 'the outer Activities Save has not been pressed',
      );
      expect(await r.snapshot(t), before);
      await apk2Tap(t, find.byKey(ActivitiesSaveBar.cancelKey));
      await apk2Tap(t, apk2Key('activities-cancel-confirm'));
      expect(await r.snapshot(t), before);
      expect(
        (await t.runAsync(
          () => LocalDb.momentLabels(date: apk2Day),
        ))!.singleWhere((x) => x.hhmm == '20:45').note,
        apk2AnswerNote,
      );
      await apk2Tap(t, apk2Key('day-row-edit:moment:2026-10-06 20:45'));
      await t.enterText(
        apk2Key('moment-note:2026-10-06 20:45'),
        'Saved by Activities',
      );
      await apk2Tap(t, apk2Key('moment-edit-save'));
      expect(
        t.widget<Text>(find.byKey(ActivitiesSaveBar.countKey)).data,
        '1 unsaved change',
      );
      await apk2Tap(t, find.byKey(ActivitiesSaveBar.saveKey));
      expect(
        (await t.runAsync(
          () => LocalDb.momentLabels(date: apk2Day),
        ))!.singleWhere((x) => x.hhmm == '20:45').note,
        'Saved by Activities',
      );
    },
  );
  Future<void> returnToDay(WidgetTester t, Apk2Rig r) async {
    await r.navigator.currentState!.maybePop();
    await settle(t);
    await apk2Tap(t, find.text('Open breakdown'));
    await settle(t);
  }

  for (final kind in ['other', 'caffeine', 'symptom']) {
    // why: R1 S2. A retained Keep boolean must retain the actual answer too.
    testWidgets(
      'R1 $kind draft retains final database values after returning',
      (t) async {
        final r = await Apk2Rig.create(t);
        await r.mount(t, marked: true, size: const Size(412, 1000));
        await apk2Tap(t, apk2Key('day-review-label:$apk2MarkA'));
        const key = '2026-10-06 09:15';
        await apk2Tap(t, apk2Key('moment-choice:$key:$kind'));
        if (kind == 'other') {
          await t.enterText(
            apk2Key('moment-note:$key'),
            'Felt better after lunch',
          );
        }
        if (kind == 'caffeine') {
          await t.enterText(apk2Key('moment-value:$key'), '85');
        }
        if (kind == 'symptom') {
          for (final suffix in [
            'severity:$key:moderate',
            'kind:$key:pain',
            'area:$key:knees',
          ]) {
            await apk2Tap(t, apk2Key('symptom-$suffix'));
          }
        }
        await apk2Tap(t, apk2Key('moment-save:$key'));
        await apk2Tap(t, apk2Key('review-save'));
        final before = await r.snapshot(t);
        await returnToDay(t, r);
        expect(await r.snapshot(t), before);
        await apk2Tap(t, find.byKey(ActivitiesSaveBar.saveKey));
        final saved = (await t.runAsync(
          () => LocalDb.momentLabels(date: apk2Day),
        ))!.singleWhere((m) => m.hhmm == '09:15');
        expect(saved.label, kind);
        if (kind == 'other') expect(saved.note, 'Felt better after lunch');
        if (kind == 'caffeine') {
          expect(saved.caffeineMg, 85);
          expect(saved.metricValue, 85);
          final metric = (await t.runAsync(
            () => r.db.query(
              'journal_metric',
              where: "date = ? AND field = 'caffeine_mg'",
              whereArgs: [apk2Day],
            ),
          ))!;
          expect(metric.single['value'], 85);
        }
        if (kind == 'symptom') {
          final symptoms = (await t.runAsync(
            () => LocalDb.symptomEntries(date: apk2Day),
          ))!;
          expect(symptoms.single.description.toJson(), {
            'severity': 'moderate',
            'kind': 'pain',
            'area': 'knees',
          });
        }
      },
    );
  }

  for (final kind in ['nap', 'workout']) {
    // why: R1 S2. A pair created in the private editor must survive navigation.
    testWidgets('R1 $kind range retains its window after returning and Save', (
      t,
    ) async {
      final r = await Apk2Rig.create(t);
      await r.mount(t, marked: true, size: const Size(412, 1000));
      await apk2Tap(t, apk2Key('day-review-label:$apk2MarkA'));
      const key = '2026-10-06 09:15';
      await apk2Tap(t, apk2Key('moment-choice:$key:$kind'));
      await apk2Tap(t, apk2Key('moment-pair:$key'));
      await apk2Tap(t, apk2Key('moment-pair-target:$key:2026-10-06 10:05'));
      await apk2Tap(t, apk2Key('review-save'));
      final before = await r.snapshot(t);
      await returnToDay(t, r);
      expect(await r.snapshot(t), before);
      await apk2Tap(t, find.byKey(ActivitiesSaveBar.saveKey));
      final rows = (await t.runAsync(
        () => r.db.query(kind == 'nap' ? 'sleep_nap' : 'sessions'),
      ))!;
      expect(rows.single['start_ts'], apk2At(9, 15));
      expect(rows.single['end_ts'], apk2At(10, 5));
      final labels = (await t.runAsync(
        () => LocalDb.momentLabels(date: apk2Day),
      ))!;
      for (final hhmm in ['09:15', '10:05']) {
        expect(labels.singleWhere((m) => m.hhmm == hhmm).label, kind);
      }
    });
  }

  testWidgets(
    'R1 Activities readout follows consecutive scrubs in one nearest region and glide',
    (t) async {
      final r = await Apk2Rig.create(t);
      await r.mount(t, size: const Size(412, 900));
      final s = t.state<ActivitiesTimelineState>(
        find.byType(ActivitiesTimeline),
      );
      for (final minute in [0, 2]) {
        s.controller.setScrub(apk2At(18, minute).toDouble());
        s.scrubbed(apk2At(18, minute).toDouble());
        await t.pump();
        if (minute == 0) {
          expect(find.text('63 bpm'), findsOneWidget);
        }
        expect(
          find.text('SELECTED · 18:${minute.toString().padLeft(2, '0')}'),
          findsOneWidget,
        );
      }
      // Tapping the already focused item drives an animation without changing
      // list focus. The final displayed time must follow that animation.
      final row = find.byKey(ActivitiesTimeline.itemKey(apk2WorkoutB));
      await t.ensureVisible(row);
      await t.tapAt(t.getRect(row).topLeft + const Offset(24, 14));
      await t.pump();
      await t.pump(const Duration(seconds: 2));
      expect(find.text('SELECTED · 18:00'), findsOneWidget);
      s.controller.zoomAt(apk2At(18).toDouble());
      await t.pump();
      await t.pump(const Duration(seconds: 2));
      expect(find.byKey(ActivitiesTimeline.resetKey), findsOneWidget);
      final list = find.byKey(ActivitiesTimeline.listKey);
      await t.drag(list, const Offset(0, 300));
      await settle(t);
      final instant = DateTime.fromMillisecondsSinceEpoch(
        s.controller.scrub!.round() * 1000,
      );
      final clock =
          '${instant.hour.toString().padLeft(2, '0')}:${instant.minute.toString().padLeft(2, '0')}';
      expect(find.text('SELECTED · $clock'), findsOneWidget);
    },
  );

  // Exercise the actual time picker and editor Save, not a synthetic route result.
  Future<void> pickTime(
    WidgetTester t,
    String clock, {
    bool dateFirst = false,
  }) async {
    if (dateFirst) await apk2Tap(t, find.text('OK'));
    await apk2Tap(t, find.byTooltip('Switch to text input mode'));
    final fields = find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.byType(TextField),
    );
    expect(fields, findsNWidgets(2));
    await t.enterText(fields.at(0), clock.split(':')[0]);
    await t.enterText(fields.at(1), clock.split(':')[1]);
    await apk2Tap(t, find.text('OK'));
  }

  for (final kind in ['nap', 'workout']) {
    testWidgets(
      'R1 saved $kind Edit is staged, Cancel preserves snapshot, Save commits',
      (t) async {
        final r = await Apk2Rig.create(t);
        await t.runAsync(() async {
          if (kind == 'nap') {
            await LocalDb.putNapEdit(
              dayId: apk2Day,
              startTs: apk2At(16),
              endTs: apk2At(16, 30),
              source: 'manual',
            );
          } else {
            await LocalDb.putSession({
              'id': 'saved-workout',
              'start_ts': apk2At(16),
              'end_ts': apk2At(16, 30),
              'type': 'walking',
              'status': 'done',
              'created_at': 1,
            });
          }
        });
        r.repo.extraTimeline = kind == 'nap'
            ? {
                'naps': [
                  {
                    'start': apk2At(16),
                    'end': apk2At(16, 30),
                    'duration_min': 30,
                    'source': 'manual',
                  },
                ],
              }
            : {
                'sessions': [
                  {
                    'id': 'saved-workout',
                    'start_ts': apk2At(16),
                    'end_ts': apk2At(16, 30),
                    'type': 'walking',
                    'status': 'done',
                  },
                ],
              };
        await r.mount(t, size: const Size(412, 1000));
        final before = await r.snapshot(t);
        final rowId = kind == 'nap'
            ? 'nap:${apk2At(16)}'
            : 'session:saved-workout';
        Future<void> edit() async {
          await apk2Tap(t, apk2Key('day-row-edit:$rowId'));
          await apk2Tap(t, find.text(kind == 'nap' ? 'End' : 'Ended'));
          await pickTime(t, '16:45', dateFirst: kind == 'nap');
          await apk2Tap(
            t,
            find.text(
              kind == 'nap' ? 'Queue this answer' : 'Save the new times',
            ),
          );
        }

        await edit();
        expect(
          t.widget<Text>(find.byKey(ActivitiesSaveBar.countKey)).data,
          '1 unsaved change',
        );
        expect(await r.snapshot(t), before, reason: 'before outer Save');
        await apk2Tap(t, find.byKey(ActivitiesSaveBar.cancelKey));
        await apk2Tap(t, apk2Key('activities-cancel-confirm'));
        expect(await r.snapshot(t), before, reason: 'after Cancel');
        await edit();
        await returnToDay(t, r);
        expect(await r.snapshot(t), before, reason: 'navigation keeps a draft');
        await apk2Tap(t, find.byKey(ActivitiesSaveBar.saveKey));
        final stored = (await t.runAsync(
          () => r.db.query(kind == 'nap' ? 'sleep_nap' : 'sessions'),
        ))!;
        expect(stored.single['start_ts'], apk2At(16));
        expect(stored.single['end_ts'], apk2At(16, 45));
      },
    );
  }

  testWidgets('R1 flag off retains immediate saved-moment editing', (t) async {
    DayTimelinePilot.debugOverride[DayTimelinePilot.activities] = false;
    final r = await Apk2Rig.create(t);
    await r.mount(t, size: const Size(412, 1000));
    await apk2Tap(t, apk2Key('day-row-edit:$apk2Answered'));
    await t.enterText(
      apk2Key('moment-note:2026-10-06 20:45'),
      'Legacy immediate change',
    );
    await apk2Tap(t, apk2Key('moment-edit-save'));
    final labels = (await t.runAsync(
      () => LocalDb.momentLabels(date: apk2Day),
    ))!;
    expect(
      labels.singleWhere((m) => m.hhmm == '20:45').note,
      'Legacy immediate change',
    );
  });

  testWidgets(
    'R1 marked-moment workout draft retains exact logged window after returning',
    (t) async {
      final r = await Apk2Rig.create(t);
      await r.mount(t, marked: true, size: const Size(412, 1000));
      await apk2Tap(t, apk2Key('day-review-label:$apk2MarkA'));
      const key = '2026-10-06 09:15';
      await apk2Tap(t, apk2Key('moment-choice:$key:workout'));
      await apk2Tap(t, apk2Key('moment-log-workout:$key'));
      await apk2Tap(t, find.text('Ended'));
      await pickTime(t, '10:10');
      await apk2Tap(t, find.text('Log it'));
      await apk2Tap(t, apk2Key('review-save'));
      final before = await r.snapshot(t);
      await returnToDay(t, r);
      expect(await r.snapshot(t), before);
      await apk2Tap(t, find.byKey(ActivitiesSaveBar.saveKey));
      final sessions = (await t.runAsync(() => r.db.query('sessions')))!;
      expect(sessions.single['start_ts'], apk2At(9, 15));
      expect(sessions.single['end_ts'], apk2At(10, 10));
      expect(
        (await t.runAsync(
          () => LocalDb.momentLabels(date: apk2Day),
        ))!.singleWhere((m) => m.hhmm == '09:15').label,
        'workout',
      );
    },
  );

  // why: R1 S3. Saved edits and review decisions must share one commit;
  // a stale answer must leave the whole batch unchanged.
  testWidgets('R1 stale saved edit rolls back a mixed Activities Save', (
    t,
  ) async {
    final r = await Apk2Rig.create(t);
    final saved = (await t.runAsync(
      () => LocalDb.momentLabels(date: apk2Day),
    ))!.singleWhere((m) => m.hhmm == '20:45');
    final valid = (await t.runAsync(
      () => LocalDb.momentLabels(date: apk2Day),
    ))!.singleWhere((m) => m.hhmm == '08:10');
    final proposal = (await t.runAsync(() => r.store.get('apk2-workout-a')))!;
    await t.runAsync(
      () => const MomentAnswerWriter().change(
        saved,
        MomentChoice.other,
        note: 'Changed elsewhere',
      ),
    );
    final before = await r.snapshot(t);
    await t.runAsync(
      () => expectLater(
        r.repo.saveDayReview(
          activities: [ActivityDecision(proposal, keep: false)],
          moments: [],
          savedEdits: SavedReviewEdits(
            moments: [
              SavedMomentEdit(
                valid,
                const ReviewDecision.label(
                  MomentChoice.other,
                  note: 'This earlier write must roll back',
                ),
              ),
              SavedMomentEdit(
                saved,
                const ReviewDecision.label(
                  MomentChoice.other,
                  note: 'Stale draft',
                ),
              ),
            ],
          ),
        ),
        throwsStateError,
      ),
    );
    expect(await r.snapshot(t), before);
    expect(await r.status(t, apk2WorkoutA), ActivityReviewStatus.pending);
  });
  // why: clearing a saved note is an intentional null, not a request to reuse
  // its old value when the stage-only editor opens again (R1 S2/S3).
  testWidgets(
    'R1 clearing a saved note stays cleared when editing the draft again',
    (t) async {
      final r = await Apk2Rig.create(t);
      await r.mount(t, size: const Size(412, 1000));
      final before = await r.snapshot(t);
      await apk2Tap(t, apk2Key('day-row-edit:$apk2Answered'));
      final note = apk2Key('moment-note:2026-10-06 20:45');
      await t.enterText(note, '');
      await apk2Tap(t, apk2Key('moment-edit-save'));
      await apk2Tap(t, apk2Key('day-row-edit:$apk2Answered'));
      final field = t.widget<EditableText>(
        find.descendant(of: note, matching: find.byType(EditableText)),
      );
      expect(field.controller.text, '');
      await apk2Tap(t, apk2Key('moment-edit-save'));
      await returnToDay(t, r);
      expect(await r.snapshot(t), before);
      await apk2Tap(t, find.byKey(ActivitiesSaveBar.saveKey));
      final saved = (await t.runAsync(
        () => LocalDb.momentLabels(date: apk2Day),
      ))!.singleWhere((m) => m.hhmm == '20:45');
      expect(saved.note, isNull);
    },
  );
}
