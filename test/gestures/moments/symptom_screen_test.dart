// The Symptom describer on the follow-up screen (RED).
//
// Tapping Symptom no longer answers the moment at once: it opens a describer in
// the row with severity, side (optional), kind and area presets, free text for
// "other", an optional note, a live preview of the sentence, and Save. Save does
// nothing until severity, kind and area are chosen. The writer is a fake; what
// lands in the database is symptom_answer_test.dart's job.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/symptom_description.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Symptom {
  _Symptom(this.m, this.d);
  final PendingMoment m;
  final SymptomDescription d;
}

class _FakeWriter extends MomentAnswerWriter {
  final symptoms = <_Symptom>[];
  final answers = <MomentChoice>[];
  final skips = <String>[];

  @override
  Future<MomentAnswerResult> answerSymptom(
      PendingMoment m, SymptomDescription d, {DateTime? now}) async {
    symptoms.add(_Symptom(m, d));
    return MomentAnswerResult.saved;
  }

  @override
  Future<MomentAnswerResult> answer(PendingMoment m, MomentChoice choice,
      {double? value, String? note, DateTime? now}) async {
    answers.add(choice);
    return MomentAnswerResult.saved;
  }

  @override
  Future<MomentAnswerResult> skip(PendingMoment m, {DateTime? now}) async {
    skips.add(m.key);
    return MomentAnswerResult.saved;
  }
}

const _a = PendingMoment(date: '2026-10-06', hhmm: '09:15');
const _b = PendingMoment(date: '2026-10-07', hhmm: '07:05');
final _now = DateTime(2026, 10, 7, 12, 0);

Finder _choice(PendingMoment m, MomentChoice c) =>
    find.byKey(ValueKey('moment-choice:${m.key}:${c.id}'));
Finder _describer(PendingMoment m) =>
    find.byKey(ValueKey('symptom-describer:${m.key}'));
Finder _sev(PendingMoment m, SymptomSeverity s) =>
    find.byKey(ValueKey('symptom-severity:${m.key}:${s.name}'));
Finder _side(PendingMoment m, SymptomSide s) =>
    find.byKey(ValueKey('symptom-side:${m.key}:${s.name}'));
Finder _kind(PendingMoment m, SymptomKind k) =>
    find.byKey(ValueKey('symptom-kind:${m.key}:${k.name}'));
Finder _area(PendingMoment m, SymptomArea a) =>
    find.byKey(ValueKey('symptom-area:${m.key}:${a.name}'));
Finder _save(PendingMoment m) => find.byKey(ValueKey('moment-save:${m.key}'));
Finder _preview(PendingMoment m) =>
    find.byKey(ValueKey('symptom-preview:${m.key}'));

Future<_FakeWriter> _pump(WidgetTester t, List<PendingMoment> moments) async {
  final w = _FakeWriter();
  t.view.physicalSize = const Size(390 * 3, 8000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: MomentFollowUpScreen(preloaded: moments, writer: w, now: _now),
  ));
  await t.pumpAndSettle();
  return w;
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

/// Pick the three required parts: moderate, pain, knees.
Future<void> _required(WidgetTester t, PendingMoment m) async {
  await _tap(t, _sev(m, SymptomSeverity.moderate));
  await _tap(t, _kind(m, SymptomKind.pain));
  await _tap(t, _area(m, SymptomArea.knees));
}

/// Reading order (top to bottom, then left to right) of [keys] on screen.
List<T> _readingOrder<T>(
    WidgetTester t, Iterable<T> all, Finder Function(T) finder) {
  final pos = {for (final x in all) x: t.getTopLeft(finder(x))};
  final sorted = all.toList()
    ..sort((p, q) {
      final a = pos[p]!, b = pos[q]!;
      final dy = a.dy.compareTo(b.dy);
      return dy != 0 ? dy : a.dx.compareTo(b.dx);
    });
  return sorted;
}

