// Layout shift budget on the marked-moment REVIEW screen, one state per test.
// Measurement tests: they fail where the screen really moves.
//
// The screen is built with `preloaded` (the loader reads the real database, so
// the loading placeholder is not measured here). Time is the fake-async clock
// and the injected `now`; every writer is a fake.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_service.dart';
import 'package:openstrap_edge/gestures/moment_review_store.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/moment_review_fakes.dart';
import '../../support/shift_run.dart';

const _m = [
  PendingMoment(date: '2026-10-05', hhmm: '08:10'),
  PendingMoment(date: '2026-10-05', hhmm: '13:30'),
  PendingMoment(date: '2026-10-05', hhmm: '21:45'),
  PendingMoment(date: '2026-10-06', hhmm: '07:20'),
  PendingMoment(date: '2026-10-06', hhmm: '15:05'),
  PendingMoment(date: '2026-10-07', hhmm: '07:05'),
];
final _g = glass('2026-10-06', 10 * 60);

Finder _row(PendingMoment m) => find.byKey(ValueKey('moment-follow-up:${m.key}'));
Finder _choice(PendingMoment m, MomentChoice c) =>
    find.byKey(ValueKey('moment-choice:${m.key}:${c.id}'));
Finder _undo(PendingMoment m) => find.byKey(ValueKey('moment-undo:${m.key}'));
Finder _queueIt(PendingMoment m) => find.byKey(ValueKey('moment-save:${m.key}'));
Finder _note(PendingMoment m) => find.byKey(ValueKey('moment-note:${m.key}'));
Finder _skip(PendingMoment m) => find.byKey(ValueKey('moment-skip:${m.key}'));
final _save = find.byKey(const ValueKey('review-save'));

/// A real tap that is NOT measured (it builds the state under test).
Future<void> _setup(WidgetTester t, Finder f) async {
  await t.tap(f);
  await t.pumpAndSettle();
}

Future<ShiftRun> _open(WidgetTester t) async {
  SharedPreferences.setMockInitialValues({});
  await Prefs.ensureLoaded();
  Prefs.setString(MomentReviewStore.prefKey, '');
  phoneSurface(t);
  final log = WriteLog();
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: MomentFollowUpScreen(
      preloaded: _m,
      preloadedAssumed: [_g],
      writer: FakeAnswerWriter(log: log),
      assumedWriter: FakeGlassWriter(log: log),
      rangeWriter: FakeRangeWriter(log: log),
      service: MomentReviewService(store: const MomentReviewStore()),
      exporter: null,
      now: reviewNow,
    ),
  ));
  await t.pumpAndSettle();
  return ShiftRun(t);
}

void main() {
  testWidgets('review open with 6 moments + 1 assumed glass', (t) async {
    phoneSurface(t);
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    Prefs.setString(MomentReviewStore.prefKey, '');
    final run = ShiftRun(t);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: MomentFollowUpScreen(
        preloaded: _m,
        preloadedAssumed: [_g],
        writer: FakeAnswerWriter(),
        assumedWriter: FakeGlassWriter(),
        rangeWriter: FakeRangeWriter(),
        service: MomentReviewService(store: const MomentReviewStore()),
        now: reviewNow,
      ),
    ));
    run.opened();
    await run.frames();
    run.expectNoErrors('review open');
  });

  testWidgets('review: tap a choice chip on the first row', (t) async {
    final run = await _open(t);
    await run.tap(_choice(_m[0], MomentChoice.meal), shiftOffsets, _row(_m[0]));
    await t.pump(const Duration(seconds: 2));
    run.expectNoErrors('review choice chip, first row');
  });

  testWidgets('review: Undo on the first row', (t) async {
    final run = await _open(t);
    await _setup(t, _choice(_m[0], MomentChoice.meal));
    await run.tap(_undo(_m[0]), shiftOffsets, _row(_m[0]));
    await t.pump(const Duration(seconds: 2));
    run.expectNoErrors('review undo, first row');
  });

  testWidgets('review: a choice that opens the inline form, then queue it',
      (t) async {
    final run = await _open(t);
    await run.tap(_choice(_m[0], MomentChoice.caffeine), shiftOffsets, _row(_m[0]));
    // No typed amount: a queued blank dose is the label alone, and removing a
    // focused field in one frame trips a framework assertion in tests.
    await t.pumpAndSettle();
    await run.tap(_queueIt(_m[0]), shiftOffsets, _row(_m[0]));
    await t.pump(const Duration(seconds: 2));
    run.expectNoErrors('review inline form open + queue');
  });

  testWidgets('review: skip row 1 while row 2 note has focus',
      (t) async {
    final run = await _open(t);
    // Setup (unmeasured): open "Other" on row 2.
    await t.pumpAndSettle();
    await _setup(t, _choice(_m[1], MomentChoice.other));
    await t.tap(_note(_m[1]));
    await t.pumpAndSettle();
    run.snap();
    final field = run.probe.idOf(t, _note(_m[1]));
    expect(field, isNotNull, reason: 'the focused field must be tracked');
    run.probe.focus.add(FocusEvent(run.now, field!));
    await run.tap(_skip(_m[0]), shiftOffsets, _row(_m[0]));
    await t.pump(const Duration(seconds: 2));
    run.expectNoErrors('review skip row 1, focus on row 2 note');
  });

  testWidgets('review: Save removes the answered rows', (t) async {
    final run = await _open(t);
    await _setup(t, _choice(_m[0], MomentChoice.meal));
    await _setup(t, _choice(_m[1], MomentChoice.pillsMeds));
    await run.tap(_save, shiftOffsets);
    await t.pump(const Duration(seconds: 3));
    run.expectNoErrors('review Save');
  });
}
