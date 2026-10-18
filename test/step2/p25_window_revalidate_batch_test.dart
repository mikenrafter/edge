// The sleep-windows revalidation after the worker decode is ONE query per
// chunk (WHERE day_id IN (...)), not one read per row, and it decides exactly
// what the per-row read decided: same staleness test, same single retry, same
// treatment of a deleted, replaced or wiped row.
//
// Parity is proven by running each scenario twice through the same lane, once
// with SleepWindowRowSource (batched) and once with a source that only has the
// per-row current(), and requiring identical output and worker-call counts.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/json_payload_lane.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

import 'support/p25_support.dart';

const _name = 'p25_window_batch.db';

class _JsonLane implements JsonPayloadDecodeLane {
  int calls = 0;
  Future<void> Function(int index)? hook;
  @override
  Future<JsonPayloadsResult> run(JsonPayloadsInput input) async {
    final i = calls++;
    await hook?.call(i);
    return decodeJsonPayloadsHeavy(bundleWorkerInputs, input);
  }
}

/// The per-row path: only [current], no batching.
class _PerRow implements JsonRowSource {
  _PerRow(this.day) : _inner = SleepWindowRowSource(day);
  final String day;
  final SleepWindowRowSource _inner;
  @override
  String get key => _inner.key;
  @override
  Future<JsonRowState?> current() => _inner.current();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  setUp(() async {
    db = await p21Fresh(_name);
    BundleStore.debugResetShared();
    JsonPayloadLane.debugResetShared();
    await p25SeedWindows(db);
  });
  tearDown(() async {
    BundleStore.debugResetShared();
    JsonPayloadLane.debugResetShared();
    await p21Drop(_name);
  });

  test('sleepWindows revalidates with one statement per chunk, none per row',
      () async {
    final sql = <String>[];
    await LocalDb.close();
    // ignore: experimental_member_use
    databaseFactory = SqfliteDatabaseFactoryLogger(
      databaseFactoryFfi,
      options: SqfliteLoggerOptions(
        type: SqfliteDatabaseFactoryLoggerType.all,
        log: (e) {
          if (e is SqfliteLoggerSqlEvent) sql.add(e.toString());
        },
      ),
    );
    addTearDown(() => databaseFactory = databaseFactoryFfi);
    await LocalDb.instance;
    await LocalDb.setForeground(true);
    addTearDown(() => LocalDb.setForeground(false));
    JsonPayloadLane.debugUseShared(JsonPayloadLane(lane: _JsonLane()));
    sql.clear();

    final rows = await LocalRepositoryImpl(getProfileMap: () => p22Profile)
        .sleepWindows(days: 14);

    expect(rows, isNotEmpty);
    // Every statement that reads window_json: the one list read, then the
    // revalidation reads.
    final windowReads =
        sql.where((l) => l.contains('r.window_json AS window_json')).length;
    expect(windowReads, inInclusiveRange(2, 4),
        reason: 'one list read, then one query per chunk (2 chunks of at most '
            '8, plus one recheck of the first), never one per row; saw $windowReads');
  });

  group('parity with the per-row revalidation', () {
    Future<({List<Object?> values, int workerCalls, int entries})> run(
      JsonRowSource Function(String day) make,
      Future<void> Function(int call) mutate,
    ) async {
      final fake = _JsonLane()..hook = mutate;
      final lane = JsonPayloadLane(lane: fake);
      final rows = await LocalDb.sleepWindowRows(14);
      final out = await lane.decodeMany([
        for (final r in rows)
          (
            source: make('${r['day_id']}'),
            state: SleepWindowRowSource.stateOf(r),
          ),
      ]);
      return (
        values: [for (final d in out) d?.value],
        workerCalls: fake.calls,
        entries: lane.debugEntries,
      );
    }

    Future<void> scenario(
      String name,
      Future<void> Function(int call) mutate,
    ) async {
      // Same store, same mutation, both source kinds.
      await p21Drop(_name);
      db = await p21Fresh(_name);
      await p25SeedWindows(db);
      final batched = await run(SleepWindowRowSource.new, mutate);
      await p21Drop(_name);
      db = await p21Fresh(_name);
      await p25SeedWindows(db);
      final perRow = await run(_PerRow.new, mutate);
      expect(batched.values, perRow.values, reason: name);
      expect(batched.workerCalls, perRow.workerCalls, reason: name);
      expect(batched.entries, perRow.entries, reason: name);
    }

    test('a day replaced between decode and revalidation', () async {
      await scenario('replaced', (call) async {
        if (call != 0) return;
        await p25Row(db, p25WindowDays[2],
            window: '{"onset_ms": 1000000, "offset_ms": 2000000}',
            computedAt: 9000);
      });
    });

    test('a day replaced on every attempt (twice is absence)', () async {
      await scenario('replaced twice', (call) async {
        await p25Row(db, p25WindowDays[1],
            window: '{"onset_ms": ${1000000 + call}, "offset_ms": 2000000}',
            computedAt: 9000 + call);
      });
    });

    test('a day deleted between decode and revalidation', () async {
      await scenario('deleted', (call) async {
        if (call != 0) return;
        await db.delete('day_result',
            where: 'day_id = ?', whereArgs: [p25WindowDays[3]]);
      });
    });

    test('a wipe during the worker call', () async {
      await scenario('wiped', (call) async {
        if (call != 0) return;
        await LocalDb.wipeAll();
      });
    });
  });
}
