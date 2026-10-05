// 8AI G1 (red first): LastResultCache is memory (LRU 32) IN FRONT OF the
// `last_result` table, so the last good result of a slow read survives a
// restart (the 8AG-P1b cache was memory only and was lost on every launch).
//
// ASSUMED API (lib/ui2/last_result_cache.dart; everything not listed is as
// today, test/calc_last_result_cache_test.dart keeps its meaning):
//
//   LastResultCache({int capacity = 32, DateTime Function()? now,
//                    int maxRows = 200});      // maxRows: table bound; ~200
//   Future<CachedResult<T>?> read<T>(String key);
//        // memory first, then the table; a table hit is promoted into memory,
//        // so the synchronous get<T>(key) answers afterwards. A value of
//        // another type is null.
//   CachedResult<T>? get<T>(String key);       // unchanged: memory only
//   void put<T>(String key, T value);          // unchanged, plus a
//        // fire-and-forget write-through when [value] is a JSON-encodable Map
//        // (the repository-level maps the screens build from). A value that
//        // cannot be encoded stays in memory only and NEVER throws.
//   Future<T> load<T>(String key, Future<T> Function() loader);
//        // unchanged contract (only a normal return is stored, an error
//        // propagates and keeps the earlier good entry), and it AWAITS the
//        // write-through before it returns.
//   Future<void> flush();                      // pending write-throughs landed
//   void clearMemory();                        // a simulated restart
//   Future<void> clear();                      // memory AND table
//
// computed_at in the table is the cache clock at the moment the loader
// returned: when the stored result was computed, NEVER the time it is read
// back. The restored `cachedAt` is that stamp.
//
// A "restart" in these tests is a NEW LastResultCache over the same LocalDb
// (the memory is gone, the file is not).
//
// Failure mode today: `read`, `flush`, `clearMemory` and the `maxRows` named
// argument do not exist (compile errors), and the table does not exist.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';

import 'support/last_result_db.dart';

