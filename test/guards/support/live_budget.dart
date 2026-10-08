// live_budget.dart — the @live budget (design 02, rev 5): a calibrated bound
// rather than a fixed wall-clock number.
//
//   reference = median of 5 runs of a loop of 10,000 integer adds, timed on
//               THIS runner;
//   live      = median of 5 runs of 10,000 calls of the @live function on fixed
//               input;
//   pass iff  live <= min(200 x reference, 8 ms).
//
// A frame is 16 ms and a live tick handles at most ~50 packets/s, so 8 ms per
// 10,000 calls is generous; the 200x factor keeps slow CI runners honest. A
// flaky budget is a bug to investigate, never retry-to-green. Device-side
// budgets are a release-checklist item (documented separately).
//
// Time here is a monotonic Stopwatch over fixed input, never a date. Both the
// reference loop and the live function get an un-timed warm-up first.

import 'dart:math' as math;

const int kLiveCalls = 10000;
const int kLiveRuns = 5;
const int kLiveReferenceFactor = 200;
const int kLiveCapMicros = 8000;

/// Microseconds source; injectable so the median / decision logic is tested
/// deterministically.
typedef MicrosClock = int Function();

class LiveBudgetResult {
  final int referenceMedianMicros;
  final int liveMedianMicros;
  final int limitMicros;
  const LiveBudgetResult({
    required this.referenceMedianMicros,
    required this.liveMedianMicros,
    required this.limitMicros,
  });
  bool get passed => liveMedianMicros <= limitMicros;

  @override
  String toString() =>
      'live median ${liveMedianMicros}us vs limit ${limitMicros}us '
      '(reference ${referenceMedianMicros}us x $kLiveReferenceFactor, '
      'cap ${kLiveCapMicros}us)';
}

/// The pass limit for a measured [referenceMedianMicros].
///
/// A reference that rounds to 0 us (coarse clock) counts as 1 us, so the limit
/// is never 0.
int liveLimitMicros(int referenceMedianMicros) => math.min(
      math.max(1, referenceMedianMicros) * kLiveReferenceFactor,
      kLiveCapMicros,
    );

int medianOf(List<int> xs) {
  final s = List<int>.of(xs)..sort();
  return s[s.length ~/ 2];
}

int _timeRuns(MicrosClock now, void Function() body) {
  final runs = <int>[];
  for (var r = 0; r < kLiveRuns; r++) {
    final t0 = now();
    body();
    runs.add(now() - t0);
  }
  return medianOf(runs);
}

int _sink = 0; // keeps the reference loop from being optimised away

/// Un-timed passes before measuring, so the first (cold JIT) run does not
/// inflate the reference (observed 184 us cold vs ~8 us warm) or the live
/// median. Skipped when a scripted clock is injected, so scripted tests see
/// exactly the clock reads they expect.
const int kLiveWarmupRuns = 2;

/// Measures [liveCall] (a closure over FIXED input) against the reference loop.
LiveBudgetResult measureLiveBudget(void Function() liveCall, {MicrosClock? now}) {
  final clock = now ?? _stopwatchMicros();
  if (now == null) {
    for (var w = 0; w < kLiveWarmupRuns; w++) {
      _timeRuns(clock, () {
        var acc = 0;
        for (var i = 0; i < kLiveCalls; i++) {
          acc += i;
        }
        _sink ^= acc;
      });
      _timeRuns(clock, () {
        for (var i = 0; i < kLiveCalls; i++) {
          liveCall();
        }
      });
    }
  }
  final ref = _timeRuns(clock, () {
    var acc = 0;
    for (var i = 0; i < kLiveCalls; i++) {
      acc += i;
    }
    _sink ^= acc;
  });
  final live = _timeRuns(clock, () {
    for (var i = 0; i < kLiveCalls; i++) {
      liveCall();
    }
  });
  return LiveBudgetResult(
    referenceMedianMicros: ref,
    liveMedianMicros: live,
    limitMicros: liveLimitMicros(ref),
  );
}

MicrosClock _stopwatchMicros() {
  final sw = Stopwatch()..start();
  return () => sw.elapsedMicroseconds;
}

/// Throws if [liveCall] is over budget. Use from each `@live` function's test.
void expectLiveBudget(void Function() liveCall) {
  final r = measureLiveBudget(liveCall);
  if (!r.passed) {
    throw StateError('@live budget exceeded: $r');
  }
}

/// Exposed for the reference loop's side effect so the analyzer sees it used.
int get liveBudgetSink => _sink;
