/// The window picker the cadence rigs share: the [spanSec] window of a 1 Hz
/// record with the lowest (or highest) mean valid HR. Physiologically the
/// lowest is the night, and it needs no timezone, no staging and no threshold.
///
/// [recTs] and [hr] are parallel, ordered by time. Returns `(start, end)` in
/// epoch seconds, `end` exclusive.
(int, int) extremeHrWindow(List<int> recTs, List<int> hr, int spanSec,
    {required bool lowest}) {
  final t0 = recTs.first, t1 = recTs.last;
  final n = t1 - t0 + 1;
  // Second-indexed prefix sums so every candidate window is O(1).
  final sum = List<double>.filled(n + 1, 0);
  final cnt = List<int>.filled(n + 1, 0);
  final hrAt = List<double>.filled(n, 0);
  for (var i = 0; i < recTs.length; i++) {
    if (hr[i] > 0) hrAt[recTs[i] - t0] = hr[i].toDouble();
  }
  for (var i = 0; i < n; i++) {
    sum[i + 1] = sum[i] + hrAt[i];
    cnt[i + 1] = cnt[i] + (hrAt[i] > 0 ? 1 : 0);
  }
  var bestStart = t0;
  double? bestMean;
  // 10-min steps: fine enough to land on the night, coarse enough to be free.
  for (var s = 0; s + spanSec <= n; s += 600) {
    final c = cnt[s + spanSec] - cnt[s];
    // Demand real coverage — an empty window has a mean of nothing, and a
    // sparsely-covered one is not the window we mean by "the night".
    if (c < spanSec * 0.8) continue;
    final m = (sum[s + spanSec] - sum[s]) / c;
    if (bestMean == null || (lowest ? m < bestMean : m > bestMean)) {
      bestMean = m;
      bestStart = t0 + s;
    }
  }
  return (bestStart, bestStart + spanSec);
}
