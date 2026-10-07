// The follow-up screen: each pending moment with its local time and day label
// and quick choices (Pills & meds, Nap, Caffeine, Alcohol, Meal, Workout,
// Symptom, Other with an optional note), plus Skip. What each choice writes is
// the writer's job (answer_writer_test.dart); here the writer is a fake and the
// assertions are about what the screen asks of it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/ui2/screens/log_workout.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Call {
  _Call(this.m, this.choice, this.value, this.note);
  final PendingMoment m;
  final MomentChoice? choice; // null = skip
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
Finder _skip(PendingMoment m) => find.byKey(ValueKey('moment-skip:${m.key}'));

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
  group('listing', () {
    testWidgets('every pending moment, with its local time and day label',
        (t) async {
      await _pump(t, [_a, _b]);
      expect(_row(_a), findsOneWidget);
      expect(_row(_b), findsOneWidget);
      expect(find.descendant(of: _row(_a), matching: find.textContaining('09:15')),
          findsOneWidget);
      expect(
          find.descendant(
              of: _row(_a), matching: find.textContaining('2026-10-06')),
          findsOneWidget);
      expect(find.descendant(of: _row(_b), matching: find.textContaining('07:05')),
          findsOneWidget);
    });

    testWidgets('each moment offers all eight choices and Skip', (t) async {
      await _pump(t, [_a]);
      for (final c in MomentChoice.values) {
        expect(_choice(_a, c), findsOneWidget, reason: c.id);
        expect(
            find.descendant(of: _choice(_a, c), matching: find.text(c.label)),
            findsOneWidget);
      }
      expect(find.text('Pills & meds'), findsOneWidget);
      expect(_skip(_a), findsOneWidget);
    });

    testWidgets('nothing pending: no rows, an honest empty state', (t) async {
      await _pump(t, const []);
      expect(find.byKey(const ValueKey('moment-follow-up-empty')),
          findsOneWidget);
    });
  });

  group('answering', () {
    testWidgets('a plain choice writes that choice and clears the row',
        (t) async {
      final w = await _pump(t, [_a, _b]);
      await t.tap(_choice(_a, MomentChoice.nap));
      await t.pumpAndSettle();
      expect(w.calls, hasLength(1));
      expect(w.calls.single.m.key, _a.key);
      expect(w.calls.single.choice, MomentChoice.nap);
      expect(w.calls.single.value, isNull);
      expect(_row(_a), findsNothing);
      expect(_row(_b), findsOneWidget);
    });

    for (final c in [
      MomentChoice.pillsMeds,
      MomentChoice.meal,
      MomentChoice.symptom,
    ]) {
      testWidgets('${c.label} is one tap, label only', (t) async {
        final w = await _pump(t, [_a]);
        await t.tap(_choice(_a, c));
        await t.pumpAndSettle();
        expect(w.calls.single.choice, c);
        expect(w.calls.single.value, isNull);
        expect(w.calls.single.note, isNull);
      });
    }

    testWidgets('Caffeine asks for the amount inline; blank stores the label '
        'only (never a guess)', (t) async {
      final w = await _pump(t, [_a]);
      await t.tap(_choice(_a, MomentChoice.caffeine));
      await t.pumpAndSettle();
      expect(w.calls, isEmpty, reason: 'it asks first');
      expect(find.byKey(ValueKey('moment-value:${_a.key}')), findsOneWidget);
      await t.tap(find.byKey(ValueKey('moment-save:${_a.key}')));
      await t.pumpAndSettle();
      expect(w.calls.single.choice, MomentChoice.caffeine);
      expect(w.calls.single.value, isNull);
    });

    testWidgets('Caffeine with an amount passes the number through',
        (t) async {
      final w = await _pump(t, [_a]);
      await t.tap(_choice(_a, MomentChoice.caffeine));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(ValueKey('moment-value:${_a.key}')), '95');
      await t.tap(find.byKey(ValueKey('moment-save:${_a.key}')));
      await t.pumpAndSettle();
      expect(w.calls.single.choice, MomentChoice.caffeine);
      expect(w.calls.single.value, 95);
    });

    testWidgets('Alcohol asks for units the same way', (t) async {
      final w = await _pump(t, [_a]);
      await t.tap(_choice(_a, MomentChoice.alcohol));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(ValueKey('moment-value:${_a.key}')), '2');
      await t.tap(find.byKey(ValueKey('moment-save:${_a.key}')));
      await t.pumpAndSettle();
      expect(w.calls.single.choice, MomentChoice.alcohol);
      expect(w.calls.single.value, 2);
    });

    testWidgets('a value that is not a number is not sent', (t) async {
      final w = await _pump(t, [_a]);
      await t.tap(_choice(_a, MomentChoice.caffeine));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(ValueKey('moment-value:${_a.key}')), 'abc');
      await t.tap(find.byKey(ValueKey('moment-save:${_a.key}')));
      await t.pumpAndSettle();
      expect(w.calls.single.value, isNull);
    });

    testWidgets('Other takes an optional free-text note', (t) async {
      final w = await _pump(t, [_a]);
      await t.tap(_choice(_a, MomentChoice.other));
      await t.pumpAndSettle();
      expect(w.calls, isEmpty);
      await t.enterText(
          find.byKey(ValueKey('moment-note:${_a.key}')), 'felt dizzy');
      await t.tap(find.byKey(ValueKey('moment-save:${_a.key}')));
      await t.pumpAndSettle();
      expect(w.calls.single.choice, MomentChoice.other);
      expect(w.calls.single.note, 'felt dizzy');
    });

    testWidgets('Other with the note left empty still answers', (t) async {
      final w = await _pump(t, [_a]);
      await t.tap(_choice(_a, MomentChoice.other));
      await t.pumpAndSettle();
      await t.tap(find.byKey(ValueKey('moment-save:${_a.key}')));
      await t.pumpAndSettle();
      expect(w.calls.single.choice, MomentChoice.other);
      expect(w.calls.single.note, isNull);
    });
  });

  group('Skip', () {
    testWidgets('marks it answered with no label and clears the row',
        (t) async {
      final w = await _pump(t, [_a, _b]);
      await t.tap(_skip(_b));
      await t.pumpAndSettle();
      expect(w.calls, hasLength(1));
      expect(w.calls.single.m.key, _b.key);
      expect(w.calls.single.choice, isNull);
      expect(_row(_b), findsNothing);
      expect(_row(_a), findsOneWidget);
    });
  });

  group('Workout', () {
    testWidgets('offers "Log a workout at this time", prefilled with the '
        "moment's time", (t) async {
      final w = await _pump(t, [_a]);
      await t.tap(_choice(_a, MomentChoice.workout));
      await t.pumpAndSettle();
      expect(w.calls, isEmpty, reason: 'nothing is stored until it is chosen');
      final log = find.byKey(ValueKey('moment-log-workout:${_a.key}'));
      expect(log, findsOneWidget);
      expect(find.text('Log a workout at this time'), findsOneWidget);
      await t.tap(log);
      await t.pumpAndSettle();
      final form = t.widget<LogWorkout>(find.byType(LogWorkout));
      expect(form.start, DateTime(2026, 10, 6, 9, 15));
      expect(form.end, DateTime(2026, 10, 6, 10, 15));
    });

    testWidgets('"Just label it" stores the label alone', (t) async {
      final w = await _pump(t, [_a]);
      await t.tap(_choice(_a, MomentChoice.workout));
      await t.pumpAndSettle();
      await t.tap(find.byKey(ValueKey('moment-label-only:${_a.key}')));
      await t.pumpAndSettle();
      expect(w.calls.single.choice, MomentChoice.workout);
      expect(w.calls.single.value, isNull);
    });
  });

  group('workoutPrefillFor', () {
    test('starts at the moment, an hour long', () {
      final r = workoutPrefillFor(_a, _now);
      expect(r.start, DateTime(2026, 10, 6, 9, 15));
      expect(r.end, DateTime(2026, 10, 6, 10, 15));
    });

    test('never ends after now', () {
      final r = workoutPrefillFor(_b, _now); // 07:05 + 1 h < 12:00
      expect(r.end, DateTime(2026, 10, 7, 8, 5));
      const recent = PendingMoment(date: '2026-10-07', hhmm: '11:30');
      final c = workoutPrefillFor(recent, _now);
      expect(c.start, DateTime(2026, 10, 7, 11, 30));
      expect(c.end, DateTime(2026, 10, 7, 12, 0));
    });
  });
}
