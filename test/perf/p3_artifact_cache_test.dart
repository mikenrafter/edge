// 8AG-perf P3-A: a stored result carries the signature of the inputs it was
// computed from, and a result whose signature still matches is FRESH: shown as
// is, never recomputed on open.
//
// ASSUMED API (lib/ui2/last_result_cache.dart, schema 60 `last_result.input_sig`):
//
//   class CachedResult<T> { ...; final String? sig; }
//       The signature stored with the value; null for a row written without one
//       (every pre-P3 row, and any put() that passes none).
//
//   void put<T>(String key, T value, {String? sig})
//       Same as today, plus: [sig] is kept in memory AND written through to
//       `last_result.input_sig` (NULL when omitted).
//
//   Future<CachedResult<T>?> read<T>(String key)
//       Returns the table's `input_sig` as `.sig`, and promotes it into memory
//       with the sig, so `get<T>(key)?.sig` answers for it afterwards.
//
//   Future<T> loadArtifact<T>(
//     String key,
//     Future<T> Function() loader, {
//     required Future<String?> Function() signature,
//     required void Function(CachedResult<T> last) onLast,
//   })
//     1. `signature()` is called EXACTLY ONCE per call, BEFORE `loader` starts
//        (so a result whose inputs moved while it was being computed is stored
//        under the OLDER signature and reads stale next time, never fresh by
//        accident). A throw from it is a null signature.
//     2. The stored entry is memory first, then the table.
//     3. FRESH = an entry exists AND the current signature is non-null AND
//        entry.sig == current. Then: the stored VALUE is returned, `loader` is
//        never called, `onLast` is never called, nothing is rewritten.
//        A null current signature, or a null stored one, is never fresh.
//     4. Otherwise (stale, missing, null on either side): if there is a stored
//        entry `onLast(entry)` is called (before the loader finishes), then
//        `loader()` runs once, its value is `put` with `sig: current`, and it is
//        returned. A loader error propagates, stores nothing and leaves the
//        earlier entry (and its sig) in place.
//
// Real sqflite_ffi (the cache writes through to the table). Everything new is
// reached through `dynamic`, so a missing method fails ITS test, not the file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';

import '../fix8ai/support/g1_db.dart';

const _db = 'openstrap_p3_artifact_cache_test.db';

Future<Map<String, Object?>?> _row(String key) async {
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
      'SELECT key, computed_at, payload_json, input_sig FROM last_result '
      'WHERE key = ?',
      [key]);
  return rows.isEmpty ? null : rows.single;
}

dynamic _d(LastResultCache c) => c;

/// A cache whose pending write-throughs land before the next test reopens the
/// database file.
LastResultCache _mk() {
  final c = LastResultCache();
  addTearDown(c.flush);
  return c;
}

