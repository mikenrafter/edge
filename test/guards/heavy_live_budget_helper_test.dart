// heavy_live_budget_helper_test.dart — the @live budget helper (design 02,
// rev 5): reference loop of 10,000 integer adds timed on the same runner; the
// @live function's median of 5 x 10,000 calls must be <= 200 x that median,
// capped at 8 ms absolute.
//
// The decision and median logic is driven with a scripted clock (deterministic);
// two smoke tests use the real monotonic Stopwatch with a gap so large it
// cannot flake. No dates, no sleeps, no retries.
//
// Each @live function (none exist until step 1 GREEN marks some) adds
// its own `expectLiveBudget(() => fn(fixedInput))` test.

import 'package:flutter_test/flutter_test.dart';

import 'support/live_budget.dart';

/// Replays [stamps] as successive clock reads.
MicrosClock scripted(List<int> stamps) {
  var i = 0;
  return () => stamps[i++];
}

void main() {
  group('limit', () {
    test('200x the reference, capped at 8 ms', () {
      expect(liveLimitMicros(10), 2000);
      expect(liveLimitMicros(40), 8000);
      expect(liveLimitMicros(100), 8000, reason: 'cap wins');
      expect(kLiveCapMicros, 8000);
      expect(kLiveReferenceFactor, 200);
    });

    test('a 0 us reference (coarse clock) still gives a non-zero limit', () {
      expect(liveLimitMicros(0), 200);
    });

    test('the measurement shape is 5 runs x 10,000 calls', () {
      expect(kLiveRuns, 5);
      expect(kLiveCalls, 10000);
    });
  });

  group('median', () {
    test('is the middle of five, not the mean or the best', () {
      expect(medianOf([9, 1, 5, 100, 3]), 5);
    });
  });

  group('measureLiveBudget with a scripted clock', () {
    // 10 clock reads: 5 reference runs (start,end) then 5 live runs.
    int sizeOf(List<int> runs) => runs.length;

    List<int> stamps(List<int> refRuns, List<int> liveRuns) {
      expect(sizeOf(refRuns), 5);
      expect(sizeOf(liveRuns), 5);
      var t = 0;
      final out = <int>[];
      for (final d in [...refRuns, ...liveRuns]) {
        out.add(t);
        t += d;
        out.add(t);
        t += 1000; // gap between runs is not part of any run
      }
      return out;
    }

    test('passes at exactly the limit', () {
      final r = measureLiveBudget(() {},
          now: scripted(stamps([10, 10, 10, 10, 10], [2000, 2000, 2000, 2000, 2000])));
      expect(r.referenceMedianMicros, 10);
      expect(r.liveMedianMicros, 2000);
      expect(r.limitMicros, 2000);
      expect(r.passed, isTrue);
    });

    test('fails one microsecond over', () {
      final r = measureLiveBudget(() {},
          now: scripted(stamps([10, 10, 10, 10, 10], [2001, 2001, 2001, 2001, 2001])));
      expect(r.passed, isFalse);
    });

    test('one slow outlier among five does not fail it (median)', () {
      final r = measureLiveBudget(() {},
          now: scripted(stamps([10, 10, 10, 10, 10], [100, 100, 100, 100, 99999])));
      expect(r.passed, isTrue);
    });

    test('three slow runs among five do fail it', () {
      final r = measureLiveBudget(() {},
          now: scripted(stamps([10, 10, 10, 10, 10], [100, 100, 9000, 9000, 9000])));
      expect(r.passed, isFalse);
    });

    test('the absolute cap beats a slow runner', () {
      final r = measureLiveBudget(() {},
          now: scripted(stamps([500, 500, 500, 500, 500], [8001, 8001, 8001, 8001, 8001])));
      expect(r.limitMicros, 8000);
      expect(r.passed, isFalse);
    });

    test('calls the function 10,000 times per run, 5 runs', () {
      var calls = 0;
      measureLiveBudget(() => calls++, now: scripted(List.generate(20, (i) => i)));
      expect(calls, kLiveCalls * kLiveRuns);
    });
  });

  group('real clock smoke', () {
    test('a trivial function is within budget', () {
      var acc = 0;
      expectLiveBudget(() => acc = (acc + 3) & 0xffff);
      expect(acc, isNonNegative);
    });

    test('a function doing ~5,000 adds per call is far over budget', () {
      var acc = 0;
      void slow() {
        for (var i = 0; i < 5000; i++) {
          acc += i;
        }
      }

      expect(() => expectLiveBudget(slow), throwsStateError);
      expect(acc, isNonZero);
    });
  });
}
