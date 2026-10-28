// Layout shift budget on the screen that edits a SAVED marked-moment answer
// (CLS-1; docs/LAYOUT_SHIFT.md). One state per test, measurement only: they fail
// where the screen really moves. The writer is a fake, so no database is read.
//
// why: the Save button and the chips are what the wearer presses. A form
// opening below the chips, or a refusal appearing, must not move either.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/symptom_description.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../../support/shift_run.dart';

const _caffeine = MomentLabel(
    date: '2026-10-06',
    hhmm: '10:15',
    label: 'caffeine',
    caffeineMg: 80,
    metricValue: 80,
    answeredAtMs: 1);
const _knee = SymptomDescription(
  severity: SymptomSeverity.moderate,
  side: SymptomSide.left,
  kind: SymptomKind.pain,
  area: SymptomArea.knees,
);
const _symptom = MomentLabel(
    date: '2026-10-06', hhmm: '13:00', label: 'symptom', answeredAtMs: 1);

class _Writer extends MomentAnswerWriter {
  const _Writer(this.result);
  final MomentAnswerChange result;
  @override
  Future<MomentAnswerChange> change(MomentLabel saved, MomentChoice choice,
          {double? value,
          String? note,
          SymptomDescription? symptom,
          DateTime? now}) async =>
      result;
}

Finder _chip(MomentLabel m, MomentChoice c) =>
    find.byKey(ValueKey('moment-choice:${m.date} ${m.hhmm}:${c.id}'));
final _save = find.byKey(const ValueKey('moment-edit-save'));

Future<ShiftRun> _open(WidgetTester t, MomentLabel saved,
    {StoredSymptom? symptom,
    MomentAnswerChange result = const MomentNotFound()}) async {
  phoneSurface(t);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: MomentAnswerEditScreen(
        saved: saved, symptom: symptom, writer: _Writer(result)),
  ));
  await t.pumpAndSettle();
  return ShiftRun(t);
}

void main() {
  testWidgets('edit open on a caffeine answer', (t) async {
    phoneSurface(t);
    final run = ShiftRun(t);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: MomentAnswerEditScreen(
          saved: _caffeine, writer: _Writer(const MomentNotFound())),
    ));
    run.opened();
    await run.frames();
    run.expectNoErrors('edit open');
  });

  testWidgets('edit: pick another chip (the form changes below the chips)',
      (t) async {
    final run = await _open(t, _caffeine);
    await run.tap(_chip(_caffeine, MomentChoice.alcohol), shiftOffsets,
        find.byKey(const ValueKey('moment-follow-up:2026-10-06 10:15')));
    await t.pump(const Duration(seconds: 2));
    run.expectNoErrors('edit chip');
  });

  testWidgets('edit: a refusal appears without moving Save or the chips',
      (t) async {
    final run = await _open(t, _caffeine, result: MomentStale(_caffeine));
    await run.tap(_save, shiftOffsets);
    await t.pump(const Duration(seconds: 2));
    expect(find.byKey(const ValueKey('moment-edit-error')), findsOneWidget,
        reason: 'the refusal has to be on screen for this to measure it');
    run.expectNoErrors('edit refusal');
  });

  testWidgets('edit: a symptom answer, pick another severity', (t) async {
    final run = await _open(t, _symptom,
        symptom: StoredSymptom(
            date: _symptom.date, hhmm: _symptom.hhmm, description: _knee));
    await run.tap(
        find.byKey(const ValueKey('symptom-severity:2026-10-06 13:00:severe')),
        shiftOffsets);
    await t.pump(const Duration(seconds: 2));
    run.expectNoErrors('edit symptom severity');
  });
}
