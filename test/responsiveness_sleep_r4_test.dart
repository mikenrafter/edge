import 'support/sleep_writes.dart';
// WHY: daytime raw cannot stand in for the missing input of a measured night.
// CLAIM(sleep-edit-r4): settled assertions preserve measurements when night
// input is gone; recalculation reuses only an unchanged, fenced assertion.
// catches: gating preservation/reuse on an entirely empty day (R4-1).
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'backup/backup_support.dart';
import 'responsiveness_sleep_r3_test.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUp(() async {
    env = await BackupEnv.create('responsiveness_r4.db');
    await LocalDb.setForeground(true);
    await LocalDb.instance;
  });
  tearDown(() async {
    DerivationEngine.debugSecondHalfHook = null;
    DerivationEngine.debugRunning = false;
    await env.dispose();
  });

  Future<void> seed({required bool daytime, required bool manual}) async {
    await p.raw(p.b);
    if (daytime) await p.raw(p.old);
    await p.stored(p.old);
    if (manual) {
      await p.edit(p.old);
      await p.finish((await SleepEditStore.pending()).single);
      final assertion = (await LocalDb.getSleepOverride(p.old))!;
      await (await LocalDb.instance).rawUpdate(
        'UPDATE day_result SET window_json = ? WHERE day_id = ?',
        [
          jsonEncode({
            'value': {
              'onset_ms': (assertion['onset_ts'] as int) * 1000,
              'offset_ms': (assertion['offset_ts'] as int) * 1000,
            },
          }),
          p.old,
        ],
      );
    }
    await (await LocalDb.instance).rawUpdate(
      'UPDATE day_result SET finalized = 1 WHERE day_id = ?',
      [p.old],
    );
  }

  // WHY: application is the durable boundary, even while dependent work is
  // unfinished and a legacy result has no bounds for the reuse proof.
  // CLAIM(sleep-edit-r4); catches: protecting only done jobs or exact windows.
  test(
    'R4-1 applied manual night survives daytime raw while dependents remain',
    () async {
      await seed(daytime: true, manual: true);
      await (await LocalDb.instance).rawUpdate(
        "UPDATE sleep_edit_job SET phase = 'dependents' WHERE day_id = ?",
        [p.old],
      );
      await (await LocalDb.instance).rawUpdate(
        "UPDATE day_result SET window_json = '{}' WHERE day_id = ?",
        [p.old],
      );
      final engine = DerivationEngine();
      await engine.runDays(const Profile(), {p.old}, force: true);
      expect(engine.snapshot()['last_error'], isNull);
      await p.expectStored(p.old);
      final job = (await SleepEditStore.status(p.old))!;
      expect(job['applied_revision'], job['revision']);
    },
  );

  // WHY: a measured sleep duration remains valuable without physiology.
  // CLAIM(sleep-edit-r4); catches: protecting only rhr/rmssd/readiness columns.
  test('R4-1 applied duration-only night survives missing overnight raw', () async {
    await seed(daytime: true, manual: true);
    const payload =
        '{"date":"2026-10-01","scalars":{"tst_min":400,"strain":5,"steps":1234}}';
    final db = await LocalDb.instance;
    await db.rawUpdate(
      "UPDATE day_result SET payload_json = ?, rhr = NULL, rmssd = NULL, readiness = NULL, window_json = '{}' WHERE day_id = ?",
      [payload, p.old],
    );
    await db.delete(
      'metric_series',
      where: 'date = ? AND key = ?',
      whereArgs: [p.old, 'rmssd'],
    );
    final engine = DerivationEngine();
    await engine.runDays(const Profile(), {p.old}, force: true);
    expect(engine.snapshot()['last_error'], isNull);
    expect((await LocalDb.dayResult(p.old))!['payload_json'], payload);
    expect(
      (await db.query(
        'metric_series',
        where: 'date = ? AND key = ?',
        whereArgs: [p.old, 'tst_min'],
      )).single['value'],
      400,
    );
  });

  for (final daytime in [false, true]) {
    final input = daytime ? 'daytime raw only' : 'fully pruned';
    test('R4-1 settled manual night survives force with $input', () async {
      await seed(daytime: daytime, manual: true);
      final engine = DerivationEngine();
      await engine.runDays(const Profile(), {p.old}, force: true);
      expect(engine.snapshot()['last_error'], isNull);
      await p.expectStored(p.old);
      expect((await LocalDb.dayResult(p.old))!['finalized'], 1);
      expect((await SleepEditStore.status(p.old))!['phase'], 'done');
    });

    test('R4-1 no-override force control with $input', () async {
      await seed(daytime: daytime, manual: false);
      final engine = DerivationEngine();
      await engine.runDays(const Profile(), {p.old}, force: true);
      expect(engine.snapshot()['last_error'], isNull);
      await p.expectStored(p.old);
    });

    // WHY: a changed assertion has no proof tying it to the stored night.
    // CLAIM(sleep-edit-r4); catches: reusing any previously measured window.
    test(
      'R4-1 changed unsupported manual window stays unavailable with $input',
      () async {
        await seed(daytime: daytime, manual: true);
        final assertion = (await LocalDb.getSleepOverride(p.old))!;
        await TestSleepWrites.putSleepOverride(
          dayId: p.old,
          onsetTs: (assertion['onset_ts'] as int) + 3600,
          offsetTs: (assertion['offset_ts'] as int) + 3600,
          source: 'manual',
        );
        final app = AppState.forTesting();
        try {
          await app.sleepEditRunner.start().timeout(
            const Duration(seconds: 120),
          );
          final row = (await LocalDb.dayResult(p.old))!;
          expect(row['rmssd'], isNull);
          final scalars =
              (jsonDecode(row['payload_json'] as String) as Map)['scalars']
                  as Map;
          expect(scalars['tst_min'], isNull);
          expect(scalars['readiness'], isNull);
          final series = await (await LocalDb.instance).query(
            'metric_series',
            where: 'date = ? AND key IN (?, ?)',
            whereArgs: [p.old, 'rmssd', 'tst_min'],
          );
          expect(series, isEmpty);
          final job = (await SleepEditStore.status(p.old))!;
          expect(job['applied_revision'], job['revision']);
          expect(job['phase'], 'done');
          expect(job['error'], isNull);
        } finally {
          app.dispose();
        }
      },
    );

    for (final manual in [false, true]) {
      final source = manual ? 'manual' : 'auto';
      test('R4-1 recalculate unchanged $source night with $input', () async {
        await seed(daytime: daytime, manual: manual);
        await SleepEditStore.recalculate(p.old);
        final app = AppState.forTesting();
        try {
          await app.sleepEditRunner.start().timeout(
            const Duration(seconds: 120),
          );
          await p.expectStored(p.old);
          final job = (await SleepEditStore.status(p.old))!;
          expect(job['phase'], 'done');
          expect(job['error'], isNull);
          expect(job['applied_revision'], job['revision']);
          expect(await SleepEditStore.pending(retryFailed: true), isEmpty);
        } finally {
          app.dispose();
        }
      });
    }
  }
}
