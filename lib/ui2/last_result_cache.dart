// The last good result of a screen that computes on open, kept in memory so the
// next open shows it at once (under an "As of" label) while the loader runs
// again in the background.
//
// Bounded and process-lifetime: 32 entries, least recently used out first. An
// error is never stored, and a failed refresh leaves the earlier good entry in
// place — a stale result is labelled, a missing one would be a spinner.
import 'dart:collection';

class CachedResult<T> {
  const CachedResult(this.value, this.cachedAt);
  final T value;

  /// When the value was computed and stored, not when it was read.
  final DateTime cachedAt;
}

class LastResultCache {
  LastResultCache({this.capacity = 32, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  /// What the screens use.
  static final LastResultCache instance = LastResultCache();

  final int capacity;
  final DateTime Function() _now;

  // Insertion order is recency order: the first key is the oldest.
  final LinkedHashMap<String, CachedResult<Object?>> _m =
      LinkedHashMap<String, CachedResult<Object?>>();

  int get length => _m.length;

  static String keyOf(String screen, [List<Object?> args = const []]) =>
      [screen, ...args].join('|');

  /// A hit becomes the most recent entry. A value of another type is a miss.
  CachedResult<T>? get<T>(String key) {
    final e = _m.remove(key);
    if (e == null) return null;
    _m[key] = e;
    final v = e.value;
    return v is T ? CachedResult<T>(v, e.cachedAt) : null;
  }

  void put<T>(String key, T value) {
    _m.remove(key);
    _m[key] = CachedResult<Object?>(value, _now());
    while (_m.length > capacity) {
      _m.remove(_m.keys.first);
    }
  }

  /// Runs [loader]; only a normal return is stored. An error propagates.
  Future<T> load<T>(String key, Future<T> Function() loader) async {
    final v = await loader();
    put<T>(key, v);
    return v;
  }

  void clear() => _m.clear();
}
