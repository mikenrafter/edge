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
// An entry may carry the signature of the inputs it was computed from
// (`input_sig`). [loadArtifact] treats an entry whose signature still equals the
// current one as FRESH: shown as is, never recomputed on open. A missing
// signature (an old row, a put that gave none) is never fresh.
//
// An error is never stored, and a failed refresh leaves the earlier good entry
// in place — a stale result is labelled, a missing one would be a spinner. A
// store that cannot be read or written is a miss, never an exception: this
// cache only ever makes a screen faster. The fresh read never waits on the
// table.
import 'dart:async' show Completer, Zone;
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../compute/derive_perf.dart' show ReadPerf;
import '../data/db.dart';

class CachedResult<T> {
  const CachedResult(this.value, this.cachedAt, {this.sig});
  final T value;

  /// When the value was computed and stored, not when it was read.
  final DateTime cachedAt;

  /// The signature of the inputs it was computed from; null when none was kept.
  final String? sig;
}

class _Entry {
  _Entry(this.value, this.cachedAt, this.generation, this.sig);
  final Object? value;
  final DateTime cachedAt;
  final String? sig;

  /// Store identity when it was taken; a replacement invalidates the entry.
  /// Mutable for exactly one reason: a put made while the store was closed is
  /// restamped once its own write-through has opened the store (see [put]).
  ({int wipeEpoch, int openCount}) generation;
}

/// Tests only: a point in a put's write-through where a test can stand still.
/// An interface method, not a function-typed field, so the heavy-calc guard
/// resolves the call instead of counting an unresolved invocation.
@visibleForTesting
abstract class WriteThroughGate {
  Future<void> beforeWriteThrough();
}

class LastResultCache {
  LastResultCache(
      {this.capacity = 32, DateTime Function()? now, this.maxRows = 200})
      : _now = now ?? DateTime.now;

  /// What the screens use.
  static final LastResultCache instance = LastResultCache();

  final int capacity;

  /// Tests only: awaited at the start of every put's write-through, before the
  /// store is touched. Null in production.
  @visibleForTesting
  static WriteThroughGate? debugWriteThroughGate;

  /// The table's bound.
  final int maxRows;
  DateTime Function() _now;