void main() {
  group('opening it', () {
    testWidgets('tapping Symptom opens the describer and answers NOTHING yet',
        (t) async {
      final w = await _pump(t, [_a, _b]);
      expect(_describer(_a), findsNothing);
      await _tap(t, _choice(_a, MomentChoice.symptom));
      expect(_describer(_a), findsOneWidget);
      expect(_describer(_b), findsNothing, reason: 'only the tapped moment');
      expect(w.symptoms, isEmpty);
      expect(w.answers, isEmpty);
    });

    testWidgets('every preset is offered, in the owner\'s order', (t) async {
      await _pump(t, [_a]);
      await _tap(t, _choice(_a, MomentChoice.symptom));
      for (final s in SymptomSeverity.values) {
        expect(_sev(_a, s), findsOneWidget);
      }
      for (final s in SymptomSide.values) {
        expect(_side(_a, s), findsOneWidget);
      }
      for (final k in SymptomKind.values) {
        expect(_kind(_a, k), findsOneWidget);
      }
      for (final a in SymptomArea.values) {
        expect(_area(_a, a), findsOneWidget);
      }
      expect(_readingOrder(t, SymptomSeverity.values, (s) => _sev(_a, s)),
          SymptomSeverity.values);
      expect(_readingOrder(t, SymptomSide.values, (s) => _side(_a, s)),
          SymptomSide.values);
      expect(_readingOrder(t, SymptomKind.values, (k) => _kind(_a, k)),
          SymptomKind.values);
      expect(_readingOrder(t, SymptomArea.values, (a) => _area(_a, a)),
          SymptomArea.values,
          reason: 'body order, low to high');
    });

    testWidgets('Skip is still there and answers without a symptom',
        (t) async {
      final w = await _pump(t, [_a]);
      await _tap(t, _choice(_a, MomentChoice.symptom));
      await _tap(t, find.byKey(ValueKey('moment-skip:${_a.key}')));
      expect(w.skips, [_a.key]);
      expect(w.symptoms, isEmpty);
    });
  });

  group('Save', () {
    testWidgets('does nothing until severity, kind and area are chosen',
        (t) async {
      final w = await _pump(t, [_a]);
      await _tap(t, _choice(_a, MomentChoice.symptom));
      await _tap(t, _save(_a));
      expect(w.symptoms, isEmpty);

      await _tap(t, _sev(_a, SymptomSeverity.mild));
      await _tap(t, _save(_a));
      expect(w.symptoms, isEmpty);

      await _tap(t, _kind(_a, SymptomKind.pain));
      await _tap(t, _save(_a));
      expect(w.symptoms, isEmpty, reason: 'still no area');

      await _tap(t, _area(_a, SymptomArea.neck));
      await _tap(t, _save(_a));
      expect(w.symptoms, hasLength(1));
    });

    testWidgets('side is optional: saved with none', (t) async {
      final w = await _pump(t, [_a]);
      await _tap(t, _choice(_a, MomentChoice.symptom));
      await _required(t, _a);
      await _tap(t, _save(_a));
      expect(w.symptoms.single.m.key, _a.key);
      final d = w.symptoms.single.d;
      expect(d.severity, SymptomSeverity.moderate);
      expect(d.side, isNull);
      expect(d.kind, SymptomKind.pain);
      expect(d.area, SymptomArea.knees);
      expect(d.kindOther, isNull);
      expect(d.areaOther, isNull);
      expect(d.note, isNull);
    });

    testWidgets('a chosen side is saved; tapping it again clears it',
        (t) async {
      final w = await _pump(t, [_a]);
      await _tap(t, _choice(_a, MomentChoice.symptom));
      await _required(t, _a);
      await _tap(t, _side(_a, SymptomSide.left));
      await _tap(t, _side(_a, SymptomSide.left));
      await _tap(t, _side(_a, SymptomSide.both));
      await _tap(t, _save(_a));
      expect(w.symptoms.single.d.side, SymptomSide.both);
    });

    testWidgets('saving answers the moment: it leaves the list, the other '
        'stays', (t) async {
      await _pump(t, [_a, _b]);
      await _tap(t, _choice(_a, MomentChoice.symptom));
      await _required(t, _a);
      await _tap(t, _save(_a));
      expect(find.byKey(ValueKey('moment-follow-up:${_a.key}')), findsNothing);
      expect(find.byKey(ValueKey('moment-follow-up:${_b.key}')), findsOneWidget);
    });

    testWidgets('the optional note is carried', (t) async {
      final w = await _pump(t, [_a]);
      await _tap(t, _choice(_a, MomentChoice.symptom));
      await _required(t, _a);
      final note = find.byKey(ValueKey('symptom-note:${_a.key}'));
      await t.ensureVisible(note);
      await t.enterText(note, 'after the run');
      await _tap(t, _save(_a));
      expect(w.symptoms.single.d.note, 'after the run');
    });
  });

  group('other:freeform', () {
    testWidgets('kind Other asks for text; Save waits for it', (t) async {
      final w = await _pump(t, [_a]);
      await _tap(t, _choice(_a, MomentChoice.symptom));
      final field = find.byKey(ValueKey('symptom-kind-other:${_a.key}'));
      expect(field, findsNothing, reason: 'only once Other is chosen');
      await _tap(t, _sev(_a, SymptomSeverity.severe));
      await _tap(t, _area(_a, SymptomArea.hands));
      await _tap(t, _kind(_a, SymptomKind.other));
      expect(field, findsOneWidget);
      await _tap(t, _save(_a));
      expect(w.symptoms, isEmpty, reason: 'Other with no text is not a kind');
      await t.ensureVisible(field);
      await t.enterText(field, 'burning');
      await t.pumpAndSettle();
      await _tap(t, _save(_a));
      final d = w.symptoms.single.d;
      expect(d.kind, SymptomKind.other);
      expect(d.kindOther, 'burning');
    });

    testWidgets('area Other asks for text; Save waits for it', (t) async {
      final w = await _pump(t, [_a]);
      await _tap(t, _choice(_a, MomentChoice.symptom));
      await _tap(t, _sev(_a, SymptomSeverity.faint));
      await _tap(t, _kind(_a, SymptomKind.tingling));
      await _tap(t, _area(_a, SymptomArea.other));
      final field = find.byKey(ValueKey('symptom-area-other:${_a.key}'));
      expect(field, findsOneWidget);
      await _tap(t, _save(_a));
      expect(w.symptoms, isEmpty);
      await t.ensureVisible(field);
      await t.enterText(field, 'big toe');
      await t.pumpAndSettle();
      await _tap(t, _save(_a));
      expect(w.symptoms.single.d.areaOther, 'big toe');
    });

    testWidgets('switching away from Other drops the typed text', (t) async {
      final w = await _pump(t, [_a]);
      await _tap(t, _choice(_a, MomentChoice.symptom));
      await _required(t, _a);
      await _tap(t, _kind(_a, SymptomKind.other));
      final field = find.byKey(ValueKey('symptom-kind-other:${_a.key}'));
      await t.enterText(field, 'burning');
      await _tap(t, _kind(_a, SymptomKind.soreness));
      expect(field, findsNothing);
      await _tap(t, _save(_a));
      expect(w.symptoms.single.d.kind, SymptomKind.soreness);
      expect(w.symptoms.single.d.kindOther, isNull);
    });
  });

  group('the preview sentence', () {
    testWidgets('builds as the wearer picks, side omitted when unset',
        (t) async {
      await _pump(t, [_a]);
      await _tap(t, _choice(_a, MomentChoice.symptom));
      await _required(t, _a);
      expect(
          find.descendant(
              of: _preview(_a),
              matching: find.text('moderate pain in my knees')),
          findsOneWidget);
      await _tap(t, _side(_a, SymptomSide.left));
      expect(
          find.descendant(
              of: _preview(_a),
              matching: find.text('moderate pain in my knees (left)')),
          findsOneWidget);
      await _tap(t, _side(_a, SymptomSide.left));
      expect(
          find.descendant(
              of: _preview(_a),
              matching: find.text('moderate pain in my knees')),
          findsOneWidget);
    });

    testWidgets('shows nothing invented before the required parts are chosen',
        (t) async {
      await _pump(t, [_a]);
      await _tap(t, _choice(_a, MomentChoice.symptom));
      await _tap(t, _sev(_a, SymptomSeverity.mild));
      expect(find.textContaining(' in my '), findsNothing);
    });
  });

  group('the other choices are untouched', () {
    testWidgets('Nap still answers at once; Caffeine still asks an amount',
        (t) async {
      final w = await _pump(t, [_a, _b]);
      await _tap(t, _choice(_a, MomentChoice.nap));
      expect(w.answers, [MomentChoice.nap]);
      await _tap(t, _choice(_b, MomentChoice.caffeine));
      expect(find.byKey(ValueKey('moment-value:${_b.key}')), findsOneWidget);
      expect(_describer(_b), findsNothing);
    });
  });
}
