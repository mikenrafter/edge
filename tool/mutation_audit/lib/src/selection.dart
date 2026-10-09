import 'mutant.dart';

/// Chooses which of [mutants] (already in generator order) to run.
///
/// - [sample] (needs [seed], else [ArgumentError]): that many mutants drawn
///   uniformly without replacement by a seeded PRNG implemented in this
///   package (so a seed means the same draw on every Dart version), returned in
///   the original order. Asking for more than exist returns all of them.
/// - [maxMutants]: afterwards, at most that many, the first ones in order.
/// - Neither: all of them. Negative numbers are an [ArgumentError].
List<Mutant> selectMutants(
  List<Mutant> mutants, {
  int? maxMutants,
  int? sample,
  int? seed,
}) {
  if (maxMutants != null && maxMutants < 0) {
    throw ArgumentError.value(maxMutants, 'maxMutants', 'must not be negative');
  }
  if (sample != null) {
    if (sample < 0) throw ArgumentError.value(sample, 'sample', 'must not be negative');
    if (seed == null) throw ArgumentError.value(sample, 'sample', 'needs a seed');
  }
  var chosen = List<Mutant>.of(mutants);
  if (sample != null && sample < chosen.length) {
    // Partial Fisher-Yates over the indices, then back to the original order.
    final rng = _SplitMix64(seed!);
    final n = chosen.length;
    final indices = List<int>.generate(n, (i) => i);
    for (var i = 0; i < sample; i++) {
      final j = i + rng.below(n - i);
      final t = indices[i];
      indices[i] = indices[j];
      indices[j] = t;
    }
    final picked = indices.sublist(0, sample)..sort();
    chosen = [for (final i in picked) mutants[i]];
  }
  if (maxMutants != null && maxMutants < chosen.length) {
    chosen = chosen.sublist(0, maxMutants);
  }
  return chosen;
}

/// SplitMix64: a fixed, well-known generator, so a seed names the same draw on
/// every Dart version (`Random(seed)` makes no such promise).
class _SplitMix64 {
  _SplitMix64(this._state);
  int _state;

  int _next() {
    _state += 0x9E3779B97F4A7C15;
    var z = _state;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    return z ^ (z >>> 31);
  }

  /// Uniform-enough integer in [0, bound).
  int below(int bound) => (_next() >>> 1) % bound;
}
