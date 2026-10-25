// RED APK2: drive the real screens and read their real activity/moment stores.
// No future production types or constructor parameters are referenced.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';

import 'support/apk2_keys.dart';
import 'support/apk2_review_harness.dart';
import 'support/as_of_recalc_fakes.dart' show settle;
import 'support/pin_tz.dart';

void main() {
  pinProcessTimeZone('America/Denver');

  testWidgets('normal breakdown pages four pending items three at a time, '
      'with disabled boundary arrows and Save', (t) async {
    final semantics = t.ensureSemantics();
    addTearDown(semantics.dispose);
    final r = await Apk2Rig.create(t);
    await r.mount(t);
    expect(apk2Key(apk2Tray), findsOneWidget);
    final first = apk2PageIds();
    expect(first, hasLength(3));
    expect(apk2ActivityIds.containsAll(first), isTrue);
    expect(apk2Enabled(t, apk2Key(apk2Save)), isFalse);
    expect(apk2Enabled(t, apk2Key(apk2Previous)), isFalse);
    expect(apk2Enabled(t, apk2Key(apk2Next)), isTrue);
    expect(find.descendant(of: apk2Key(apk2Page), matchRoot: true,
        matching: find.text('1 of 2')),
        findsOneWidget);
    expect(apk2SpokenCount(t, '1 of 2'), 1);

    await apk2Tap(t, apk2Key(apk2Next));
    final second = apk2PageIds();
    expect(second, hasLength(1));
    expect(first.intersection(second), isEmpty);
    expect(first.union(second), apk2ActivityIds);
    expect(apk2Enabled(t, apk2Key(apk2Next)), isFalse);
    expect(apk2Enabled(t, apk2Key(apk2Previous)), isTrue);
    expect(apk2SpokenCount(t, '2 of 2'), 1);
    expect(apk2SpokenCount(t, '1 of 2'), 0);
    await apk2Tap(t, apk2Key(apk2Previous));
    expect(apk2PageIds(), first);
  });

  testWidgets('Keep and Discard leave the database untouched until Save '
      'commits both decisions and leaves unchosen items pending', (t) async {
    final semantics = t.ensureSemantics();
    addTearDown(semantics.dispose);
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
    expect(apk2Enabled(t, apk2Key(apk2Save)), isFalse);
    expect(apk2PageIds(), {apk2NapB, apk2WorkoutB});
  });

  for (final keep in [true, false]) {
    testWidgets('tapping a staged ${keep ? 'Keep' : 'Discard'} again undoes '
        'it and disables Save without writing', (t) async {
      final semantics = t.ensureSemantics();
      addTearDown(semantics.dispose);
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
      expect(apk2Enabled(t, apk2Key(apk2Save)), isFalse);
      expect(await r.snapshot(t), before);
    });
  }

  testWidgets('keeping a workout creates one session at its detected times '
      'while discarding a nap credits no sleep', (t) async {
    final semantics = t.ensureSemantics();
    addTearDown(semantics.dispose);
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
  });

  testWidgets('paging preserves a choice; choosing the other action replaces '
      'it and Save applies only the replacement', (t) async {
    final semantics = t.ensureSemantics();
    addTearDown(semantics.dispose);
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    await r.mount(t);
    expect(apk2Key(apk2Tray), findsOneWidget);
    final chosen = apk2PageIds().first;
    await apk2Tap(t, apk2Keep(chosen));
    await apk2Tap(t, apk2Key(apk2Next));
    await apk2Tap(t, apk2Key(apk2Previous));
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
  });

  testWidgets('Back asks before losing changes; cancel preserves page and '
      'choice; confirming leaves without saving or restoring a stale draft', (t) async {
    final semantics = t.ensureSemantics();
    addTearDown(semantics.dispose);
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    await r.mount(t);
    expect(apk2Key(apk2Tray), findsOneWidget);
    await apk2Tap(t, apk2Key(apk2Next));
    final chosen = apk2PageIds().single;
    await apk2Tap(t, apk2Discard(chosen));
    await t.binding.handlePopRoute();
    await settle(t, n: 8);
    expect(apk2Key(apk2LeaveDialog), findsOneWidget);
    expect(find.descendant(of: apk2Key(apk2LeaveDialog),
        matching: find.textContaining(RegExp('discard', caseSensitive: false))),
        findsWidgets);
    await apk2Tap(t, apk2Key(apk2Stay));
    expect(apk2Key(apk2LeaveDialog), findsNothing);
    expect(apk2PageIds(), {chosen});
    expect(apk2Selected(t, apk2Discard(chosen)), isTrue);
    expect(apk2Enabled(t, apk2Key(apk2Save)), isTrue);
    expect(await r.snapshot(t), before);

    await t.binding.handlePopRoute();
    await settle(t, n: 8);
    await apk2Tap(t, apk2Key(apk2Leave));
    expect(find.text('Outside breakdown'), findsOneWidget);
    expect(apk2Key(apk2Tray), findsNothing);
    expect(await r.snapshot(t), before);
    await apk2Tap(t, find.text('Open breakdown'));
    await settle(t);
    await apk2Show(t, chosen);
    expect(apk2Selected(t, apk2Discard(chosen)), isFalse);
    expect(apk2Enabled(t, apk2Key(apk2Save)), isFalse);
  });

  testWidgets('a failure on the second decision rolls back the entire Save, '
      'keeps every choice, and permits a successful retry', (t) async {
    final semantics = t.ensureSemantics();
    addTearDown(semantics.dispose);
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
    expect(apk2Enabled(t, apk2Key(apk2Save)), isFalse);
  });

  testWidgets('marked moments and detected naps and workouts share one '
      'paginated queue and one Save with no early writes', (t) async {
    final semantics = t.ensureSemantics();
    addTearDown(semantics.dispose);
    final r = await Apk2Rig.create(t);
    final before = await r.snapshot(t);
    await r.mount(t, marked: true);
    expect(apk2Key(apk2Tray), findsOneWidget);
    final first = apk2PageIds();
    expect(first, hasLength(3));
    await apk2Tap(t, apk2Key(apk2Next));
    final second = apk2PageIds();
    expect(second, hasLength(3));
    expect(first.intersection(second), isEmpty);
    expect(first.union(second), apk2MixedIds);
    expect(apk2Enabled(t, apk2Key(apk2Next)), isFalse);
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
    expect(apk2Enabled(t, apk2Key(apk2Save)), isFalse);
  });

  testWidgets('a queue read failure stays visible beside the day chart, '
      'does not claim empty, and Retry restores pending items', (t) async {
    final semantics = t.ensureSemantics();
    addTearDown(semantics.dispose);
    final r = await Apk2Rig.create(t);
    r.repo.failQueueRead = true;
    await r.mount(t);
    expect(apk2Key(apk2LoadError), findsOneWidget);
    apk2StatusSpokenOnce(t, apk2LoadError);
    expect(apk2Key(apk2Chart), findsOneWidget);
    expect(apk2Key(apk2Empty), findsNothing);
    expect(apk2PageIds(), isEmpty);
    r.repo.failQueueRead = false;
    await apk2Tap(t, apk2Key(apk2Retry));
    expect(apk2Key(apk2LoadError), findsNothing);
    expect(apk2PageIds(), hasLength(3));
  });
}