  /// Tests only: the clock puts are stamped with. Null is the system clock.
  @visibleForTesting
  set clock(DateTime Function()? now) => _now = now ?? DateTime.now;

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
    if (e.generation != LocalDb.storeGeneration) return null;
    _m[key] = e;
    final v = e.value;
    return v is T ? CachedResult<T>(v, e.cachedAt, sig: e.sig) : null;
  }

  /// Memory first, then the table. A table hit is promoted into memory, so
  /// [get] answers for it afterwards.
  Future<CachedResult<T>?> read<T>(String key) async {
    final mem = get<T>(key);
    if (mem != null) return mem;
    // The generation is taken INSIDE the queued read, after the store is open.
    // Taken before, a closed store's read opened it, moved the generation, and
    // the fence below then threw away the row it had just read.
    ({int wipeEpoch, int openCount})? taken;
    try {
      final row = await _run(() async {
        await LocalDb.instance;
        taken = LocalDb.storeGeneration;
        return LocalDb.lastResult(key);
      });
      final generation = taken;
      if (row == null ||
          generation == null ||
          generation != LocalDb.storeGeneration) {
        return null;
      }
      final v = jsonDecode(row.payload);
      if (v is! T) return null;
      ReadPerf.lastResultRead(key, row.payload, v);
      final at = DateTime.fromMillisecondsSinceEpoch(row.computedAt);
      // A newer result put while the table was read stays.
      if (!_m.containsKey(key)) _store(key, v, at, generation, row.sig);
      return CachedResult<T>(v, at, sig: row.sig);
    } catch (_) {
      return null; // unreadable or corrupt: a miss
    }
  }

  /// [sig] is the signature of the inputs [value] was computed from, kept with
  /// it in memory and in the table (NULL when omitted).
  void put<T>(String key, T value, {String? sig}) {
    final at = _now();
    final putGeneration = LocalDb.storeGeneration;
    // Only a put made while the store was CLOSED can be waiting for its first
    // open. On an open store the stamp is already the real generation, and any
    // later change to it is a reopen or a replacement, never a catch-up.
    final storeWasClosed = !LocalDb.isStoreOpen;
    final entry = _store(key, value, at, putGeneration, sig);
    final json = _encode(value);
    if (json == null) return;
    ReadPerf.lastResultPut(key, json);
    _enqueue(() async {
      await debugWriteThroughGate?.beforeWriteThrough();
      // Opens the store if the put came first. That open moves the generation,
      // and it is the only thing allowed to: see the restamp below.
      await LocalDb.instance;
      final opened = LocalDb.storeGeneration;
      await LocalDb.putLastResult(key, at.millisecondsSinceEpoch, json, maxRows,
          sig: sig);
      // Bind the entry to the generation this SUCCESSFUL write-through used,
      // when (and only when) it is the generation right after the put's own
      // open, nothing replaced the store while it wrote, and the entry is still
      // this put's (a newer put for the key keeps its own stamp and value). A
      // wipe, merge, rebuild or reopen that crossed the write leaves the old
      // stamp, so the entry misses. An unconditional restamp would revive it.
      if (storeWasClosed &&
          putGeneration != opened &&
          opened == LocalDb.generationAfterFirstOpen(putGeneration) &&
          LocalDb.storeGeneration == opened &&
          identical(_m[key], entry)) {
        entry.generation = opened;
      }
    });
  }

  _Entry _store(
    String key,
    Object? value,
    DateTime at,
    ({int wipeEpoch, int openCount}) generation,
    String? sig,
  ) {
    _m.remove(key);
    final entry = _m[key] = _Entry(value, at, generation, sig);
    while (_m.length > capacity) {
      _m.remove(_m.keys.first);
    }
    return entry;
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

  /// What a screen with no business computing in its build path opens with:
  /// the artifact [key] FRESH from the store (same rule as [loadArtifact]: its
  /// signature equals a non-null current one), else [warm] is awaited, which is
  /// the request to the one background warmer, and the store is read again. A
  /// stale stored entry goes to [onLast] first. Returns null when the warm did
  /// not leave a fresh entry (held, failed, nothing to sign): the caller keeps
  /// its loading state and asks again on its next read. Nothing is computed
  /// here and nothing is stored here; [onLast] runs where the caller must check
  /// it is still mounted.
  Future<T?> loadWarmed<T>(
    String key, {
    required Future<String?> Function() signature,
    required Future<void> Function() warm,
    required void Function(CachedResult<T> last) onLast,
  }) async {
    String? current;
    try {
      current = await signature();
    } catch (_) {
      current = null;
    }
    final stored = await read<T>(key);
    if (stored != null) {
      if (current != null && stored.sig == current) return stored.value;
      onLast(stored);
    }
    try {
      await warm();
    } catch (_) {
      return null;
    }
    final landed = await read<T>(key);
    return landed != null && current != null && landed.sig == current
        ? landed.value
        : null;
  }

  /// What an artifact screen opens with. [signature] is asked ONCE, before
  /// anything else, so a result whose inputs move while it is being computed is
  /// stored under the older signature and reads stale next time; an error from
  /// it is a null signature. The stored entry (memory, then the table) is FRESH
  /// when it exists and its signature equals a non-null current one: its value
  /// is returned, [loader] and [onLast] never run and nothing is rewritten.
  /// Otherwise a stored entry goes to [onLast], [loader] runs once and its value
  /// is stored under the current signature. An error from [loader] propagates
  /// and stores nothing; the earlier entry stays. [onLast] runs where the caller
  /// must check it is still mounted.
  Future<T> loadArtifact<T>(
    String key,
    Future<T> Function() loader, {
    required Future<String?> Function() signature,
    required void Function(CachedResult<T> last) onLast,
  }) async {
    String? current;
    try {
      current = await signature();
    } catch (_) {
      current = null;
    }
    final stored = await read<T>(key);
    if (stored != null) {
      if (current != null && stored.sig == current) return stored.value;
      onLast(stored);
    }
    final v = await loader();
    put<T>(key, v, sig: current);
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
