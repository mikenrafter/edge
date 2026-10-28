// Editing an ANSWERED marked moment from the day breakdown (CLS-1, RED).
//
// Spec: edge.research/wake-pr/cls1-edit-moment.md (item 2). Owner intent
// (2026-10-25): an answered marked moment gets a persistent Edit that reopens
// the answer in the prefilled moment editor; saving changes the answer; the row
// keeps its height when the answer changes.
//
// Contract these tests pin (production keys):
//   * a list row of an answered moment has the key `day-row-edit:moment:<date>
//     <hhmm>` (the same Edit slot saved naps and workouts use) and no Keep or
//     Discard;
//   * it opens a screen keyed `moment-edit-screen` with the SAME chips, amount,
//     note and symptom fields as the review editor (`moment-choice:<k>:<id>`,
//     `moment-value:<k>`, `moment-note:<k>`, `symptom-preview:<k>`), prefilled;
//   * its save button is `moment-edit-save`; a refusal shows in `moment-edit-error`
//     and the screen stays open;
//   * Skip, pairing and "Log a workout" are NOT offered (an edit changes an answer, it
//     does not skip, pair or create a session).
//
// Real database through the APK2 rig, so the writes are the real ones.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/data/nutrition_store.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/symptom_description.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../../support/apk2_review_harness.dart';
import '../../support/as_of_recalc_fakes.dart' show settle;
import '../../support/moment_review_fakes.dart' show reviewNow;
import '../../support/pin_tz.dart';

const _caffeine = PendingMoment(date: apk2Day, hhmm: '11:30');
const _symptom = PendingMoment(date: apk2Day, hhmm: '13:00');
const _legacy = PendingMoment(date: apk2Day, hhmm: '14:00');
final _caffeineId = 'moment:${_caffeine.key}';
const _writer = MomentAnswerWriter();
const _knee = SymptomDescription(
  severity: SymptomSeverity.moderate,
  side: SymptomSide.left,
  kind: SymptomKind.pain,
  area: SymptomArea.knees,
);

String _edit(String id) => 'day-row-edit:$id';
Finder _chip(PendingMoment m, MomentChoice c) =>
    apk2Key('moment-choice:${m.key}:${c.id}');
Finder _field(String key) =>
    find.descendant(of: apk2Key(key), matching: find.byType(EditableText));

/// The chip's colour says whether it is the chosen one (domMind) or not (blue).
Color _chipColor(WidgetTester t, PendingMoment m, MomentChoice c) =>
    t.widget<Pill>(find.descendant(of: _chip(m, c), matching: find.byType(Pill)))
        .color;

Future<void> _seed(WidgetTester t, Future<void> Function() body) async {
  await t.runAsync(body);
}

Future<List<Map<String, Object?>>> _rows(WidgetTester t, String table) async =>
    (await t.runAsync(
        () async => (await LocalDb.instance).query(table, orderBy: 'rowid')))!;

Future<Apk2Rig> _rig(WidgetTester t) async {
  final r = await Apk2Rig.create(t, pending: false);
  await _seed(t, () async {
    await _writer.answer(_caffeine, MomentChoice.caffeine,
        value: 80, now: reviewNow);
    await _writer.answerSymptom(_symptom, _knee, now: reviewNow);
    // As the previous build stored an alcohol answer: no metric_value.
    await (await LocalDb.instance).rawInsert(
        'INSERT INTO moment_label (date, hhmm, label, answered_at) '
        "VALUES ('$apk2Day', '14:00', 'alcohol', 1)");
    await LocalDb.putJournalMetrics(apk2Day, const {
      'caffeine_mg': JournalMetricValue(180, atMinuteOfDay: 690),
      'alcohol_units': JournalMetricValue(3, atMinuteOfDay: 840),
    });
  });
  return r;
}

Future<void> _open(WidgetTester t, String id) async {
  await apk2Show(t, id);
  await apk2Tap(t, apk2Key(_edit(id)));
  expect(apk2Key('moment-edit-screen'), findsOneWidget,
      reason: 'Edit opens the prefilled editor');
}

