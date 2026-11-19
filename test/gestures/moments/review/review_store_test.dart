// The queue's STORE (a Prefs JSON blob, key `moment_review.queue`) keeps ONLY a
// Save that already started (owner, 2026-11-17: choices and unstarted ranges
// are session-only). Written on every change so an interrupted Save resumes
// after a kill; a corrupt blob reads as empty; an empty queue leaves no draft
// behind; an older build's blob is filtered when loaded.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/gestures/moment_review_store.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/moment_review_fakes.dart';

final kA = ReviewKey.moment(mA);

void main() {
  const store = MomentReviewStore();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    // Prefs caches the first instance for the whole run: wipe our key.
    Prefs.setString(MomentReviewStore.prefKey, '');
  });

  test('nothing stored: an empty queue', () {
    expect(store.load().isEmpty, isTrue);
  });

  ReviewRange started({bool windowWritten = true}) => MomentReviewQueue.empty
      .withRange(mB, mC, MomentChoice.nap)
      .ranges
      .single
      .copyWith(attempting: true, windowWritten: windowWritten);

  test('save keeps only the started range; choices and unstarted ranges stay '
      'in the session', () async {
    final q = MomentReviewQueue.empty
        .withDecision(
            kA, const ReviewDecision.label(MomentChoice.caffeine, value: 80))
        .withRange(mA, mB, MomentChoice.workout)
        .withRangeProgress(started());
    await store.save(q);
    final back = const MomentReviewStore().load();
    expect(back.decisions, isEmpty);
    expect(back.ranges.single.startKey, mB.key);
    expect(back.ranges.single.windowWritten, isTrue);
  });

  test('what is stored is plain JSON under the documented key (restart-proof)',
      () async {
    await store.save(
        MomentReviewQueue.empty.withRangeProgress(started()));
    final raw = Prefs.getString(MomentReviewStore.prefKey, '');
    expect(MomentReviewStore.prefKey, 'moment_review.queue');
    expect(raw, isNotEmpty);
    // A process that starts later reads exactly this text.
    final fresh = MomentReviewQueue.fromJson(jsonDecode(raw));
    expect(fresh.ranges.single.windowWritten, isTrue);
  });

  test('a later save replaces the earlier one', () async {
    await store.save(MomentReviewQueue.empty.withRangeProgress(started()));
    await store.save(MomentReviewQueue.empty
        .withRangeProgress(started().copyWith(startLabelled: true)));
    expect(store.load().ranges.single.startLabelled, isTrue);
    expect(store.load().length, 1);
  });

  test('a queue with nothing started stores nothing', () async {
    await store.save(MomentReviewQueue.empty
        .withDecision(kA, const ReviewDecision.skip()));
    expect(Prefs.getString(MomentReviewStore.prefKey, ''), '');
    expect(store.load().isEmpty, isTrue);
  });

  test('saving an empty queue leaves no draft behind', () async {
    await store.save(MomentReviewQueue.empty.withRangeProgress(started()));
    await store.save(MomentReviewQueue.empty);
    expect(store.load().isEmpty, isTrue);
    final raw = Prefs.getString(MomentReviewStore.prefKey, '');
    expect(raw == '' || MomentReviewQueue.fromJson(jsonDecode(raw)).isEmpty,
        isTrue);
  });

  test('a corrupt blob reads as empty and never throws', () {
    for (final bad in ['{not json', '[1,2]', '"x"', 'null', '{"decisions":5}']) {
      Prefs.setString(MomentReviewStore.prefKey, bad);
      expect(store.load().isEmpty, isTrue, reason: bad);
    }
  });
}
