// The queue PERSISTS (a Prefs JSON blob, key `moment_review.queue`): written on
// every change, so leaving the screen, a rebuild or an app kill loses nothing;
// a corrupt blob reads as empty; an empty queue leaves no draft behind.
// RED: the store is a throwing stub.

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

  test('save then load (a brand new store object = a new screen) round-trips',
      () async {
    final q = MomentReviewQueue.empty
        .withDecision(
            kA, const ReviewDecision.label(MomentChoice.caffeine, value: 80))
        .withRange(mB, mC, MomentChoice.nap);
    await store.save(q);
    final back = const MomentReviewStore().load();
    expect(back.decisionFor(kA)!.value, 80);
    expect(back.ranges.single.startKey, mB.key);
    expect(back.length, 2);
  });

  test('what is stored is plain JSON under the documented key (restart-proof)',
      () async {
    await store.save(MomentReviewQueue.empty
        .withDecision(kA, const ReviewDecision.skip()));
    final raw = Prefs.getString(MomentReviewStore.prefKey, '');
    expect(MomentReviewStore.prefKey, 'moment_review.queue');
    expect(raw, isNotEmpty);
    // A process that starts later reads exactly this text.
    final fresh = MomentReviewQueue.fromJson(jsonDecode(raw));
    expect(fresh.decisionFor(kA)!.kind, ReviewDecisionKind.skip);
  });

  test('a later save replaces the earlier one', () async {
    await store.save(MomentReviewQueue.empty
        .withDecision(kA, const ReviewDecision.skip()));
    await store.save(MomentReviewQueue.empty.withDecision(
        kA, const ReviewDecision.label(MomentChoice.meal)));
    expect(store.load().decisionFor(kA)!.choice, MomentChoice.meal);
    expect(store.load().length, 1);
  });

  test('saving an empty queue leaves no draft behind', () async {
    await store.save(MomentReviewQueue.empty
        .withDecision(kA, const ReviewDecision.skip()));
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
