// RED APK2: drive the real screens and read their real activity/moment stores.
// No future production types or constructor parameters are referenced.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/apk2_keys.dart';
import 'support/apk2_review_harness.dart';
import 'support/as_of_recalc_fakes.dart' show settle;
import 'support/pin_tz.dart';

void main() {
  pinProcessTimeZone('America/Denver');

  testWidgets('day change clears the old rows and the Save bar while the new timeline is loading', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    final newer = await r.repo.getDayTimeline(apk2NewerDay);
    final gate = Completer<Map<String, dynamic>>();
    await r.mount(t);
    await apk2Show(t, apk2NapA);
    await apk2Tap(t, apk2Keep(apk2NapA));
    r.repo.timelineGate = gate;
    await apk2Tap(t, find.byWidgetPredicate((w) =>
        w is Pressable && w.semanticLabel == 'Next day'));
    await apk2Tap(t, apk2Key(apk2Leave));
    expect(apk2PageIds(), isEmpty);
    expect(apk2Key(apk2Save), findsNothing);
    expect(apk2Keep(apk2NapA), findsNothing);
    expect(apk2Row(apk2NapA), findsNothing);
    expect(await r.snapshot(t), before);
    gate.complete(newer);
    await settle(t);
    expect(apk2PageIds(), isEmpty);
    expect(apk2Key(apk2Save), findsNothing);
    expect(await r.snapshot(t), before);
    semantics.dispose();
  });

  testWidgets('normal breakdown lists all four pending items in the list, '
      'with no tray, no pagination and no Save bar until something is staged', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    await r.mount(t);
    expect(apk2PageIds(), apk2ActivityIds);
    for (final key in ['apk2-review-tray', 'apk2-review-next',
        'apk2-review-previous', 'apk2-review-page', 'apk2-review-empty']) {
      expect(apk2Key(key), findsNothing, reason: key);
    }
    expect(apk2Key(apk2Save), findsNothing);
    for (final id in apk2ActivityIds) {
      await apk2Show(t, id);
      expect(apk2Keep(id), findsOneWidget);
      expect(apk2Discard(id), findsOneWidget);
      expect(apk2Key('day-review-label:$id'), findsOneWidget);
      expect(apk2Enabled(t, apk2Keep(id)), isTrue);
    }
    await apk2Tap(t, apk2Keep(apk2NapA));
    expect(apk2Key(apk2Save), findsOneWidget);
    expect(apk2Enabled(t, apk2Key(apk2Save)), isTrue);
    // Disposed in the body: the binding checks handles before teardowns run.
    semantics.dispose();
  });

  testWidgets('Keep and Discard leave the database untouched until Save '
      'commits both decisions and leaves unchosen items pending', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    await r.mount(t);
    await apk2Show(t, apk2NapA);
    await apk2Tap(t, apk2Keep(apk2NapA));
    expect(await r.snapshot(t), before, reason: 'Keep is staged only');
    await apk2Show(t, apk2WorkoutA);
    await apk2Tap(t, apk2Discard(apk2WorkoutA));
    expect(await r.snapshot(t), before, reason: 'Discard is staged only');
    expect(apk2Enabled(t, apk2Key(apk2Save)), isTrue);

    await apk2Tap(t, apk2Key(apk2Save));
    expect(await r.status(t, apk2NapA), ActivityReviewStatus.confirmed);
    expect(await r.status(t, apk2WorkoutA), ActivityReviewStatus.discarded);
    expect(await r.status(t, apk2NapB), ActivityReviewStatus.pending);
    expect(await r.status(t, apk2WorkoutB), ActivityReviewStatus.pending);
    final after = await r.snapshot(t);
    expect(after['sleep_nap'], hasLength(1));
    expect(after['sleep_nap']!.single['start_ts'], apk2At(11));
    expect(after['sleep_nap']!.single['end_ts'], apk2At(11, 25));
    expect(after['sleep_nap']!.single['source'], 'confirmed');
    expect(after['sessions'], isEmpty, reason: 'discarded workout is not logged');
    expect(after['moment_label'], before['moment_label']);
    expect(apk2Key(apk2Save), findsNothing);
    expect(apk2PageIds(), {apk2NapB, apk2WorkoutB});
    // Disposed in the body: the binding checks handles before teardowns run.
    semantics.dispose();
  });

  for (final keep in [true, false]) {
    testWidgets('tapping a staged ${keep ? 'Keep' : 'Discard'} again undoes '
        'it and disables Save without writing', (t) async {
      final semantics = t.ensureSemantics();
      final r = await Apk2Rig.create(t);
      final before = await r.snapshot(t);
      await r.mount(t);
      await apk2Show(t, apk2NapA);
      final choice = keep ? apk2Keep(apk2NapA) : apk2Discard(apk2NapA);
      await apk2Tap(t, choice);
      expect(apk2Selected(t, choice), isTrue);
      expect(apk2Enabled(t, apk2Key(apk2Save)), isTrue);
      await apk2Tap(t, choice);
      expect(apk2Selected(t, choice), isFalse);
      expect(apk2Key(apk2Save), findsNothing);
      expect(await r.snapshot(t), before);
      // Disposed in the body: the binding checks handles before teardowns run.
      semantics.dispose();
    });
  }

  testWidgets('keeping a workout creates one session at its detected times '
      'while discarding a nap credits no sleep', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    await r.mount(t);
    await apk2Show(t, apk2WorkoutA);
    await apk2Tap(t, apk2Keep(apk2WorkoutA));
    await apk2Show(t, apk2NapA);
    await apk2Tap(t, apk2Discard(apk2NapA));
    expect(await r.snapshot(t), before);
    await apk2Tap(t, apk2Key(apk2Save));
    expect(await r.status(t, apk2WorkoutA), ActivityReviewStatus.confirmed);
    expect(await r.status(t, apk2NapA), ActivityReviewStatus.discarded);
    final after = await r.snapshot(t);
    expect(after['sessions'], hasLength(1));
    expect(after['sessions']!.single['start_ts'], apk2At(12));
    expect(after['sessions']!.single['end_ts'], apk2At(12, 30));
    expect(after['sessions']!.single['type'], 'walking');
    expect(after['sleep_nap'], isEmpty);
    expect(await r.status(t, apk2NapB), ActivityReviewStatus.pending);
    expect(await r.status(t, apk2WorkoutB), ActivityReviewStatus.pending);
    // Disposed in the body: the binding checks handles before teardowns run.
    semantics.dispose();
  });

  testWidgets('choosing the other action replaces a staged choice and Save '
      'applies only the replacement', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    await r.mount(t);
    const chosen = apk2NapA;
    await apk2Tap(t, apk2Keep(chosen));
    expect(apk2Selected(t, apk2Keep(chosen)), isTrue);
    await apk2Tap(t, apk2Discard(chosen));
    expect(apk2Selected(t, apk2Keep(chosen)), isFalse);
    expect(apk2Selected(t, apk2Discard(chosen)), isTrue);
    expect(await r.snapshot(t), before);
    await apk2Tap(t, apk2Key(apk2Save));
    expect(await r.status(t, chosen), ActivityReviewStatus.discarded);
    for (final id in apk2ActivityIds.difference({chosen})) {
      expect(await r.status(t, id), ActivityReviewStatus.pending, reason: id);
    }
    expect((await r.snapshot(t))['sleep_nap'], isEmpty);
    expect((await r.snapshot(t))['sessions'], isEmpty);
    // Disposed in the body: the binding checks handles before teardowns run.
    semantics.dispose();
  });

  testWidgets('Back asks before losing changes; cancel preserves the page and '
      'choice; confirming leaves without saving or restoring a stale draft', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    await r.mount(t);
    expect(apk2PageIds(), apk2ActivityIds);
    const chosen = apk2WorkoutB;
    await apk2Tap(t, apk2Discard(chosen));
    await t.binding.handlePopRoute();
    await settle(t, n: 8);
    expect(apk2Key(apk2LeaveDialog), findsOneWidget);
    expect(find.descendant(of: apk2Key(apk2LeaveDialog),
        matching: find.textContaining(RegExp('discard', caseSensitive: false))),
        findsWidgets);
    await apk2Tap(t, apk2Key(apk2Stay));
    expect(apk2Key(apk2LeaveDialog), findsNothing);
    expect(apk2PageIds(), apk2ActivityIds);
    expect(apk2Selected(t, apk2Discard(chosen)), isTrue);
    expect(apk2Enabled(t, apk2Key(apk2Save)), isTrue);
    expect(await r.snapshot(t), before);

    await t.binding.handlePopRoute();
    await settle(t, n: 8);
    await apk2Tap(t, apk2Key(apk2Leave));
    expect(find.text('Outside breakdown'), findsOneWidget);
    expect(apk2Key(apk2Save), findsNothing);
    expect(await r.snapshot(t), before);
    await apk2Tap(t, find.text('Open breakdown'));
    await settle(t);
    await apk2Show(t, chosen);
    expect(apk2Selected(t, apk2Discard(chosen)), isFalse);
    expect(apk2Key(apk2Save), findsNothing);
    // Disposed in the body: the binding checks handles before teardowns run.
    semantics.dispose();
  });

  testWidgets('a failure on the second decision rolls back the entire Save, '
      'keeps every choice, and permits a successful retry', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    // Fail AFTER one decision, whichever order the implementation chooses.
    // RAISE(ABORT) only rolls back this SQL statement; the app must roll back
    // the enclosing batch to undo the preceding decision and its nap write.
    await t.runAsync(() => r.db.execute('''
      CREATE TRIGGER apk2_fail_second_review
      BEFORE UPDATE OF status ON activity_suggestions
      WHEN OLD.status = 'pending' AND NEW.status IN ('confirmed', 'discarded')
        AND EXISTS (SELECT 1 FROM activity_suggestions
                    WHERE status IN ('confirmed', 'discarded'))
      BEGIN SELECT RAISE(ABORT, 'APK2 injected disk failure'); END
    '''));
    await r.mount(t, marked: true);
    await apk2Show(t, apk2MarkA);
    await apk2Tap(t, apk2Discard(apk2MarkA));
    await apk2Show(t, apk2NapA);
    await apk2Tap(t, apk2Keep(apk2NapA));
    await apk2Show(t, apk2WorkoutA);
    await apk2Tap(t, apk2Discard(apk2WorkoutA));
    await apk2Tap(t, apk2Key(apk2Save));
    expect(apk2Key(apk2SaveError), findsOneWidget);
    apk2StatusSpokenOnce(t, apk2SaveError);
    expect(await r.snapshot(t), before,
        reason: 'neither ledger decisions nor accepted records may leak');
    expect(apk2Enabled(t, apk2Key(apk2Save)), isTrue);
    await apk2Show(t, apk2NapA);
    expect(apk2Selected(t, apk2Keep(apk2NapA)), isTrue);
    await apk2Show(t, apk2WorkoutA);
    expect(apk2Selected(t, apk2Discard(apk2WorkoutA)), isTrue);

    await t.runAsync(() => r.db.execute('DROP TRIGGER apk2_fail_second_review'));
    await apk2Tap(t, apk2Key(apk2Save));
    expect(apk2Key(apk2SaveError), findsNothing);
    expect(await r.status(t, apk2NapA), ActivityReviewStatus.confirmed);
    expect(await r.status(t, apk2WorkoutA), ActivityReviewStatus.discarded);
    expect((await r.snapshot(t))['sleep_nap'], hasLength(1));
    final labels = (await t.runAsync(() => LocalDb.momentLabels(date: apk2Day)))!;
    expect(labels.where((l) => l.hhmm == '09:15'), hasLength(1));
    expect(labels.singleWhere((l) => l.hhmm == '09:15').label, isNull);
    expect(apk2Key(apk2Save), findsNothing);
    // Disposed in the body: the binding checks handles before teardowns run.
    semantics.dispose();
  });

  testWidgets('marked moments and detected naps and workouts share one '
      'list and one Save with no early writes', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    await r.mount(t, marked: true);
    expect(apk2PageIds(), apk2MixedIds);
    await apk2Show(t, apk2MarkA);
    await apk2Tap(t, apk2Discard(apk2MarkA));
    await apk2Show(t, apk2NapA);
    await apk2Tap(t, apk2Keep(apk2NapA));
    await apk2Show(t, apk2WorkoutA);
    await apk2Tap(t, apk2Discard(apk2WorkoutA));
    expect(await r.snapshot(t), before);
    await apk2Tap(t, apk2Key(apk2Save));
    final labels = (await t.runAsync(() => LocalDb.momentLabels(date: apk2Day)))!;
    final skipped = labels.where((l) => l.hhmm == '09:15').toList();
    expect(skipped, hasLength(1));
    expect(skipped.single.label, isNull, reason: 'Discard uses the skip tombstone');
    expect(labels.any((l) => l.hhmm == '10:05'), isFalse);
    expect(await r.status(t, apk2NapA), ActivityReviewStatus.confirmed);
    expect(await r.status(t, apk2WorkoutA), ActivityReviewStatus.discarded);
    expect(apk2PageIds(), {apk2NapB, apk2WorkoutB, apk2MarkB});
    expect(apk2Key(apk2Save), findsNothing);
    // Disposed in the body: the binding checks handles before teardowns run.
    semantics.dispose();
  });

  testWidgets('a queue read failure stays visible beside the day chart, '
      'does not claim nothing to review, and Retry restores pending items', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    r.repo.failQueueRead = true;
    await r.mount(t);
    expect(apk2Key(apk2LoadError), findsOneWidget);
    apk2StatusSpokenOnce(t, apk2LoadError);
    expect(apk2Key(apk2Chart), findsOneWidget);
    expect(apk2PageIds(), isEmpty);
    r.repo.failQueueRead = false;
    await apk2Tap(t, apk2Key(apk2Retry));
    expect(apk2Key(apk2LoadError), findsNothing);
    expect(apk2PageIds(), apk2ActivityIds);
    // Disposed in the body: the binding checks handles before teardowns run.
    semantics.dispose();
  });

  // A saved nap or workout keeps its row (disabled Edit) until the day is
  // calculated again AFTER the Save.
  group('a saved row waits for a result newer than its Save', () {
    final future = DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch;
    // Another Save is what makes the screen read the day again.
    Future<void> saveThenReloadViaSecondSave(WidgetTester t, Apk2Rig r) async {
      await apk2Tap(t, apk2Keep(apk2NapA));
      await apk2Tap(t, apk2Key(apk2Save));
      await apk2Tap(t, apk2Discard(apk2WorkoutB));
      await apk2Tap(t, apk2Key(apk2Save));
    }

    testWidgets('a stale reload keeps it, even beside a stored overlapping nap', (t) async {
      final semantics = t.ensureSemantics();
      final r = await Apk2Rig.create(t);
      // Derivation deferred: the stored bundle is the OLD one, with a nap that
      // happens to overlap the edited window.
      r.repo.computedAtMs = 1;
      r.repo.extraTimeline = {'naps': [
        {'start': apk2At(11, 20), 'end': apk2At(11, 40), 'duration_min': 20},
      ]};
      await r.mount(t);
      await saveThenReloadViaSecondSave(t, r);
      expect(apk2Row(apk2NapA), findsOneWidget,
          reason: 'old data must not retire the placeholder');
      expect(apk2Key('day-row-edit:$apk2NapA'), findsOneWidget);
      expect(apk2Enabled(t, apk2Key('day-row-edit:$apk2NapA')), isFalse);
      semantics.dispose();
    });

    testWidgets('a newer result clears it even when no nap row exists '
        '(absorbed into the main sleep)', (t) async {
      final semantics = t.ensureSemantics();
      final r = await Apk2Rig.create(t);
      r.repo.computedAtMs = future;
      await r.mount(t);
      await saveThenReloadViaSecondSave(t, r);
      expect(apk2Row(apk2NapA), findsNothing);
      expect(apk2Key('day-row-edit:$apk2NapA'), findsNothing);
      semantics.dispose();
    });

    testWidgets('its stored replacement takes the placeholder\'s place among '
        'rows at the same time', (t) async {
      final semantics = t.ensureSemantics();
      final r = await Apk2Rig.create(t);
      const tie = 'activity:apk2-tie';
      await t.runAsync(() => r.store.reconcile(ActivityKind.workout, [
        {'id': 'apk2-workout-a', 'start_ts': apk2At(12),
          'end_ts': apk2At(12, 30), 'sport': 'walking'},
        {'id': 'apk2-workout-b', 'start_ts': apk2At(18),
          'end_ts': apk2At(18, 40), 'sport': 'running'},
        {'id': 'apk2-tie', 'start_ts': apk2At(11),
          'end_ts': apk2At(11, 25), 'sport': 'walking'},
      ]));
      await r.mount(t);
      expect(apk2PageIds(), contains(tie));
      final first = t.getTopLeft(apk2Row(apk2NapA)).dy <=
              t.getTopLeft(apk2Row(tie)).dy ? apk2NapA : tie;
      final second = first == apk2NapA ? tie : apk2NapA;
      // The kept one comes back as a stored row at the very same time.
      r.repo.computedAtMs = future;
      r.repo.extraTimeline = first == apk2NapA
          ? {'naps': [{'start': apk2At(11), 'end': apk2At(11, 25), 'duration_min': 25}]}
          : {'sessions': [{'id': 'apk2-stored', 'start_ts': apk2At(11),
              'end_ts': apk2At(11, 25), 'type': 'walking'}]};
      await apk2Tap(t, apk2Keep(first));
      await apk2Tap(t, apk2Key(apk2Save));
      expect(apk2Row(first), findsNothing, reason: 'the placeholder is gone');
      final stored = first == apk2NapA
          ? apk2Key('apk2-day-row:nap:${apk2At(11)}')
          : apk2Key('apk2-day-row:session:apk2-stored');
      expect(stored, findsOneWidget);
      expect(apk2Row(second), findsOneWidget);
      expect(t.getTopLeft(stored).dy, lessThan(t.getTopLeft(apk2Row(second)).dy),
          reason: 'A then B stays A then B');
      semantics.dispose();
    });
  });
}
