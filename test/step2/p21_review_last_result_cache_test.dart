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

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';

import '../support/last_result_db.dart';

const _db = 'p21_review_last_result_cache.db';

class _Hold implements WriteThroughGate {
  _Hold(this._done);
  final Completer<void> _done;
  @override
  Future<void> beforeWriteThrough() => _done.future;
}

LastResultCache _mk() {
  final c = LastResultCache();
  addTearDown(c.flush);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async => g1FreshDb(_db));
  tearDown(() => LastResultCache.debugWriteThroughGate = null);
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

  // Sol review r2, finding 1.
  group('a pending put is never restamped across anything but its own open',
      () {
    const bricked = 'p21_review_lrc_bricked.db';

    tearDown(() async {
      await g1DropDb(bricked);
      for (final f in Directory(await databaseFactory.getDatabasesPath())
          .listSync()) {
        if (f is File && f.path.contains('$bricked.unopenable')) f.deleteSync();
      }
    });

    test('the first open fails, the rebuild salvages nothing: the pending '
        'put\'s entry misses', () async {
      await LocalDb.close();
      final path = p.join(await databaseFactory.getDatabasesPath(), bricked);
      await databaseFactory.deleteDatabase(path);
      // The wrong shape makes the ladder's index creation throw; nothing in
      // the file is salvageable, so the salvage commits no page.
      final seed = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(
              version: 2,
              onCreate: (d, _) =>
                  d.execute('CREATE TABLE metric_series (bogus INTEGER)')));
      await seed.close();
      LocalDb.lastRebuild = null;
      LocalDb.dbName = bricked;
      final c = _mk();

      c.put<Map<String, dynamic>>('k', {'a': 1}); // store closed
      await c.flush();

      expect(LocalDb.lastRebuild, isNotNull, reason: 'the open really bricked');
      expect(LocalDb.lastRebuild!.salvaged.values.fold<int>(0, (a, b) => a + b),
          0,
          reason: 'nothing was salvaged: no merge page, no merge mark');
      expect(c.get<Map<String, dynamic>>('k'), isNull,
          reason: 'the store was REPLACED by the rebuild; the fresh-file open '
              'must not look like a plain first open');
    });

    test('put on an OPEN store, ordinary close and reopen before the '
        'write-through: no restamp, a miss', () async {
      await LocalDb.instance;
      final hold = Completer<void>();
      LastResultCache.debugWriteThroughGate = _Hold(hold);
      final c = _mk();

      c.put<Map<String, dynamic>>('k', {'a': 1});
      await LocalDb.close();
      await LocalDb.instance; // an ordinary reopen
      hold.complete();
      await c.flush();

      expect(c.get<Map<String, dynamic>>('k'), isNull,
          reason: 'the store was open at put(); nothing about this put was '
              'bound to a first open');
      expect((await LocalDb.lastResult('k'))?.payload, '{"a":1}');
    });

    test('put on a CLOSED store, an ordinary open by someone else first: '
        'still bound and a hit', () async {
      await LocalDb.close();
      final hold = Completer<void>();
      LastResultCache.debugWriteThroughGate = _Hold(hold);
      final c = _mk();

      c.put<Map<String, dynamic>>('k', {'a': 1});
      await LocalDb.instance; // the first open after the put
      hold.complete();
      await c.flush();

      expect(c.get<Map<String, dynamic>>('k')?.value, {'a': 1});
    });
  });
}