void main() {
  pinProcessTimeZone('America/Denver');

  group('the row', () {
    testWidgets('every answered moment has a persistent Edit and no Keep or '
        'Discard', (t) async {
      final semantics = t.ensureSemantics();
      final r = await _rig(t);
      await r.mount(t);
      for (final id in [
        _caffeineId,
        'moment:${_symptom.key}',
        apk2Answered,
        apk2Meal,
      ]) {
        await apk2Show(t, id);
        expect(apk2Key(_edit(id)), findsOneWidget, reason: '$id Edit');
        expect(apk2Enabled(t, apk2Key(_edit(id))), isTrue);
        expect(t.getSize(apk2Key(_edit(id))).height, greaterThanOrEqualTo(44));
        expect(apk2Keep(id), findsNothing, reason: 'answered: no Keep');
        expect(apk2Discard(id), findsNothing, reason: 'answered: no Discard');
      }
      semantics.dispose();
    });

    testWidgets('a moment still waiting for its answer has no saved-answer Edit',
        (t) async {
      final r = await Apk2Rig.create(t);
      await r.mount(t, marked: true);
      for (final id in [apk2MarkA, apk2MarkB]) {
        await apk2Show(t, id);
        expect(apk2Key(_edit(id)), findsNothing, reason: id);
        expect(apk2Key('day-review-label:$id'), findsOneWidget, reason: id);
      }
    });
  });

  group('the editor opens on the saved answer', () {
    testWidgets('a dose: the chip is chosen and the amount is filled in',
        (t) async {
      final r = await _rig(t);
      await r.mount(t);
      await _open(t, _caffeineId);
      expect(_chipColor(t, _caffeine, MomentChoice.caffeine), C.domMind);
      expect(_chipColor(t, _caffeine, MomentChoice.alcohol), C.blue);
      expect(t.widget<EditableText>(_field('moment-value:${_caffeine.key}'))
          .controller.text, '80');
    });

    testWidgets('a note answer: the note is filled in', (t) async {
      final r = await _rig(t);
      await r.mount(t);
      await _open(t, apk2Answered);
      const k = '2026-10-06 20:45';
      expect(t.widget<EditableText>(_field('moment-note:$k')).controller.text,
          apk2AnswerNote);
      expect(find.text('2026-10-06 · 20:45'), findsOneWidget,
          reason: 'the editor says which moment it is');
    });

    testWidgets('a symptom: its description is filled in', (t) async {
      final r = await _rig(t);
      await r.mount(t);
      await _open(t, 'moment:${_symptom.key}');
      expect(_chipColor(t, _symptom, MomentChoice.symptom), C.domMind);
      final preview = apk2Key('symptom-preview:${_symptom.key}');
      expect(preview, findsOneWidget);
      expect(t.widget<Text>(find.descendant(of: preview, matching: find.byType(Text)))
          .data, _knee.describe(null));
    });

    testWidgets('it offers no Skip, no pairing and no workout log', (t) async {
      final r = await _rig(t);
      await r.mount(t);
      await _open(t, _caffeineId);
      await apk2Tap(t, _chip(_caffeine, MomentChoice.workout));
      final k = _caffeine.key;
      expect(apk2Key('moment-skip:$k'), findsNothing);
      expect(apk2Key('moment-pair:$k'), findsNothing);
      expect(apk2Key('moment-log-workout:$k'), findsNothing);
      expect(apk2Key('moment-edit-save'), findsOneWidget,
          reason: 'a workout label is just a label here');
    });

    testWidgets('leaving without saving writes nothing', (t) async {
      final r = await _rig(t);
      await r.mount(t);
      final before = await r.snapshot(t);
      await _open(t, _caffeineId);
      await apk2Tap(t, _chip(_caffeine, MomentChoice.alcohol));
      await t.binding.handlePopRoute();
      await settle(t);
      expect(apk2Key('moment-edit-screen'), findsNothing);
      expect(await r.snapshot(t), before);
    });
  });

  group('saving', () {
    testWidgets('a new amount replaces the old one and the row stays the same '
        'height with its Edit still there', (t) async {
      final r = await _rig(t);
      await r.mount(t);
      await apk2Show(t, _caffeineId);
      final height = t.getSize(apk2Row(_caffeineId)).height;

      await _open(t, _caffeineId);
      await t.enterText(_field('moment-value:${_caffeine.key}'), '120');
      await apk2Tap(t, apk2Key('moment-edit-save'));

      expect(apk2Key('moment-edit-screen'), findsNothing);
      final labels = await _rows(t, 'moment_label');
      expect(labels.where((l) => l['hhmm'] == '11:30'), hasLength(1));
      expect(labels.firstWhere((l) => l['hhmm'] == '11:30')['caffeine_mg'], 120);
      // 180 had 80 in it; 100 + 120.
      final metrics = await _rows(t, 'journal_metric');
      expect(metrics.firstWhere((m) => m['field'] == 'caffeine_mg')['value'],
          220);
      await apk2Show(t, _caffeineId);
      expect(apk2Key(_edit(_caffeineId)), findsOneWidget);
      expect(t.getSize(apk2Row(_caffeineId)).height, height,
          reason: 'changing the amount does not move the rows below');
    });

    testWidgets('a different label replaces the title; height unchanged',
        (t) async {
      final r = await _rig(t);
      await r.mount(t);
      await apk2Show(t, _caffeineId);
      final height = t.getSize(apk2Row(_caffeineId)).height;
      expect(find.descendant(of: apk2Row(_caffeineId), matching: find.text('Caffeine')),
          findsOneWidget);

      await _open(t, _caffeineId);
      await apk2Tap(t, _chip(_caffeine, MomentChoice.alcohol));
      await t.enterText(_field('moment-value:${_caffeine.key}'), '2');
      await apk2Tap(t, apk2Key('moment-edit-save'));

      await apk2Show(t, _caffeineId);
      expect(find.descendant(of: apk2Row(_caffeineId), matching: find.text('Alcohol')),
          findsOneWidget);
      expect(find.descendant(of: apk2Row(_caffeineId), matching: find.text('Caffeine')),
          findsNothing);
      expect(t.getSize(apk2Row(_caffeineId)).height, height);
      final metrics = await _rows(t, 'journal_metric');
      expect(metrics.firstWhere((m) => m['field'] == 'caffeine_mg')['value'], 100);
      expect(metrics.firstWhere((m) => m['field'] == 'alcohol_units')['value'], 5,
          reason: '3 from the 14:00 answer + 2');
    });

    testWidgets('a symptom edited to another symptom keeps ONE entry',
        (t) async {
      final r = await _rig(t);
      await r.mount(t);
      await _open(t, 'moment:${_symptom.key}');
      await apk2Tap(t, apk2Key('symptom-severity:${_symptom.key}:severe'));
      await apk2Tap(t, apk2Key('moment-edit-save'));
      final entries = await _rows(t, 'symptom_entry');
      expect(entries.where((e) => e['hhmm'] == '13:00'), hasLength(1));
      expect(entries.single['severity'], 'severe');
      expect(entries.single['area'], 'knees', reason: 'the rest is kept');
    });

    testWidgets('an amount the editor cannot accept stays on the screen with a '
        'reason and writes nothing', (t) async {
      final r = await _rig(t);
      await r.mount(t);
      final before = await r.snapshot(t);
      await _open(t, _caffeineId);
      await t.enterText(_field('moment-value:${_caffeine.key}'), '99999');
      await apk2Tap(t, apk2Key('moment-edit-save'));
      expect(apk2Key('moment-edit-screen'), findsOneWidget);
      expect(apk2Key('moment-amount-error:${_caffeine.key}'), findsOneWidget);
      expect(await r.snapshot(t), before);
    });
  });

  group('review CLS1-R2-1: the joined meal row keeps the height too', () {
    testWidgets('an Other note -> Meal beside a long food entry', (t) async {
      final r = await _rig(t);
      await _seed(t, () async {
        await _writer.answer(const PendingMoment(date: apk2Day, hhmm: '11:45'),
            MomentChoice.other,
            note: 'felt hungry again earlier than usual today', now: reviewNow);
        await NutritionDb.put(
            await LocalDb.instance,
            FoodEntry(
                id: 'long-lunch',
                date: apk2Day,
                meal: 'lunch',
                label: 'Slow cooked chickpea and spinach stew with brown rice '
                    'and a lemon yoghurt dressing',
                atTs: apk2At(11, 45) + 15,
                kcal: 640));
      });
      await r.mount(t, size: const Size(320, 900));
      const id = 'moment:$apk2Day 11:45';
      await apk2Show(t, id);
      final before = t.getSize(apk2Row(id)).height;
      await _open(t, id);
      await apk2Tap(t, apk2Key('moment-choice:$apk2Day 11:45:meal'));
      await apk2Tap(t, apk2Key('moment-edit-save'));
      await apk2Show(t, id);
      expect(find.descendant(of: apk2Row(id), matching: find.textContaining('Slow cooked')),
          findsOneWidget, reason: 'the row is now the joined food row');
      expect(t.getSize(apk2Row(id)).height, before);
    });
  });

  group('review CLS1-C8: a typed amount is never silently dropped', () {
    for (final bad in ['1..2', 'abc', '2 mg']) {
      testWidgets('"$bad" is refused with a reason and writes nothing',
          (t) async {
        final r = await _rig(t);
        await r.mount(t);
        final before = await r.snapshot(t);
        await _open(t, _caffeineId);
        await t.enterText(_field('moment-value:${_caffeine.key}'), bad);
        await apk2Tap(t, apk2Key('moment-edit-save'));
        expect(apk2Key('moment-edit-screen'), findsOneWidget);
        expect(apk2Key('moment-amount-error:${_caffeine.key}'), findsOneWidget);
        expect(await r.snapshot(t), before);
      });
    }
  });

  group('review CLS1-C3: answered rows keep their height', () {
    Future<double> height(WidgetTester t, String id) async {
      await apk2Show(t, id);
      return t.getSize(apk2Row(id)).height;
    }

    testWidgets('an Other note (long) -> Caffeine with no note', (t) async {
      final r = await _rig(t);
      await r.mount(t);
      final before = await height(t, apk2Answered);
      await _open(t, apk2Answered);
      await apk2Tap(t, apk2Key('moment-choice:2026-10-06 20:45:caffeine'));
      await apk2Tap(t, apk2Key('moment-edit-save'));
      expect(await height(t, apk2Answered), before);
    });

    testWidgets('no note -> a long note', (t) async {
      final r = await _rig(t);
      await r.mount(t);
      final before = await height(t, _caffeineId);
      await _open(t, _caffeineId);
      await apk2Tap(t, _chip(_caffeine, MomentChoice.other));
      await t.enterText(_field('moment-note:${_caffeine.key}'), apk2AnswerNote);
      await apk2Tap(t, apk2Key('moment-edit-save'));
      expect(await height(t, _caffeineId), before);
    });

    testWidgets('a long symptom description -> a one-word answer', (t) async {
      final r = await _rig(t);
      await _seed(t, () async {
        await _writer.answerSymptom(
            const PendingMoment(date: apk2Day, hhmm: '16:00'),
            const SymptomDescription(
              severity: SymptomSeverity.moderate,
              side: SymptomSide.both,
              kind: SymptomKind.other,
              kindOther: 'pins and needles that come and go in waves',
              area: SymptomArea.other,
              areaOther: 'the outside of the right lower leg below the knee',
            ),
            now: reviewNow);
      });
      await r.mount(t, size: const Size(320, 900));
      const id = 'moment:$apk2Day 16:00';
      final before = await height(t, id);
      await _open(t, id);
      await apk2Tap(t, apk2Key('moment-choice:$apk2Day 16:00:nap'));
      await apk2Tap(t, apk2Key('moment-edit-save'));
      expect(await height(t, id), before);
    });
  });

  group('when the change is refused', () {
    testWidgets('an answer changed elsewhere meanwhile: it says so, stays open, '
        'and does not overwrite', (t) async {
      final r = await _rig(t);
      await r.mount(t);
      await _open(t, _caffeineId);
      await t.enterText(_field('moment-value:${_caffeine.key}'), '120');
      // Another screen changes the same answer first.
      await _seed(t, () async {
        final saved = (await LocalDb.momentLabels(date: apk2Day))
            .firstWhere((l) => l.key == _caffeine.key);
        await _writer.change(saved, MomentChoice.caffeine,
            value: 30, now: reviewNow.add(const Duration(minutes: 1)));
      });
      final afterOther = await r.snapshot(t);

      await apk2Tap(t, apk2Key('moment-edit-save'));

      expect(apk2Key('moment-edit-screen'), findsOneWidget);
      expect(apk2Key('moment-edit-error'), findsOneWidget);
      expect(find.descendant(of: apk2Key('moment-edit-error'),
          matching: find.textContaining('changed'), matchRoot: true),
          findsOneWidget);
      expect(await r.snapshot(t), afterOther);
    });

    testWidgets('an old dose answer whose amount was never kept says it cannot '
        'be changed safely, and changes nothing', (t) async {
      final r = await _rig(t);
      await r.mount(t);
      final before = await r.snapshot(t);
      await _open(t, 'moment:${_legacy.key}');
      await apk2Tap(t, _chip(_legacy, MomentChoice.other));
      await apk2Tap(t, apk2Key('moment-edit-save'));
      expect(apk2Key('moment-edit-screen'), findsOneWidget);
      expect(find.descendant(of: apk2Key('moment-edit-error'),
          matching: find.textContaining('amount'), matchRoot: true),
          findsOneWidget);
      expect(await r.snapshot(t), before);
    });
  });

  group('the day list builds the Edit from the stored answer', () {
    MomentLabel label(String hhmm, String? l) => MomentLabel(
        date: apk2Day, hhmm: hhmm, label: l, answeredAtMs: 1);
    final dayStart = DateTime(2026, 10, 6).millisecondsSinceEpoch ~/ 1000;

    test('a labelled moment points at its own editor by its key', () {
      final m = dayMoments(timeline: {'day_start': dayStart},
          momentLabels: [label('10:15', 'caffeine')]);
      expect(m.single.editRef, 'moment:2026-10-06 10:15');
    });

    test('C4: a food entry that stands for the meal moment carries the moment '
        'editor, so Edit survives changing an answer to Meal', () {
      final at = DateTime(2026, 10, 6, 8, 10).millisecondsSinceEpoch ~/ 1000;
      final m = dayMoments(timeline: {'day_start': dayStart},
          momentLabels: [label('08:10', 'meal')],
          meals: [FoodEntry(id: 'lunch', date: apk2Day, meal: 'lunch',
              label: 'Rice bowl', atTs: at + 15, kcal: 550)]);
      expect(m, hasLength(1), reason: 'the join is the precondition');
      expect(m.single.identity, 'moment:2026-10-06 08:10');
      expect(m.single.editRef, 'moment:2026-10-06 08:10');
    });
  });
}
