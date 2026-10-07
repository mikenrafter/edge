// The follow-up screen offers Water (RED): one tap on the pill answers the
// moment at once, with no amount field (one tap = one glass, like the old
// "Log water" gesture). The writer is a fake; what the glass adds is
// water_answer_test.dart's job.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Call {
  _Call(this.m, this.choice, this.value, this.note);
  final PendingMoment m;
  final MomentChoice? choice;
  final double? value;
  final String? note;
}

class _FakeWriter extends MomentAnswerWriter {
  final calls = <_Call>[];

  @override
  Future<MomentAnswerResult> answer(PendingMoment m, MomentChoice choice,
      {double? value, String? note, DateTime? now}) async {
    calls.add(_Call(m, choice, value, note));
    return MomentAnswerResult.saved;
  }

  @override
  Future<MomentAnswerResult> skip(PendingMoment m, {DateTime? now}) async {
    calls.add(_Call(m, null, null, null));
    return MomentAnswerResult.saved;
  }
}

const _a = PendingMoment(date: '2026-10-06', hhmm: '09:15');
const _b = PendingMoment(date: '2026-10-07', hhmm: '07:05');
final _now = DateTime(2026, 10, 7, 12, 0);

Finder _row(PendingMoment m) =>
    find.byKey(ValueKey('moment-follow-up:${m.key}'));
Finder _choice(PendingMoment m, MomentChoice c) =>
    find.byKey(ValueKey('moment-choice:${m.key}:${c.id}'));

Future<_FakeWriter> _pump(WidgetTester t, List<PendingMoment> moments) async {
  final w = _FakeWriter();
  t.view.physicalSize = const Size(390 * 3, 4000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: MomentFollowUpScreen(preloaded: moments, writer: w, now: _now),
  ));
  await t.pumpAndSettle();
  return w;
}

void main() {
  testWidgets('every moment offers a Water pill', (t) async {
    await _pump(t, [_a, _b]);
    for (final m in [_a, _b]) {
      expect(_choice(m, MomentChoice.water), findsOneWidget);
      expect(
          find.descendant(
              of: _choice(m, MomentChoice.water), matching: find.text('Water')),
          findsOneWidget);
    }
  });

  testWidgets('one tap answers Water: no amount asked, no value, no note',
      (t) async {
    final w = await _pump(t, [_a, _b]);
    await t.tap(_choice(_a, MomentChoice.water));
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('moment-value:${_a.key}')), findsNothing,
        reason: 'one tap = one glass; no amount prompt');
    expect(w.calls, hasLength(1));
    expect(w.calls.single.m.key, _a.key);
    expect(w.calls.single.choice, MomentChoice.water);
    expect(w.calls.single.value, isNull);
    expect(w.calls.single.note, isNull);
    expect(_row(_a), findsNothing);
    expect(_row(_b), findsOneWidget);
  });

  testWidgets('no Save button is needed for Water', (t) async {
    await _pump(t, [_a]);
    await t.tap(_choice(_a, MomentChoice.water));
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('moment-save:${_a.key}')), findsNothing);
  });

  testWidgets('Caffeine still asks for an amount (Water did not change it)',
      (t) async {
    final w = await _pump(t, [_a]);
    await t.tap(_choice(_a, MomentChoice.caffeine));
    await t.pumpAndSettle();
    expect(w.calls, isEmpty);
    expect(find.byKey(ValueKey('moment-value:${_a.key}')), findsOneWidget);
  });
}