void main() {
  setUp(() async => g1FreshDb(_db));
  tearDownAll(() => g1DropDb(_db));

  test('put(sig:) keeps the signature in memory and writes it through',
      () async {
    final c = _mk();
    _d(c).put<Map<String, dynamic>>('beats|d', {'nn': [1.0]}, sig: '100|x');
    await c.flush();
    expect((_d(c).get<Map<String, dynamic>>('beats|d') as dynamic).sig, '100|x');
    final r = await _row('beats|d');
    expect(r, isNotNull);
    expect(r!['input_sig'], '100|x');
    expect(jsonDecode(r['payload_json'] as String), {'nn': [1.0]});
  });

  test('put without a sig stores NULL', () async {
    final c = _mk();
    c.put<Map<String, dynamic>>('k', {'a': 1});
    await c.flush();
    expect((await _row('k'))!['input_sig'], isNull);
    expect((_d(c).get<Map<String, dynamic>>('k') as dynamic).sig, isNull);
  });

  test('the signature survives a restart (read() brings it back)', () async {
    final c = _mk();
    _d(c).put<Map<String, dynamic>>('k', {'a': 1}, sig: '100|y');
    await c.flush();
    c.clearMemory();
    final hit = await c.read<Map<String, dynamic>>('k');
    expect((hit as dynamic).sig, '100|y');
    expect((_d(c).get<Map<String, dynamic>>('k') as dynamic).sig, '100|y',
        reason: 'promoted into memory with its sig');
  });

  test('a later put replaces the signature', () async {
    final c = _mk();
    _d(c).put<Map<String, dynamic>>('k', {'a': 1}, sig: 's1');
    _d(c).put<Map<String, dynamic>>('k', {'a': 2}, sig: 's2');
    await c.flush();
    expect((await _row('k'))!['input_sig'], 's2');
  });

  group('loadArtifact', () {
    Future<T> load<T>(LastResultCache c, String key, Future<T> Function() loader,
            {required Future<String?> Function() signature,
            required void Function(CachedResult<T>) onLast}) =>
        _d(c).loadArtifact<T>(key, loader,
            signature: signature, onLast: onLast) as Future<T>;

    test('FRESH (memory): the stored value is returned, the loader and onLast '
        'never run', () async {
      final c = _mk();
      _d(c).put<Map<String, dynamic>>('k', {'v': 'stored'}, sig: 'S1');
      var loads = 0, lasts = 0;
      final v = await load<Map<String, dynamic>>(c, 'k', () async {
        loads++;
        return {'v': 'fresh'};
      }, signature: () async => 'S1', onLast: (_) => lasts++);
      expect(v, {'v': 'stored'});
      expect(loads, 0, reason: 'a fresh artifact is not recomputed on open');
      expect(lasts, 0, reason: 'no "As of": there is nothing stale to show');
    });

    test('FRESH (table, after a restart): same', () async {
      final c = _mk();
      _d(c).put<Map<String, dynamic>>('k', {'v': 'stored'}, sig: 'S1');
      await c.flush();
      c.clearMemory();
      var loads = 0, lasts = 0;
      final v = await load<Map<String, dynamic>>(c, 'k', () async {
        loads++;
        return {'v': 'fresh'};
      }, signature: () async => 'S1', onLast: (_) => lasts++);
      expect(v, {'v': 'stored'});
      expect(loads, 0);
      expect(lasts, 0);
    });

    test('STALE: onLast gets the stored value before the loader finishes, the '
        'loader runs once, the result is stored under the NEW signature',
        () async {
      final c = _mk();
      _d(c).put<Map<String, dynamic>>('k', {'v': 'old'}, sig: 'S1');
      await c.flush();
      final gate = Completer<Map<String, dynamic>>();
      final lasts = <Map<String, dynamic>>[];
      var loads = 0;
      final f = load<Map<String, dynamic>>(c, 'k', () {
        loads++;
        return gate.future;
      }, signature: () async => 'S2', onLast: (h) => lasts.add(h.value));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(lasts, [
        {'v': 'old'}
      ], reason: 'the stored result is shown while the recompute runs');
      expect(loads, 1);
      gate.complete({'v': 'new'});
      expect(await f, {'v': 'new'});
      await c.flush();
      final r = (await _row('k'))!;
      expect(r['input_sig'], 'S2');
      expect(jsonDecode(r['payload_json'] as String), {'v': 'new'});
    });

    test('MISSING: no onLast, one load, stored with the current signature',
        () async {
      final c = _mk();
      var lasts = 0, loads = 0;
      final v = await load<Map<String, dynamic>>(c, 'k', () async {
        loads++;
        return {'v': 1};
      }, signature: () async => 'S1', onLast: (_) => lasts++);
      expect(v, {'v': 1});
      expect([loads, lasts], [1, 0]);
      await c.flush();
      expect((await _row('k'))!['input_sig'], 'S1');
    });

    test('a NULL current signature is never fresh and stores a NULL sig',
        () async {
      final c = _mk();
      _d(c).put<Map<String, dynamic>>('k', {'v': 'old'}, sig: 'S1');
      var loads = 0;
      await load<Map<String, dynamic>>(c, 'k', () async {
        loads++;
        return {'v': 'new'};
      }, signature: () async => null, onLast: (_) {});
      expect(loads, 1);
      await c.flush();
      expect((await _row('k'))!['input_sig'], isNull,
          reason: 'never keep a signature we were not given');
    });

    test('a NULL stored signature is never fresh, even against a null '
        'current one', () async {
      final c = _mk();
      c.put<Map<String, dynamic>>('k', {'v': 'legacy'});
      var loads = 0;
      await load<Map<String, dynamic>>(c, 'k', () async {
        loads++;
        return {'v': 'new'};
      }, signature: () async => null, onLast: (_) {});
      expect(loads, 1);
      loads = 0;
      c.put<Map<String, dynamic>>('j', {'v': 'legacy'});
      await load<Map<String, dynamic>>(c, 'j', () async {
        loads++;
        return {'v': 'new'};
      }, signature: () async => 'S1', onLast: (_) {});
      expect(loads, 1, reason: 'a pre-P3 row (NULL sig) recomputes once');
    });

    test('a signature that throws is a null signature (never fresh, no '
        'exception)', () async {
      final c = _mk();
      _d(c).put<Map<String, dynamic>>('k', {'v': 'old'}, sig: 'S1');
      var loads = 0;
      final v = await load<Map<String, dynamic>>(c, 'k', () async {
        loads++;
        return {'v': 'new'};
      }, signature: () async => throw StateError('db busy'), onLast: (_) {});
      expect(v, {'v': 'new'});
      expect(loads, 1);
    });

    test('signature() is called once, BEFORE the loader; the value is stored '
        'under that earlier signature', () async {
      final c = _mk();
      final log = <String>[];
      var n = 0;
      await load<Map<String, dynamic>>(c, 'k', () async {
        log.add('load');
        return {'v': 1};
      }, signature: () async {
        log.add('sig');
        return 'S${++n}'; // a second call would answer S2
      }, onLast: (_) {});
      expect(log, ['sig', 'load']);
      await c.flush();
      expect((await _row('k'))!['input_sig'], 'S1');
    });

    test('a loader error propagates, stores nothing, keeps the old entry and '
        'its signature', () async {
      final c = _mk();
      _d(c).put<Map<String, dynamic>>('k', {'v': 'old'}, sig: 'S1');
      await c.flush();
      await expectLater(
        load<Map<String, dynamic>>(c, 'k', () async => throw StateError('x'),
            signature: () async => 'S2', onLast: (_) {}),
        throwsStateError,
      );
      await c.flush();
      final r = (await _row('k'))!;
      expect(r['input_sig'], 'S1');
      expect(jsonDecode(r['payload_json'] as String), {'v': 'old'});
      expect(c.get<Map<String, dynamic>>('k')!.value, {'v': 'old'});
    });

    test('a loader error on a MISSING entry stores no row at all', () async {
      final c = _mk();
      await expectLater(
        load<Map<String, dynamic>>(c, 'k', () async => throw StateError('x'),
            signature: () async => 'S1', onLast: (_) {}),
        throwsStateError,
      );
      await c.flush();
      expect(await _row('k'), isNull);
    });
  });
}
