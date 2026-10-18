// Round 4.
//  1  a range's identity travels with the Save that took it: a replacement made
//     meanwhile (same marks, other choice) is never overwritten by the old
//     Save's progress, and the old Save does nothing for it
//  2  consent writes are one at a time; a failure rolls back to the latest
//     CONFIRMED value, with or without a screen

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_apply.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/gestures/moment_review_service.dart';
import 'package:openstrap_edge/gestures/moment_review_store.dart';
import 'package:openstrap_edge/platform/tasker_moment_export.dart';
import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/compute/nap_edits.dart';
import 'package:openstrap_edge/state/acked_bool.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/moment_review_fakes.dart';
import '../../../support/settings_sections.dart';

/// Validation of a nap reads the day's naps: hold that read.
class _GatedNaps extends FakeRangeWriter {
  _GatedNaps({this.then = const []});
  final List<NapMap> then;
  final gate = Completer<void>();
  final started = Completer<void>();
  @override
  Future<List<NapMap>> existingNaps(String dayId) async {
    if (!started.isCompleted) started.complete();
    await gate.future;
    return then;
  }
}

MomentReviewApplier _applier(FakeAnswerWriter w, FakeRangeWriter r,
        {List<Map<String, Object>>? sent}) =>
    MomentReviewApplier(
        writer: w,
        assumedWriter: FakeGlassWriter(),
        ranges: r,
        exporter: TaskerMomentExport(
            connectionOn: () => true,
            emit: (e, x) async {
              sent?.add(x);
              return true;
            }));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    AckedBool.resetForTest();
    Prefs.setString(MomentReviewStore.prefKey, '');
  });

  group('1  range identity', () {
    ReviewRange nap() => MomentReviewQueue.empty
        .withRange(mA, mB, MomentChoice.nap)
        .ranges
        .single;

    test('sameDecision: choice, type, marks and times; never progress', () {
      final r = nap();
      expect(r.sameDecision(r.copyWith(windowWritten: true, attempting: true)),
          isTrue);
      final w = MomentReviewQueue.empty
          .withRange(mA, mB, MomentChoice.workout)
          .ranges
          .single;
      expect(r.sameDecision(w), isFalse);
      final typed = MomentReviewQueue.empty
          .withRange(mA, mB, MomentChoice.workout, workoutType: 'running')
          .ranges
          .single;
      expect(w.sameDecision(typed), isFalse);
      final other = MomentReviewQueue.empty
          .withRange(mA, mC, MomentChoice.nap)
          .ranges
          .single;
      expect(r.sameDecision(other), isFalse);
    });

    test('a replacement made while the old Save validates is NOT overwritten, '
        'and the old Save writes and announces nothing', () async {
      final s = MomentReviewService();
      await s.edit((q) => q.withRange(mA, mB, MomentChoice.nap));
      final ranges = _GatedNaps();
      final w = FakeAnswerWriter();
      final sent = <Map<String, Object>>[];
      final run = s.save(_applier(w, ranges, sent: sent),
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      await ranges.started.future;
      // Another screen turns the pair into a Workout, same two marks.
      await s.edit((q) => q.withRange(mA, mB, MomentChoice.workout));
      ranges.gate.complete();
      final rep = await run;
      expect(ranges.loggedNaps, isEmpty);
      expect(ranges.loggedWorkouts, isEmpty);
      expect(w.answers, isEmpty);
      expect(sent, isEmpty);
      expect(rep.applied, isEmpty);
      final now = s.queue.ranges.single;
      expect(now.choice, MomentChoice.workout);
      expect(now.inProgress, isFalse, reason: 'the new decision is untouched');
      expect(const MomentReviewStore().load().ranges.single.choice,
          MomentChoice.workout);
    });

    test('a different workout TYPE counts as a replacement too', () async {
      final s = MomentReviewService();
      await s.edit(
          (q) => q.withRange(mA, mB, MomentChoice.workout, workoutType: 'running'));
      final ranges = _GatedNaps();
      // validation of a workout reads sessions, not naps: gate that instead
      final gated = _GatedSpans();
      final run = s.save(_applier(FakeAnswerWriter(), gated),
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      await gated.started.future;
      await s.edit(
          (q) => q.withRange(mA, mB, MomentChoice.workout, workoutType: 'cycling'));
      gated.gate.complete();
      await run;
      expect(gated.loggedWorkouts, isEmpty);
      expect(s.queue.ranges.single.workoutType, 'cycling');
      expect(ranges.loggedNaps, isEmpty);
    });

    test('an old Save whose range FAILS validation does not put its range back '
        'over a replacement', () async {
      final s = MomentReviewService();
      await s.edit((q) => q.withRange(mA, mB, MomentChoice.nap));
      // The read returns an overlapping nap, so the old Save's range fails.
      final ranges = _GatedNaps(then: [
        {'start': sec(2026, 10, 6, 9, 20), 'end': sec(2026, 10, 6, 9, 40)}
      ]);
      final run = s.save(_applier(FakeAnswerWriter(), ranges),
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      await ranges.started.future;
      await s.edit((q) => q.withRange(mA, mB, MomentChoice.workout));
      ranges.gate.complete();
      final rep = await run;
      expect(rep.failed, isNotEmpty);
      expect(s.queue.ranges.single.choice, MomentChoice.workout);
    });

    test('the same pairing, untouched, still goes through', () async {
      final s = MomentReviewService();
      await s.edit((q) => q.withRange(mA, mB, MomentChoice.nap));
      final ranges = _GatedNaps();
      final run = s.save(_applier(FakeAnswerWriter(), ranges),
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      await ranges.started.future;
      ranges.gate.complete();
      final rep = await run;
      expect(rep.failed, isEmpty);
      expect(ranges.loggedNaps, hasLength(1));
      expect(s.queue.isEmpty, isTrue);
    });
  });

  group('2  consent writes (pure)', () {
    const key = Prefs.taskerMomentExport;

    test('a second write while one is pending is ignored (null), not sent',
        () async {
      Prefs.setBool(key, true);
      final gate = Completer<bool>();
      var writes = 0;
      final b = AckedBool.forKey(key);
      final first = b.set(false, write: (k, v) {
        writes++;
        return gate.future;
      });
      expect(b.pending, isTrue);
      expect(await b.set(false, write: (k, v) async {
        writes++;
        return true;
      }), isNull);
      gate.complete(true);
      expect(await first, isTrue);
      expect(writes, 1);
      expect(b.pending, isFalse);
    });

    test('a failure rolls back to the value confirmed BEFORE it', () async {
      Prefs.setBool(key, true);
      final b = AckedBool.forKey(key);
      expect(await b.set(false, write: (k, v) async {
        Prefs.setBool(k, v); // what the real write does to the cache
        return true;
      }), isTrue);
      expect(Prefs.taskerMomentExportOn, isFalse);
      // The next write fails: back to the confirmed OFF, never to an older ON.
      expect(await b.set(true, write: (k, v) async {
        Prefs.setBool(k, v);
        return false;
      }), isFalse);
      expect(Prefs.taskerMomentExportOn, isFalse);
    });

    test('a write that throws counts as refused and releases the lock',
        () async {
      Prefs.setBool(key, true);
      final b = AckedBool.forKey(key);
      expect(await b.set(false, write: (k, v) async => throw StateError('x')),
          isFalse);
      expect(Prefs.taskerMomentExportOn, isTrue);
      expect(b.pending, isFalse);
    });

    test('the real write, when it works, is confirmed', () async {
      Prefs.setBool(key, false);
      expect(await AckedBool.forKey(key).set(true), isTrue);
      expect(Prefs.taskerMomentExportOn, isTrue);
    });
  });

  group('2  consent switch (screen)', () {
    final row = find.byKey(const ValueKey('tasker-moment-export'));
    Finder sw() => find.descendant(of: row, matching: find.byType(Switch));
    final err = find.byKey(const ValueKey('tasker-moment-export-error'));

    testWidgets('the switch is disabled while a write is pending and a second '
        'tap writes nothing', (t) async {
      Prefs.setBool(Prefs.taskerMomentExport, true);
      final gate = Completer<bool>();
      final asked = <bool>[];
      await pumpTall(
          t,
          AutomationSettings(setBoolAcked: (k, v) {
            asked.add(v);
            return gate.future;
          }));
      await t.pumpAndSettle();
      await t.tap(sw());
      await t.pump();
      expect(t.widget<Switch>(sw()).onChanged, isNull);
      await t.tap(sw(), warnIfMissed: false);
      await t.pump();
      expect(asked, [false]);
      Prefs.setBool(Prefs.taskerMomentExport, false);
      gate.complete(true);
      await t.pumpAndSettle();
      expect(t.widget<Switch>(sw()).value, isFalse);
      expect(t.widget<Switch>(sw()).onChanged, isNotNull);
      expect(err, findsNothing);
    });

    testWidgets('a write that fails AFTER the screen is gone still restores the '
        'confirmed value', (t) async {
      Prefs.setBool(Prefs.taskerMomentExport, true);
      // 1) OFF, confirmed.
      await pumpTall(
          t,
          AutomationSettings(setBoolAcked: (k, v) async {
            Prefs.setBool(k, v);
            return true;
          }));
      await t.pumpAndSettle();
      await t.tap(sw());
      await t.pumpAndSettle();
      expect(Prefs.taskerMomentExportOn, isFalse);
      // 2) ON, held; the screen goes away; the write is then refused.
      final gate = Completer<bool>();
      await pumpTall(
          t,
          AutomationSettings(setBoolAcked: (k, v) {
            Prefs.setBool(k, v); // optimistic cache, as the platform does
            return gate.future;
          }));
      await t.pumpAndSettle();
      await t.tap(sw());
      await t.pump();
      expect(Prefs.taskerMomentExportOn, isTrue, reason: 'optimistic');
      await t.pumpWidget(const MaterialApp(home: SizedBox()));
      gate.complete(false);
      await t.pumpAndSettle();
      expect(Prefs.taskerMomentExportOn, isFalse,
          reason: 'back to the confirmed OFF, not to an older ON');
      expect(t.takeException(), isNull);
    });

    testWidgets('a screen opened while a write is pending shows it disabled',
        (t) async {
      Prefs.setBool(Prefs.taskerMomentExport, false);
      final gate = Completer<bool>();
      await pumpTall(
          t, AutomationSettings(setBoolAcked: (k, v) => gate.future));
      await t.pumpAndSettle();
      await t.tap(sw());
      await t.pump();
      await t.pumpWidget(const MaterialApp(home: SizedBox()));
      await pumpTall(t, const AutomationSettings());
      await t.pumpAndSettle();
      expect(t.widget<Switch>(sw()).onChanged, isNull);
      gate.complete(false);
      await t.pumpAndSettle();
      expect(t.widget<Switch>(sw()).onChanged, isNotNull);
    });
  });
}

class _GatedSpans extends FakeRangeWriter {
  final gate = Completer<void>();
  final started = Completer<void>();
  @override
  Future<List<SessionSpan>> sessionSpans() async {
    if (!started.isCompleted) started.complete();
    await gate.future;
    return const [];
  }
}
