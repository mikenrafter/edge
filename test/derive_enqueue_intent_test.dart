// Keep dirty intent that arrives while a job is running.
//
// The bug: `LocalDb.enqueueDeriveJob` deduped against queued OR running jobs.
// Data stored after the running job read its inputs therefore had no
// follow-up: the request was dropped and the day stayed stale until the next
// unrelated drain.
//
// ASSUMED SEMANTICS (lib/data/db.dart, `enqueueDeriveJob`, same signature):
//   * dedupe against QUEUED jobs only; a RUNNING job never absorbs new intent
//     => at most one queued follow-up per type;
//   * light is absorbed by a queued light or a queued heavy;
//   * heavy is absorbed by a queued heavy, and still deletes queued lights;
//   * `cancelQueuedLightDerive` is unchanged (queued lights only).
//   * Job ids must not collide when a follow-up is enqueued in the same
//     millisecond as the running job it follows (the old id was
//     'derive_${type}_$nowMs'): the PK insert must never throw.
//
// Uses only symbols that exist today, so every failure here is a behavioural
// one. Tests marked "guard" pin behaviour that must keep holding.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<List<Map<String, dynamic>>> _jobs() async {
  final db = await LocalDb.instance;
  return db.query('compute_jobs', where: "scope = 'derive'");
}

Future<int> _count(String type, String state) async =>
    (await _jobs()).where((j) => j['type'] == type && j['state'] == state).length;

const _light = 'derive_light';
const _heavy = 'derive_heavy';

Future<void> _enqueue(String type) =>
    LocalDb.enqueueDeriveJob(type: type, reason: 'test');

/// Queue one [type] job and claim it, so it is RUNNING.
Future<void> _startRunning(String type) async {
  await _enqueue(type);
  final taken = await LocalDb.takeNextComputeJob();
  expect(taken?['type'], type);
  expect(taken?['state'], 'running');
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_enqueue_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(() async {
    final db = await LocalDb.instance;
    await db.delete('compute_jobs');
  });

  group('a running job never absorbs new intent', () {
    test('light while a light is RUNNING => one queued follow-up', () async {
      await _startRunning(_light);
      await _enqueue(_light);
      expect(await _count(_light, 'running'), 1);
      expect(await _count(_light, 'queued'), 1,
          reason: 'the running job already read its inputs');
    });

    test('a second light while that follow-up is queued => still one',
        () async {
      await _startRunning(_light);
      await _enqueue(_light);
      await _enqueue(_light);
      await _enqueue(_light);
      expect(await _count(_light, 'queued'), 1);
      expect(await _count(_light, 'running'), 1);
    });

    test('heavy while a heavy is RUNNING => one queued heavy', () async {
      await _startRunning(_heavy);
      await _enqueue(_heavy);
      expect(await _count(_heavy, 'running'), 1);
      expect(await _count(_heavy, 'queued'), 1);
      await _enqueue(_heavy);
      expect(await _count(_heavy, 'queued'), 1,
          reason: 'at most one queued follow-up per type');
    });

    test('light while a heavy is RUNNING => one queued light follow-up',
        () async {
      await _startRunning(_heavy);
      await _enqueue(_light);
      expect(await _count(_light, 'queued'), 1);
      expect(await _count(_heavy, 'running'), 1);
    });

    test('heavy while a light is RUNNING => a queued heavy', () async {
      // Guard on today's behaviour that also must keep holding.
      await _startRunning(_light);
      await _enqueue(_heavy);
      expect(await _count(_heavy, 'queued'), 1);
      expect(await _count(_light, 'running'), 1);
    });

    test('the follow-up is claimable once the running job completes',
        () async {
      await _startRunning(_light);
      await _enqueue(_light);
      final running =
          (await _jobs()).firstWhere((j) => j['state'] == 'running');
      await LocalDb.completeComputeJob(running['id'] as String);

      final next = await LocalDb.takeNextComputeJob();
      expect(next, isNotNull);
      expect(next!['type'], _light);
      expect(await _jobs(), hasLength(1));
    });

    test('cancelQueuedLightDerive removes a queued light follow-up',
        () async {
      await _startRunning(_light);
      await _enqueue(_light);
      expect(await LocalDb.cancelQueuedLightDerive(), 1);
      expect(await _count(_light, 'running'), 1);
      expect(await _count(_light, 'queued'), 0);
    });

    test('enqueueing right behind a claim never trips over a job id',
        () async {
      // Twenty rounds of: queue, claim, queue the follow-up, finish both.
      // Same-millisecond ids would collide on the primary key.
      for (var i = 0; i < 20; i++) {
        await _enqueue(_light);
        final a = await LocalDb.takeNextComputeJob();
        await _enqueue(_light);
        await LocalDb.completeComputeJob(a!['id'] as String);
        final b = await LocalDb.takeNextComputeJob();
        expect(b, isNotNull, reason: 'round $i: the follow-up exists');
        await LocalDb.completeComputeJob(b!['id'] as String);
        expect(await _jobs(), isEmpty);
      }
    });
  });

  group('guard: dedupe against QUEUED jobs is unchanged', () {
    test('light while a light is queued => absorbed', () async {
      await _enqueue(_light);
      await _enqueue(_light);
      expect(await _count(_light, 'queued'), 1);
    });

    test('light while a heavy is queued => absorbed by the heavy', () async {
      await _enqueue(_heavy);
      await _enqueue(_light);
      expect(await _count(_light, 'queued'), 0);
      expect(await _count(_heavy, 'queued'), 1);
    });

    test('heavy while a heavy is queued => absorbed', () async {
      await _enqueue(_heavy);
      await _enqueue(_heavy);
      expect(await _count(_heavy, 'queued'), 1);
    });

    test('heavy deletes queued lights and queues itself', () async {
      await _enqueue(_light);
      await _enqueue(_heavy);
      expect(await _count(_light, 'queued'), 0);
      expect(await _count(_heavy, 'queued'), 1);
    });

    test('heavy with a running light and a queued light: the queued light '
        'goes, the running one stays', () async {
      await _startRunning(_light);
      await _enqueue(_light); // kept as a follow-up, not dropped
      await _enqueue(_heavy);
      expect(await _count(_light, 'queued'), 0);
      expect(await _count(_light, 'running'), 1);
      expect(await _count(_heavy, 'queued'), 1);
    });

    test('cancelQueuedLightDerive drops queued lights, not running or heavy',
        () async {
      await _startRunning(_light);
      await _enqueue(_light); // queued follow-up
      await _enqueue(_heavy); // deletes that light; keep a heavy queued
      await _enqueue(_light); // absorbed by the queued heavy
      final dropped = await LocalDb.cancelQueuedLightDerive();
      expect(dropped, 0);
      expect(await _count(_light, 'running'), 1);
      expect(await _count(_heavy, 'queued'), 1);
    });

  });
}
