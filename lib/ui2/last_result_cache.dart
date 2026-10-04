// The last good result of a screen that computes on open, kept so the next open
// shows it at once (under an "As of" label) while the loader runs again in the
// background.
//
// Two layers. In front, a process-lifetime memory LRU of 32 entries, least
// recently used out first. Behind it, the `last_result` table, so the result
// survives a restart: a screen's first open after launch is the one that was a
// bare spinner. Only the REPOSITORY-level JSON maps the screens build from are
// written through — never a widget object — and the table keeps at most
// [maxRows] rows, oldest `computed_at` out first.
//
// An error is never stored, and a failed refresh leaves the earlier good entry
// in place — a stale result is labelled, a missing one would be a spinner. A
// store that cannot be read or written is a miss, never an exception: this
// cache only ever makes a screen faster. The fresh read never waits on the
// table.
import 'dart:async' show Completer, Zone;
import 'dart:collection';
import 'dart:convert';

import '../data/db.dart';

class CachedResult<T> {
  const CachedResult(this.value, this.cachedAt);
  final T value;

  /// When the value was computed and stored, not when it was read.
  final DateTime cachedAt;
}

class _Entry {
  _Entry(this.value, this.cachedAt, this.epoch);
  final Object? value;
  final DateTime cachedAt;

  /// [LocalDb.wipeEpoch] when it was taken; an older one is gone with the wipe.
  final int epoch;
}

class LastResultCache {
  LastResultCache(
      {this.capacity = 32, DateTime Function()? now, this.maxRows = 200})
      : _now = now ?? DateTime.now;

  /// What the screens use.
  static final LastResultCache instance = LastResultCache();

  final int capacity;

  /// The table's bound.
  final int maxRows;
  final DateTime Function() _now;

  // Insertion order is recency order: the first key is the oldest.
  final LinkedHashMap<String, _Entry> _m = LinkedHashMap<String, _Entry>();

  // Table writes run one after another, in the order they were asked for.
  Future<void> _tail = Future<void>.value();

  int get length => _m.length;

  static String keyOf(String screen, [List<Object?> args = const []]) =>
      [screen, ...args].join('|');

  /// Memory only. A hit becomes the most recent entry. A value of another type
  /// is a miss.
  CachedResult<T>? get<T>(String key) {
    final e = _m.remove(key);
    if (e == null) return null;
    if (e.epoch != LocalDb.wipeEpoch) return null;
    _m[key] = e;
    final v = e.value;
    return v is T ? CachedResult<T>(v, e.cachedAt) : null;
  }

  /// Memory first, then the table. A table hit is promoted into memory, so
  /// [get] answers for it afterwards.
  Future<CachedResult<T>?> read<T>(String key) async {
    final mem = get<T>(key);
    if (mem != null) return mem;
    final epoch = LocalDb.wipeEpoch;
    try {
      final row = await _run(() => LocalDb.lastResult(key));
      if (row == null || epoch != LocalDb.wipeEpoch) return null;
      final v = jsonDecode(row.payload);
      if (v is! T) return null;
      final at = DateTime.fromMillisecondsSinceEpoch(row.computedAt);
      // A newer result put while the table was read stays.
      if (!_m.containsKey(key)) _store(key, v, at, epoch);
      return CachedResult<T>(v, at);
    } catch (_) {
      return null; // unreadable or corrupt: a miss
    }
  }

  void put<T>(String key, T value) {
    final at = _now();
    _store(key, value, at, LocalDb.wipeEpoch);
    final json = _encode(value);
    if (json == null) return;
    _enqueue(() => LocalDb.putLastResult(
        key, at.millisecondsSinceEpoch, json, maxRows));
  }

  void _store(String key, Object? value, DateTime at, int epoch) {
    _m.remove(key);
    _m[key] = _Entry(value, at, epoch);
    while (_m.length > capacity) {
      _m.remove(_m.keys.first);
    }
  }

  /// A Map the table can hold, or null (anything else stays in memory only).
  static String? _encode(Object? value) {
    if (value is! Map) return null;
    try {
      return jsonEncode(value);
    } catch (_) {
      return null;
    }
  }

  // Table I/O is one queue, reads included: two first opens of the database at
  // once would hold two connections to one file. It runs in the root zone, so
  // what follows it does not depend on the caller's zone (a widget test's
  // fake-async microtasks do not turn while real I/O is awaited, and a flush
  // would wait on them forever).
  void _enqueue(Future<void> Function() op) {
    _tail = Zone.root.run(() => _tail.then((_) async {
          try {
            await op();
          } catch (_) {
            // Memory still has it; the table is a bonus.
          }
        }));
  }

  /// [op] in the queue; null when it fails.
  Future<R?> _run<R>(Future<R> Function() op) {
    final done = Completer<R?>();
    _enqueue(() async {
      try {
        done.complete(await op());
      } catch (_) {
        done.complete(null);
      }
    });
    return done.future;
  }

  /// Every write-through asked for so far has landed (or failed quietly).
  Future<void> flush() async {
    Future<void> t;
    do {
      t = _tail;
      await t;
    } while (!identical(t, _tail));
  }

  /// Runs [loader]; only a normal return is stored, and it returns once the
  /// table has it. An error propagates.
  Future<T> load<T>(String key, Future<T> Function() loader) async {
    final v = await loader();
    put<T>(key, v);
    await flush();
    return v;
  }

  /// What a screen opens with: [loader] starts at once, and while it runs
  /// [onLast] is handed the last stored result for [key] (memory in the same
  /// frame, the table a moment later) unless the fresh one has already landed.
  /// The fresh result is stored without waiting for the table. An error from
  /// [loader] propagates and stores nothing. [onLast] runs where the caller
  /// must check it is still mounted.
  Future<T> loadShowingLast<T>(
    String key,
    Future<T> Function() loader, {
    required void Function(CachedResult<T> last) onLast,
  }) async {
    var landed = false;
    final fresh = loader();
    final mem = get<T>(key);
    if (mem != null) {
      onLast(mem);
    } else {
      read<T>(key).then((hit) {
        if (hit != null && !landed) onLast(hit);
      });
    }
    final v = await fresh;
    landed = true;
    put<T>(key, v);
    return v;
  }

  /// A restart: the memory is gone, the table is not.
  void clearMemory() => _m.clear();

  /// Memory and table.
  Future<void> clear() {
    _m.clear();
    _enqueue(LocalDb.clearLastResults);
    return flush();
  }
}
