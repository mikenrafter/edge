// LastResultCache — the last good result of a computed-on-open
// screen, kept in memory so a re-open shows it at once (with "As of") while the
// loader recomputes in the background.
//
// API (lib/ui2/last_result_cache.dart, new, pure Dart):
//
//   class CachedResult<T> {
//     final T value;
//     final DateTime cachedAt;           // when the value was computed/stored
//   }
//
//   class LastResultCache {
//     LastResultCache({int capacity = 32, DateTime Function()? now});
//     static final LastResultCache instance;      // process lifetime, what the
//                                                 // screens use
//     CachedResult<T>? get<T>(String key);        // a hit becomes most-recent;
//                                                 // wrong type -> null
//     void put<T>(String key, T value);           // stamps cachedAt = now()
//     Future<T> load<T>(String key, Future<T> Function() loader);
//                                                 // runs loader; ONLY a normal
//                                                 // return is stored; an error
//                                                 // propagates and stores
//                                                 // nothing (and keeps any
//                                                 // earlier good entry)
//     int get length;
//     void clear();
//     static String keyOf(String screen, [List<Object?> args = const []]);
//                                                 // 'screen|a|b'; stable and
//                                                 // distinct per args
//   }
//
// The screens key as: keyOf('beats', [day]), keyOf('metric_insights', [metric]),
// keyOf('wellness_insights'), keyOf('workout', [sessionId]).

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ui2/last_result_cache.dart';

void main() {
  test('a miss is null', () {
    expect(LastResultCache().get<int>('a'), isNull);
  });

  test('put then get returns the value and the time it was stored', () {
    var t = DateTime(2026, 10, 3, 8, 42);
    final c = LastResultCache(now: () => t);
    c.put<int>('a', 7);
    t = DateTime(2026, 10, 3, 9, 0);
    final hit = c.get<int>('a')!;
    expect(hit.value, 7);
    expect(hit.cachedAt, DateTime(2026, 10, 3, 8, 42),
        reason: 'cachedAt is when it was computed, not when it was read');
  });

  test('put replaces and re-stamps', () {
    var t = DateTime(2026, 10, 3, 8, 0);
    final c = LastResultCache(now: () => t);
    c.put<int>('a', 1);
    t = DateTime(2026, 10, 3, 8, 30);
    c.put<int>('a', 2);
    expect(c.get<int>('a')!.value, 2);
    expect(c.get<int>('a')!.cachedAt, DateTime(2026, 10, 3, 8, 30));
    expect(c.length, 1);
  });

  test('bounded: the default capacity is 32 and the oldest entry goes', () {
    final c = LastResultCache();
    for (var i = 0; i < 40; i++) {
      c.put<int>('k$i', i);
    }
    expect(c.length, 32);
    for (var i = 0; i < 8; i++) {
      expect(c.get<int>('k$i'), isNull, reason: 'k$i is the oldest');
    }
    for (var i = 8; i < 40; i++) {
      expect(c.get<int>('k$i')!.value, i);
    }
  });

  test('LRU, not FIFO: a read protects an entry from eviction', () {
    final c = LastResultCache(capacity: 3);
    c.put<int>('a', 1);
    c.put<int>('b', 2);
    c.put<int>('c', 3);
    expect(c.get<int>('a')!.value, 1); // a is now most recent
    c.put<int>('d', 4); // evicts b
    expect(c.get<int>('b'), isNull);
    expect(c.get<int>('a')!.value, 1);
    expect(c.get<int>('c')!.value, 3);
    expect(c.get<int>('d')!.value, 4);
  });

  test('a wrong-typed read is a miss, not a cast error', () {
    final c = LastResultCache();
    c.put<int>('a', 1);
    expect(c.get<String>('a'), isNull);
  });

  test('keyOf is distinct per screen and per args', () {
    final k = LastResultCache.keyOf;
    expect(k('beats', ['2026-10-03']), isNot(k('beats', ['2026-10-02'])));
    expect(k('beats', ['x']), isNot(k('metric_insights', ['x'])));
    expect(k('beats', ['x']), k('beats', ['x']));
    expect(k('wellness_insights'), k('wellness_insights'));
  });

  group('load', () {
    test('a successful load is returned and cached', () async {
      final c = LastResultCache();
      expect(await c.load<int>('a', () async => 5), 5);
      expect(c.get<int>('a')!.value, 5);
    });

    test('an error is rethrown and NEVER cached', () async {
      final c = LastResultCache();
      await expectLater(
        c.load<int>('a', () async => throw StateError('nope')),
        throwsStateError,
      );
      expect(c.get<int>('a'), isNull);
      expect(c.length, 0);
    });

    test('a failed refresh keeps the earlier good result', () async {
      final c = LastResultCache();
      await c.load<int>('a', () async => 1);
      await expectLater(
        c.load<int>('a', () async => throw StateError('nope')),
        throwsStateError,
      );
      expect(c.get<int>('a')!.value, 1);
    });

    test('a later success replaces the entry', () async {
      final c = LastResultCache();
      await c.load<int>('a', () async => 1);
      await c.load<int>('a', () async => 2);
      expect(c.get<int>('a')!.value, 2);
    });
  });

  group('loadWarmed', () {
    Future<T?> run<T>(LastResultCache c,
            {String? sig = 's1',
            required Future<void> Function() warm,
            void Function(CachedResult<T>)? onLast}) =>
        c.loadWarmed<T>('a',
            signature: () async => sig, warm: warm, onLast: onLast ?? (_) {});

    test('a fresh stored entry is returned and nothing is warmed', () async {
      final c = LastResultCache();
      c.put<int>('a', 1, sig: 's1');
      var warmed = false;
      expect(await run<int>(c, warm: () async => warmed = true), 1);
      expect(warmed, isFalse);
    });

    test('a miss asks for the warm, then returns what it stored', () async {
      final c = LastResultCache();
      expect(await run<int>(c, warm: () async => c.put<int>('a', 7, sig: 's1')),
          7);
    });

    test('a warm that stores nothing (held, failed) is null, not a made-up '
        'value', () async {
      final c = LastResultCache();
      expect(await run<int>(c, warm: () async {}), isNull);
      expect(await run<int>(c, warm: () async => throw StateError('x')),
          isNull);
    });

    test('a stale entry goes to onLast and is never returned as fresh',
        () async {
      final c = LastResultCache();
      c.put<int>('a', 1, sig: 'old');
      final seen = <int>[];
      expect(await run<int>(c, warm: () async {}, onLast: (h) => seen.add(h.value)),
          isNull);
      expect(seen, [1]);
    });

    test('no current signature: never fresh, never returned', () async {
      final c = LastResultCache();
      c.put<int>('a', 1, sig: 's1');
      expect(await run<int>(c, sig: null, warm: () async {}), isNull);
    });
  });

  test('clear empties it', () {
    final c = LastResultCache();
    c.put<int>('a', 1);
    c.clear();
    expect(c.length, 0);
    expect(c.get<int>('a'), isNull);
  });

  test('the process-wide instance is a singleton', () {
    expect(identical(LastResultCache.instance, LastResultCache.instance), isTrue);
  });
}