const _db = 'openstrap_fix8ai_g1_cache.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => g1FreshDb(_db));
  tearDownAll(() => g1DropDb(_db));

  final computed = DateTime(2026, 10, 3, 8, 42);
  const insights = {
    'insights': [
      {'outcome': 'rhr', 'delta': -1.5, 'n': 12, 'binary': false},
    ],
    'range': '90d',
    'note': null,
  };

  test('load writes through; a new cache over the same db restores it with '
      'the time it was COMPUTED', () async {
    var now = computed;
    final c1 = LastResultCache(now: () => now);
    await c1.load<Map<String, dynamic>>(
        'metric_insights|resting_hr', () async => {...insights});

    now = DateTime(2026, 10, 4, 19, 5); // a day later: the restart
    final c2 = LastResultCache(now: () => now);
    expect(c2.get<Map<String, dynamic>>('metric_insights|resting_hr'), isNull,
        reason: 'memory of the new process is empty');
    final hit = await c2.read<Map<String, dynamic>>('metric_insights|resting_hr');
    expect(hit, isNotNull, reason: 'the table answered');
    expect(hit!.value, insights, reason: 'JSON round trip, nested lists, '
        'ints, doubles, bools and null intact');
    expect(hit.cachedAt, computed,
        reason: 'computed_at is when it was computed, not when it was read');
  });

  test('the table row: key, epoch-ms computed_at, the JSON payload', () async {
    final c = LastResultCache(now: () => computed);
    await c.load<Map<String, dynamic>>('beats|2026-10-02', () async => {'a': 1});
    final rows = await g1LastResultRows();
    expect(rows, hasLength(1));
    expect(rows.single['key'], 'beats|2026-10-02');
    expect(rows.single['computed_at'], computed.millisecondsSinceEpoch);
    expect(jsonDecode(rows.single['payload_json'] as String), {'a': 1});
  });

  test('a table hit is promoted: the synchronous get answers afterwards',
      () async {
    final c1 = LastResultCache(now: () => computed);
    await c1.load<Map<String, dynamic>>('k', () async => {'v': 1});
    final c2 = LastResultCache();
    await c2.read<Map<String, dynamic>>('k');
    expect(c2.get<Map<String, dynamic>>('k')?.value, {'v': 1});
  });

  test('a miss is null, and so is a value of another type', () async {
    final c = LastResultCache();
    expect(await c.read<Map<String, dynamic>>('nope'), isNull);
    await c.load<Map<String, dynamic>>('k', () async => {'v': 1});
    final c2 = LastResultCache();
    expect(await c2.read<List<Object?>>('k'), isNull,
        reason: 'stored a Map, asked for a List');
  });

  test('a fresh result replaces the stored one and re-stamps it', () async {
    var now = computed;
    final c1 = LastResultCache(now: () => now);
    await c1.load<Map<String, dynamic>>('k', () async => {'v': 1});
    now = computed.add(const Duration(hours: 3));
    await c1.load<Map<String, dynamic>>('k', () async => {'v': 2});
    expect(await g1LastResultRows(), hasLength(1), reason: 'one row per key');

    final hit = await LastResultCache().read<Map<String, dynamic>>('k');
    expect(hit!.value, {'v': 2});
    expect(hit.cachedAt, now);
  });

  test('an error is never stored, and the earlier good row stays', () async {
    final c = LastResultCache(now: () => computed);
    await expectLater(
        c.load<Map<String, dynamic>>(
            'k', () async => throw StateError('insights failed')),
        throwsStateError);
    expect(await g1LastResultRows(), isEmpty, reason: 'nothing stored');

    await c.load<Map<String, dynamic>>('k', () async => {'v': 1});
    await expectLater(
        c.load<Map<String, dynamic>>(
            'k', () async => throw StateError('again')),
        throwsStateError);
    final hit = await LastResultCache().read<Map<String, dynamic>>('k');
    expect(hit!.value, {'v': 1}, reason: 'the failed refresh left it alone');
  });

  test('put stores a Map through to the table after flush', () async {
    final c = LastResultCache(now: () => computed);
    c.put<Map<String, dynamic>>('k', {'v': 7});
    await c.flush();
    expect((await g1LastResultRows()).single['key'], 'k');
  });

  test('a value that cannot be JSON-encoded stays in memory and never throws',
      () async {
    final c = LastResultCache(now: () => computed);
    final odd = <String, dynamic>{'when': DateTime(2026, 10, 3)};
    c.put<Map<String, dynamic>>('odd', odd);
    await c.flush();
    expect(c.get<Map<String, dynamic>>('odd')?.value, odd);
    expect(await g1LastResultRows(), isEmpty);
    // load on the same shape also returns the value and does not throw.
    final v = await c.load<Map<String, dynamic>>('odd2', () async => odd);
    expect(v, odd);
  });

  test('the table is bounded to about 200 rows, oldest computed_at dropped',
      () async {
    var now = computed;
    final c = LastResultCache(now: () {
      now = now.add(const Duration(seconds: 1));
      return now;
    });
    for (var i = 0; i < 260; i++) {
      await c.load<Map<String, dynamic>>('k$i', () async => {'i': i});
    }
    final rows = await g1LastResultRows();
    expect(rows.length, lessThanOrEqualTo(200), reason: 'bounded');
    expect(rows.length, greaterThanOrEqualTo(180),
        reason: 'bounded, not wiped');
    final keys = {for (final r in rows) r['key']};
    expect(keys, contains('k259'), reason: 'the newest survives');
    expect(keys, isNot(contains('k0')), reason: 'the oldest went first');
    expect(keys, isNot(contains('k10')));
  });

  test('memory stays an LRU of 32 while the table keeps the rest', () async {
    final c = LastResultCache(now: () => computed);
    for (var i = 0; i < 40; i++) {
      await c.load<Map<String, dynamic>>('k$i', () async => {'i': i});
    }
    expect(c.length, 32);
    expect(c.get<Map<String, dynamic>>('k0'), isNull, reason: 'out of memory');
    final hit = await c.read<Map<String, dynamic>>('k0');
    expect(hit?.value, {'i': 0}, reason: 'but still in the table');
  });

  test('clearMemory is a restart (table stays); clear empties both',
      () async {
    final c = LastResultCache(now: () => computed);
    await c.load<Map<String, dynamic>>('k', () async => {'v': 1});
    c.clearMemory();
    expect(c.length, 0);
    expect(await c.read<Map<String, dynamic>>('k'), isNotNull);
    await c.clear();
    expect(c.length, 0);
    expect(await g1LastResultRows(), isEmpty);
    expect(await c.read<Map<String, dynamic>>('k'), isNull);
  });

  test('a corrupt stored payload is a miss, not a crash', () async {
    final db = await LocalDb.instance;
    // The table must exist first (a no-op write creates nothing: this fails
    // today for the missing table, which is the point).
    await db.insert('last_result', {
      'key': 'bad',
      'computed_at': computed.millisecondsSinceEpoch,
      'payload_json': '{not json',
    });
    expect(await LastResultCache().read<Map<String, dynamic>>('bad'), isNull);
  });
}
