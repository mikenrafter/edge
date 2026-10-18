// Validating a review range (pure). A nap range is exactly the two marked
// minutes; the same rules as the Naps screen (5 min..6 h, no overlap) plus never
// in the future. A workout range reuses validateManualWindow. Local wall-clock
// DateTimes only; midnight is calendar arithmetic. RED: throwing stub.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_range.dart';

import '../../../support/moment_review_fakes.dart';

ManualWindowError? _v(
  MomentChoice c,
  DateTime s,
  DateTime e, {
  List<Map<String, dynamic>> naps = const [],
  List<SessionSpan> spans = const [],
}) =>
    validateReviewRange(
        choice: c,
        start: s,
        end: e,
        now: reviewNow,
        existingNaps: naps,
        existingSpans: spans);

void main() {
  final s = DateTime(2026, 10, 6, 13, 0);

  group('nap', () {
    test('a normal nap is valid', () {
      expect(_v(MomentChoice.nap, s, DateTime(2026, 10, 6, 14, 0)), isNull);
    });

    test('end must be after start (equal and earlier both refused)', () {
      expect(_v(MomentChoice.nap, s, s), ManualWindowError.endNotAfterStart);
      expect(_v(MomentChoice.nap, s, DateTime(2026, 10, 6, 12, 0)),
          ManualWindowError.endNotAfterStart);
    });

    test('5 minutes is the floor, 6 hours the ceiling (inclusive)', () {
      expect(_v(MomentChoice.nap, s, DateTime(2026, 10, 6, 13, 4)),
          ManualWindowError.tooShort);
      expect(_v(MomentChoice.nap, s, DateTime(2026, 10, 6, 13, 5)), isNull);
      expect(_v(MomentChoice.nap, s, DateTime(2026, 10, 6, 19, 0)), isNull);
      expect(_v(MomentChoice.nap, s, DateTime(2026, 10, 6, 19, 1)),
          ManualWindowError.tooLong);
    });

    test('a nap that ends after now is refused', () {
      expect(
          _v(MomentChoice.nap, DateTime(2026, 10, 7, 11, 0),
              DateTime(2026, 10, 7, 12, 1)),
          ManualWindowError.inFuture);
      expect(
          _v(MomentChoice.nap, DateTime(2026, 10, 7, 11, 0),
              DateTime(2026, 10, 7, 12, 0)),
          isNull,
          reason: 'ending exactly now is fine');
    });

    test('overlapping a nap already on the day is refused; touching is fine',
        () {
      final existing = [
        {'start': sec(2026, 10, 6, 13, 30), 'end': sec(2026, 10, 6, 14, 0)}
      ];
      expect(
          _v(MomentChoice.nap, s, DateTime(2026, 10, 6, 13, 45),
              naps: existing),
          ManualWindowError.overlapsExisting);
      expect(
          _v(MomentChoice.nap, DateTime(2026, 10, 6, 14, 0),
              DateTime(2026, 10, 6, 14, 30),
              naps: existing),
          isNull);
    });

    test('a nap spanning local midnight is valid and measured across it', () {
      expect(
          _v(MomentChoice.nap, DateTime(2026, 10, 5, 23, 40),
              DateTime(2026, 10, 6, 0, 20)),
          isNull);
      // 23:40 -> 05:45 next day is 6 h 5 min: too long, so midnight is not a
      // way round the ceiling.
      expect(
          _v(MomentChoice.nap, DateTime(2026, 10, 5, 23, 40),
              DateTime(2026, 10, 6, 5, 45)),
          ManualWindowError.tooLong);
    });
  });

  group('workout', () {
    test('a valid window passes; back-to-back with a saved session passes', () {
      final spans = [
        SessionSpan('a', sec(2026, 10, 6, 9, 0), sec(2026, 10, 6, 10, 0))
      ];
      expect(
          _v(MomentChoice.workout, DateTime(2026, 10, 6, 10, 0),
              DateTime(2026, 10, 6, 11, 0),
              spans: spans),
          isNull);
    });

    test('overlap with a saved session is refused', () {
      final spans = [
        SessionSpan('a', sec(2026, 10, 6, 9, 0), sec(2026, 10, 6, 10, 0))
      ];
      expect(
          _v(MomentChoice.workout, DateTime(2026, 10, 6, 9, 30),
              DateTime(2026, 10, 6, 10, 30),
              spans: spans),
          ManualWindowError.overlapsExisting);
    });

    test('end not after start, under a minute, over 24 h, future', () {
      expect(_v(MomentChoice.workout, s, s), ManualWindowError.endNotAfterStart);
      expect(_v(MomentChoice.workout, s, s.add(const Duration(seconds: 59))),
          ManualWindowError.tooShort);
      expect(_v(MomentChoice.workout, DateTime(2026, 10, 5, 8, 0),
              DateTime(2026, 10, 6, 8, 1)),
          ManualWindowError.tooLong);
      expect(
          _v(MomentChoice.workout, DateTime(2026, 10, 7, 11, 0),
              DateTime(2026, 10, 7, 12, 1)),
          ManualWindowError.inFuture);
    });

    test('a workout spanning local midnight is valid', () {
      expect(
          _v(MomentChoice.workout, DateTime(2026, 10, 5, 23, 40),
              DateTime(2026, 10, 6, 0, 50)),
          isNull);
    });
  });

  test('only nap and workout are range choices', () {
    expect(() => _v(MomentChoice.caffeine, s, DateTime(2026, 10, 6, 14, 0)),
        throwsArgumentError);
  });
}
