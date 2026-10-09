// Sol review r1, finding 2: `LastResultCache` fenced on `LocalDb.storeGeneration`
// but took its snapshots BEFORE the lazy open of the store.
//
//   * put() stamped the closed-store generation; the write-through then opened
//     the store (a new generation), so the in-memory entry missed at once.
//     Rule: a pending put is bound to the generation its SUCCESSFUL write-through
//     used, but only when that generation is the first one after the put's own
//     open and nothing replaced the store in between. A genuine replacement
//     crossing stays a miss; a newer put for the key is never overwritten.
//   * read() on a fresh cache with the store closed reopened it inside the
//     query, then discarded the row it had just read because the generation
//     moved. It now captures the generation after the store is open.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';

import '../support/last_result_db.dart';

const _db = 'p21_review_last_result_cache.db';

LastResultCache _mk() {
  final c = LastResultCache();
  addTearDown(c.flush);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async => g1FreshDb(_db));
  tearDownAll(() => g1DropDb(_db));

  group('read() on a closed store', () {
    test('a persisted row on a fresh cache is returned the first time',
        () async {
      await LocalDb.putLastResult('k', 1234, '{"a":1}', 200, sig: 's');
      await LocalDb.close();

      final hit = await _mk().read<Map<String, dynamic>>('k');

      expect(hit, isNotNull, reason: 'the open it triggered discarded its row');
      expect(hit!.value, {'a': 1});
      expect(hit.sig, 's');
    });

    test('and it is promoted into memory, so get() answers afterwards',
        () async {
      await LocalDb.putLastResult('k', 1234, '{"a":1}', 200);
      await LocalDb.close();
      final c = _mk();

      await c.read<Map<String, dynamic>>('k');

      expect(c.get<Map<String, dynamic>>('k')?.value, {'a': 1});
    });

    test('a genuine replacement during the read is still a miss', () async {
      await LocalDb.putLastResult('k', 1234, '{"a":1}', 200);
      final c = _mk();
      final read = c.read<Map<String, dynamic>>('k');
      await LocalDb.wipeAll(); // crosses the read
      final hit = await read;
      // Either order is legitimate (read first, or after the wipe finds
      // nothing); what must not happen is a pre-wipe row promoted afterwards.
      await c.flush();
      expect(c.get<Map<String, dynamic>>('k'), isNull);
      expect(hit == null || hit.value['a'] == 1, isTrue);
    });
  });

  group('put() before the lazy open', () {
    test('a put on a closed store is a memory hit once the write-through lands',
        () async {
      final c = _mk();
      c.put<Map<String, dynamic>>('k', {'a': 1}, sig: 's');
      await c.flush();
      expect(c.get<Map<String, dynamic>>('k')?.value, {'a': 1});
    });

    test('a put whose write-through crosses a genuine replacement is NOT '
        'restamped: it misses', () async {
      final c = _mk();
      c.put<Map<String, dynamic>>('k', {'a': 1});
      final wipe = LocalDb.wipeAll(); // opens the store, then wipes it
      await wipe;
      await c.flush();
      expect(c.get<Map<String, dynamic>>('k'), isNull,
          reason: 'a value put before a wipe must not outlive it in memory');
    });

    test('same on an open store', () async {
      await LocalDb.instance;
      final c = _mk();
      c.put<Map<String, dynamic>>('k', {'a': 1});
      await LocalDb.wipeAll();
      await c.flush();
      expect(c.get<Map<String, dynamic>>('k'), isNull);
    });

    test('a newer put during a pending write-through wins', () async {
      final c = _mk();
      c.put<Map<String, dynamic>>('k', {'v': 1}, sig: 's1');
      c.put<Map<String, dynamic>>('k', {'v': 2}, sig: 's2');
      await c.flush();
      final hit = c.get<Map<String, dynamic>>('k');
      expect(hit?.value, {'v': 2});
      expect(hit?.sig, 's2');
      final row = await LocalDb.lastResult('k');
      expect(row?.payload, '{"v":2}');
    });

    test('the first put\'s completion does not restamp the second put\'s '
        'entry for another key out of order', () async {
      final c = _mk();
      c.put<Map<String, dynamic>>('a', {'v': 1});
      c.put<Map<String, dynamic>>('b', {'v': 2});
      await c.flush();
      expect(c.get<Map<String, dynamic>>('a')?.value, {'v': 1});
      expect(c.get<Map<String, dynamic>>('b')?.value, {'v': 2});
    });
  });
}
