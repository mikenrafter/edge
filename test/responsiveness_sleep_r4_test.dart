// WHY: daytime raw cannot stand in for the missing input of a measured night.
// CLAIM(sleep-edit-r4): settled assertions preserve measurements when night
// input is gone; recalculation reuses only an unchanged, fenced assertion.
// catches: gating preservation/reuse on an entirely empty day (R4-1).
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
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

  // WHY: CLAIM(retained-nap-receipt). Main-window reuse cannot certify a
  // nap-only edit. Real runner + reopen prove projection and receipt agree.
  for (final action in ['add', 'move', 'reject']) {
    test('R1 pruned night applies $action nap before dependents and done', () async {
      await seed(daytime: false, manual: false);
      final db = await LocalDb.instance;
      int at(int h) => DateTime.parse('${p.old}T${h.toString().padLeft(2, '0')}:00:00')
          .millisecondsSinceEpoch ~/ 1000;
      final target = {'start': at(10), 'end': at(10) + 1800,
        'duration_min': 20, 'in_bed_min': 30, 'source': 'legacy', 'confidence': .8};
      final unrelated = {'start': at(16), 'end': at(16) + 1800,
        'duration_min': 25, 'in_bed_min': 30, 'source': 'legacy', 'confidence': .9};
      final main = {'is_main': true, 'onset_ts': at(0) - 3600,
        'wake_ts': at(7), 'duration_min': 400, 'efficiency': .91};
      final row = (await LocalDb.dayResult(p.old))!;
      final bundle = Map<String, dynamic>.from(jsonDecode(row['payload_json'] as String) as Map);
      bundle['naps'] = {'value': [target, unrelated], 'assessment_complete': true};
      (bundle['scalars'] as Map)['nap_min'] = 45.0;
      bundle['sleep_periods'] = {'periods': [main], 'total_asleep_min': 445};
      await db.update('day_result', {'payload_json': jsonEncode(bundle)},
        where: 'day_id = ?', whereArgs: [p.old]);
      await db.transaction((tx) => ActivityStore.preserveLegacyNaps(tx, p.old, bundle));
      if (action == 'reject') {
        // The low-level assertion deliberately isolates the worker regression
        // from the separate legacy entry-action guard tested in data safety.
        await LocalDb.putNapEdit(dayId: p.old, startTs: at(10),
          endTs: at(10) + 1800, source: 'rejected');
        await SleepEditStore.recalculate(p.old);
      } else {
        await writeSleepEdit(db, SleepEditPlan(day: p.old, naps: [NapWrite(
          start: at(14), end: at(14) + 1800,
          fromStart: action == 'move' ? at(10) : null,
          fromEnd: action == 'move' ? at(10) + 1800 : null,
          fromSource: action == 'move' ? 'legacy' : null)]));
      }
      await LocalDb.close();
      final expected = action == 'add' ? 75 : action == 'move' ? 55 : 25;
      var dependentRan = false;
      DerivationEngine.debugSecondHalfHook = (day) async {
        if (day != p.b) return;
        dependentRan = true;
        expect((await SleepEditStore.status(p.old))!['phase'], 'dependents');
        final applied = jsonDecode((await LocalDb.dayResult(p.old))!['payload_json'] as String) as Map;
        expect((applied['scalars'] as Map)['nap_min'], expected);
      };
      final app = AppState.forTesting();
      try {
        await app.sleepEditRunner.start().timeout(const Duration(seconds: 120));
        final result = (await LocalDb.dayResult(p.old))!;
        final saved = jsonDecode(result['payload_json'] as String) as Map;
        final scalars = saved['scalars'] as Map;
        expect(scalars['nap_min'], expected);
        expect({...scalars}..remove('nap_min'), {'strain': 5, 'steps': 1234,
          'rmssd': 55, 'tst_min': 400, 'readiness': 70, 'rhr': 52});
        expect(result['rmssd'], 55);
        final periods = saved['sleep_periods'] as Map;
        expect((periods['periods'] as List).where((p) => (p as Map)['is_main'] == true).single, main);
        expect(periods['total_asleep_min'], 400 + expected);
        final naps = (saved['naps'] as Map)['value'] as List;
        expect(naps.where((n) => (n as Map)['start'] == at(16)).single, unrelated);
        expect(naps.map((n) => (n as Map)['start']), action == 'add'
          ? [at(10), at(14), at(16)] : action == 'move' ? [at(14), at(16)] : [at(16)]);
        final repo = LocalRepositoryImpl(getProfileMap: () => {});
        expect((await repo.getDayNaps(p.old))['nap_min'], expected);
        final job = (await SleepEditStore.status(p.old))!;
        expect([job['phase'], job['applied_revision']], ['done', job['revision']]);
        expect(dependentRan, isTrue);
      } finally { app.dispose(); }
    });
  }

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
        await LocalDb.putSleepOverride(
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
