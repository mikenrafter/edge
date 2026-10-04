// 8M follow-up — a manual sync absorbs the debounced light derive.
//
// Committed chunks arm `onDataStored`, which queues a durable light derive on an
// 8 s settle. The manual sync then runs its own derive over the same data, so
// the same days were computed twice (or the light job fired mid-calculation and
// returned 0 behind the engine lock, silently "completing" a job nobody ran).
//
// While a manual sync holds the scheduler: nothing drains, no timer is armed.
// When it releases having derived the data it was holding for, the queued light
// job is dropped; data that landed AFTER the derive started keeps its job.
// A failed or cancelled sync releases WITHOUT absorbing, so the light job runs.
//
// The scheduler's settle timers are real but tiny (10 ms), like the workout-gate
// suite: the assertions are on the parked state, which is deterministic because
// a held scheduler never creates a timer at all.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_outcome.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

const _settle = Duration(milliseconds: 10);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_manual_sync_hold_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() => LocalDb.close());

  late List<DeriveJobKind> ran;
  late DeriveScheduler s;

  setUp(() async {
    // No job survives from a previous test.
    final db = await LocalDb.instance;
    await db.delete('compute_jobs');
    // Per-scheduler list: a drain still in flight from the previous test must
    // not write into this test's results.
    final mine = ran = [];
    s = DeriveScheduler(
      run: ({required DeriveJobKind kind}) async {
        mine.add(kind);
        return const DeriveOutcome();
      },
      log: (_) {},
      onChanged: () {},
      lightSettle: _settle,
      heavySettle: _settle,
    );
  });

  tearDown(() => s.dispose());

  test('a queued light derive does not run while a manual sync holds', () async {
    final hold = s.beginManualSync();
    s.markStoredData();
    await _until(() => s.snapshot()['pending_light'] == true);
    expect(s.snapshot()['manual_sync_hold'], isTrue);
    await Future<void>.delayed(_settle * 5);
    expect(ran, isEmpty, reason: 'the held scheduler arms no timer at all');
    s.endManualSync(hold, absorb: false);
  });

  test('releasing after the derive absorbs the light job: it never runs',
      () async {
    final hold = s.beginManualSync();
    s.markStoredData();
    await _until(() => s.snapshot()['pending_light'] == true);

    s.markManualDeriveStarted(hold);
    await s.endManualSync(hold, absorb: true);

    expect(s.snapshot()['pending_light'], isFalse);
    await Future<void>.delayed(_settle * 6);
    expect(ran, isEmpty, reason: 'same data, already derived: not twice');

    // Not wedged: fresh data afterwards still gets its light derive.
    s.markStoredData();
    await _until(() => ran.length == 1);
    expect(ran, [DeriveJobKind.light]);
  });

  test('data stored after the derive started keeps its light job', () async {
    final hold = s.beginManualSync();
    s.markStoredData();
    await _until(() => s.snapshot()['pending_light'] == true);

    s.markManualDeriveStarted(hold);
    s.markStoredData(); // a commit landed mid-derive
    await s.endManualSync(hold, absorb: true);

    await _until(() => ran.length == 1);
    expect(ran, [DeriveJobKind.light],
        reason: 'the derive may not have read that data; it must run once');
  });

  test('a failed sync releases without absorbing: the light job runs', () async {
    final hold = s.beginManualSync();
    s.markStoredData();
    await _until(() => s.snapshot()['pending_light'] == true);
    s.markManualDeriveStarted(hold);
    await s.endManualSync(hold, absorb: false);

    await _until(() => ran.length == 1);
    expect(ran, [DeriveJobKind.light]);
    expect(s.snapshot()['manual_sync_hold'], isFalse);
  });

  test('a queued heavy job is never absorbed (it carries the finalize extras)',
      () async {
    final hold = s.beginManualSync();
    s.requestHeavy();
    await _until(() => s.snapshot()['pending_heavy'] == true);
    s.markManualDeriveStarted(hold);
    await s.endManualSync(hold, absorb: true);

    await _until(() => ran.length == 1);
    expect(ran, [DeriveJobKind.heavy]);
  });

  test('two overlapping holds: the scheduler stays held until both end',
      () async {
    final old = s.beginManualSync(); // a retired run still unwinding
    final next = s.beginManualSync();
    s.markStoredData();
    await _until(() => s.snapshot()['pending_light'] == true);

    await s.endManualSync(old, absorb: false);
    await Future<void>.delayed(_settle * 5);
    expect(ran, isEmpty, reason: 'the newer sync still holds');

    await s.endManualSync(next, absorb: false);
    await _until(() => ran.length == 1);
  });

  test('ending a hold twice is harmless', () async {
    final hold = s.beginManualSync();
    await s.endManualSync(hold, absorb: false);
    await s.endManualSync(hold, absorb: false);
    expect(s.snapshot()['manual_sync_hold'], isFalse);
  });
}
