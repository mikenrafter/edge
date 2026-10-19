import 'dart:collection';
import 'dart:typed_data';

// Compact stand-ins for sample copies the incremental day state used to keep
// only to answer "is this still the same data?". A 128-bit fingerprint answers
// it in 16 bytes. A false "same" needs a collision in both lanes (about 2^-128
// for unrelated data); a false "different" only costs a recompute, so every
// difference the old exact comparison saw is still seen, and numbers equal under
// `==` (0.0 and -0.0, any two NaNs) fingerprint alike, as they compared alike.

final ByteData _scratch = ByteData(8);

/// Raw bits of [x], with the values `==` cannot tell apart folded together.
int _doubleBits(double x) {
  if (x.isNaN) return 0x7ff8000000000000;
  if (x == 0) return 0;
  _scratch.setFloat64(0, x);
  return _scratch.getInt64(0);
}

/// splitmix64 finalizer.
int _mix(int z) {
  z = (z ^ (z >>> 30)) * 0xbf58476d1ce4e5b9;
  z = (z ^ (z >>> 27)) * 0x94d049bb133111eb;
  return z ^ (z >>> 31);
}

/// Order-sensitive 128-bit running fingerprint of a number sequence.
class PrefixFingerprint {
  int _a = 0x243f6a8885a308d3, _b = 0x13198a2e03707344;

  PrefixFingerprint();

  /// A fingerprint resumed from [words] of an earlier one.
  PrefixFingerprint.fromWords(int a, int b)
      : _a = a,
        _b = b;

  /// The two 64-bit lanes, for storing the fingerprint and resuming it.
  (int, int) get words => (_a, _b);

  void addInt(int v) {
    _a = _mix(_a + v + 0x9e3779b97f4a7c15);
    _b = _mix((_b ^ v) * 0xd6e8feb86659fd93 + 0x632be59bd9b4e019);
  }

  void addDouble(double v) => addInt(_doubleBits(v));

  bool matches(PrefixFingerprint other) => _a == other._a && _b == other._b;

  void copyFrom(PrefixFingerprint other) {
    _a = other._a;
    _b = other._b;
  }

  void clear() => copyFrom(PrefixFingerprint());
}

/// Lists at least this long are digested on their own (see [ListDigestCache]).
const int kListDigestMin = 64;

/// Digests of long `List<double>` dependencies, keyed by list IDENTITY, so a
/// list that many memos name in one pass is walked once. Valid for one pass:
/// [clear] it at the start of each, since a list may be mutated between passes.
/// An entry also records the length, so a list that grew in place re-digests.
class ListDigestCache {
  final HashMap<List<double>, (int, int, int)> _byList =
      HashMap.identity();

  /// Full-list digests computed (cache misses), cumulative.
  int computed = 0;

  void clear() => _byList.clear();

  (int, int) digest(List<double> list) {
    final hit = _byList[list];
    if (hit != null && hit.$1 == list.length) return (hit.$2, hit.$3);
    final fp = PrefixFingerprint();
    for (var i = 0; i < list.length; i++) {
      fp.addDouble(list[i]);
    }
    computed++;
    final w = fp.words;
    _byList[list] = (list.length, w.$1, w.$2);
    return w;
  }
}

/// What [CalculationCache] compares in place of a full dependency snapshot.
///
/// Two dependency values give equal fingerprints only when they have the same
/// shape and the same numbers, strings and flags, with map entries taken in any
/// order. Objects of any other type are kept as they are (compared with `==`,
/// by the cache), so an unfamiliar type can only cost memory, never a wrong hit.
/// A long `List<double>` is digested as its own 128-bit fingerprint (through
/// [cache] when given, with or without it the same value).
List<Object?> dependencyFingerprint(Object? dependencies,
    {ListDigestCache? cache}) {
  final fp = PrefixFingerprint();
  final opaque = <Object?>[];
  _add(fp, dependencies, opaque, cache ?? _scratchCache);
  final out = PrefixFingerprint()..copyFrom(fp);
  return [out._a, out._b, ...opaque];
}

final ListDigestCache _scratchCache = ListDigestCache();

void _add(PrefixFingerprint fp, Object? v, List<Object?> opaque,
    ListDigestCache cache) {
  if (v == null) {
    fp.addInt(1);
  } else if (v is bool) {
    fp.addInt(v ? 3 : 2);
  } else if (v is int) {
    fp.addInt(4);
    fp.addInt(v);
  } else if (v is double) {
    fp.addInt(5);
    fp.addDouble(v);
  } else if (v is String) {
    fp.addInt(6);
    fp.addInt(v.length);
    for (var i = 0; i < v.length; i++) {
      fp.addInt(v.codeUnitAt(i));
    }
  } else if (v is List<double> && v.length >= kListDigestMin) {
    // Same shape tag and length as the generic branch, then the list's digest.
    fp.addInt(11);
    fp.addInt(v.length);
    final d = cache.digest(v);
    fp.addInt(d.$1);
    fp.addInt(d.$2);
    if (identical(cache, _scratchCache)) cache.clear();
  } else if (v is List) {
    fp.addInt(7);
    fp.addInt(v.length);
    for (final item in v) {
      _add(fp, item, opaque, cache);
    }
  } else if (v is Map) {
    // Entry order must not matter, so each entry is fingerprinted alone and
    // the results are summed.
    fp.addInt(8);
    fp.addInt(v.length);
    var sumA = 0, sumB = 0;
    for (final e in v.entries) {
      final one = PrefixFingerprint();
      _add(one, e.key, opaque, cache);
      _add(one, e.value, opaque, cache);
      sumA += one._a;
      sumB += one._b;
    }
    fp.addInt(sumA);
    fp.addInt(sumB);
  } else {
    fp.addInt(10);
    opaque.add(v);
  }
}
