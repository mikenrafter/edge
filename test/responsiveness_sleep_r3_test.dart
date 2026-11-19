import 'support/sleep_writes.dart';
// WHY: settled edits and pruned raw must never erase measured history or
// leave a successful edit retrying forever (review R3-1/R3-2).
// CLAIM(sleep-edit-r3): only unapplied assertions can invalidate a night;
// declined dependent days have settled.
// catches: blanking on any job row; requiring an override for reuse;
// treating declined dependent days as incomplete.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'backup/backup_support.dart';

const a = '2026-11-10', b = '2026-11-13', old = '2026-10-01';
Future<void> edit(String d, {String source = 'manual'}) {
  final wake = DateTime.parse('${d}T07:00:00').millisecondsSinceEpoch ~/ 1000;
  return TestSleepWrites.putSleepOverride(
    dayId: d,
    onsetTs: wake - 8 * 3600,
    offsetTs: wake,
    source: source,
  );
}

Future<void> finish(SleepEditJob j) async {
  await (await LocalDb.instance).rawUpdate(
    'UPDATE sleep_edit_job SET applied_revision = revision WHERE day_id = ? AND revision = ?',
    [j.day, j.revision],
  );
  await SleepEditStore.advance(j, SleepEditPhase.done);
}

Future<void> raw(String d) async {
  final t = DateTime.parse('${d}T12:00:00').millisecondsSinceEpoch ~/ 1000;
  for (final n in [t, t + 1]) {
    await (await LocalDb.instance).insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': n * 1000,
      'rec_ts': n,
      'counter': n,
      'hr': 60,
      'device_family': 'gen4',
    });
  }
}

Future<void> stored(String d) => LocalDb.putDayResult(
  dayId: d,
  algoVersion: kAlgoVersion,
  payloadJson:
      '{"date":"$d","scalars":{"strain":5,"steps":1234,"rmssd":55,"tst_min":400,"readiness":70,"rhr":52},"clinical":{"hrv_time":{"rmssd":55}}}',
  windowJson: '{}',
  rmssd: 55,
  series: const {'strain': 5, 'rmssd': 55, 'tst_min': 400},
);

// The independently seeded measurements must survive byte for byte; checking
// only a public read could hide loss in the durable payload or chart series.
Future<void> expectStored(String day) async {
  final row = (await LocalDb.dayResult(day))!;
  expect(row['rmssd'], 55);
  expect(row['partial'], 0);
  expect((jsonDecode(row['payload_json'] as String) as Map)['scalars'], {
    'strain': 5,
    'steps': 1234,
    'rmssd': 55,
    'tst_min': 400,
    'readiness': 70,
    'rhr': 52,
  });
  final series = await (await LocalDb.instance).query(
    'metric_series',
    columns: ['key', 'value'],
    where: 'date = ?',
    whereArgs: [day],
  );
  expect(
    {for (final r in series) r['key']: r['value']},
    {'strain': 5, 'rmssd': 55, 'tst_min': 400},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUp(() async {
    env = await BackupEnv.create('responsiveness_r3_probe.db');
    await LocalDb.setForeground(true);
    await LocalDb.instance;
  });
  tearDown(() async {
    DerivationEngine.debugSecondHalfHook = null;
    DerivationEngine.debugRunning = false;
    await env.dispose();
  });

  Future<void> forcePass(String day) async {
    final engine = DerivationEngine();
    await engine.runDays(const Profile(), {day}, force: true);
    expect(engine.snapshot()['last_error'], isNull);
  }

  test(
    'R3-1 control: a pruned-raw night with no edit history keeps its stored result',
    () async {
      await raw(b);
      await stored(old);
      await forcePass(old);
      final repo = LocalRepositoryImpl(getProfileMap: () => {});
      expect((await repo.getDayHrv(old))['rmssd'], 55);
    },
  );

  test(
    'R3-1 a long-done manual edit does not blank a stored night whose raw is gone',
    () async {
      await raw(b);
      await stored(old);
      await edit(old);
      await finish((await SleepEditStore.pending()).single);
      expect((await SleepEditStore.status(old))!['phase'], 'done');
      await forcePass(old);
      await expectStored(old);
      final repo = LocalRepositoryImpl(getProfileMap: () => {});
      expect(
        (await repo.getDayHrv(old))['rmssd'],
        55,
        reason:
            'a settled edit is not a new assertion; the stored night must stay',
      );
    },
  );

  test(
    'R3-1 a long-done recalculate (no override row) does not blank the stored night',
    () async {
      await raw(b);
      await stored(old);
      await SleepEditStore.recalculate(old);
      await finish((await SleepEditStore.pending()).single);
      await forcePass(old);
      await expectStored(old);
      final repo = LocalRepositoryImpl(getProfileMap: () => {});
      expect((await repo.getDayHrv(old))['rmssd'], 55);
      expect((await repo.getDayOverview(old))['readiness'], 70);
    },
  );

  test(
    'R3-2 a later day the engine declines settles the edit instead of failing it',
    () async {
      await stored(b);
      await raw(a);
      await raw(b);
      await edit(a);
      final app = AppState.forTesting();
      try {
        await app.sleepEditRunner.start().timeout(const Duration(seconds: 120));
        final job = (await SleepEditStore.status(a))!;
        final rowB = await LocalDb.dayResult(b);
        expect(job['error'], isNull);
        expect(
          await SleepEditStore.hasOutstandingOn(await LocalDb.instance),
          isFalse,
        );
        await expectStored(b);
        expect(
          job['applied_revision'],
          job['revision'],
          reason: 'own night applied',
        );
        expect(
          rowB?['rmssd'],
          55,
          reason: 'b kept its existing result (declined)',
        );
        expect(
          job['phase'],
          'done',
          reason:
              'the engine settled b; the edit owes nothing. error=${job['error']}',
        );
        expect(await SleepEditStore.pending(retryFailed: true), isEmpty);
      } finally {
        app.dispose();
      }
    },
  );
  // WHY: Recalculate changes no assertion. Raw retention cannot turn it into
  // an instruction to erase the measured night. Exercises the real runner.
  test(
    'R3-1 recalculate a pruned auto night keeps measurements and applies the revision',
    () async {
      await raw(b);
      await stored(old);
      await SleepEditStore.recalculate(old);
      final app = AppState.forTesting();
      try {
        await app.sleepEditRunner.start().timeout(const Duration(seconds: 120));
        await expectStored(old);
        final job = (await SleepEditStore.status(old))!;
        expect(job['phase'], 'done');
        expect(job['error'], isNull);
        expect(job['applied_revision'], job['revision']);
        expect(await SleepEditStore.pending(retryFailed: true), isEmpty);
      } finally {
        app.dispose();
      }
    },
  );

  // WHY: Recalculate also changes no assertion on a manually corrected night.
  // The exact measured bounds prove reuse, even though the manual blanking
  // policy normally takes precedence for a newly changed unsupported window.
  // CLAIM(sleep-edit-r3); catches: running manual blanking before reuse proof.
  test(
    'R3-1 recalculating a pruned manual night reuses its unchanged window',
    () async {
      await raw(b);
      await stored(old);
      await edit(old);
      await finish((await SleepEditStore.pending()).single);
      final assertion = (await LocalDb.getSleepOverride(old))!;
      await (await LocalDb.instance).rawUpdate(
        'UPDATE day_result SET window_json = ? WHERE day_id = ?',
        [
          jsonEncode({
            'value': {
              'onset_ms': (assertion['onset_ts'] as int) * 1000,
              'offset_ms': (assertion['offset_ts'] as int) * 1000,
            },
          }),
          old,
        ],
      );
      await SleepEditStore.recalculate(old);
      final app = AppState.forTesting();
      try {
        await app.sleepEditRunner.start().timeout(const Duration(seconds: 120));
        await expectStored(old);
        final job = (await SleepEditStore.status(old))!;
        expect(job['phase'], 'done');
        expect(job['revision'], 2);
        expect(job['applied_revision'], 2);
        expect(job['error'], isNull);
        expect(await SleepEditStore.pending(retryFailed: true), isEmpty);
      } finally {
        app.dispose();
      }
    },
  );

  // WHY: callers need an explicit complete outcome for settled dependent days,
  // not merely an applied own-night marker (R3-2).
  test('R3-2 engine reports complete when a later day declines', () async {
    await stored(b);
    await raw(a);
    await raw(b);
    await edit(a);
    final engine = DerivationEngine();
    expect(
      await engine.rederiveAfterSleepEdit(const Profile(), a),
      SleepEditCalculation.complete,
    );
    expect(engine.snapshot()['last_error'], isNull);
    await expectStored(b);
  });

  // WHY: a later chart point and a metric card must name the same failed
  // prerequisite, even when an earlier queued edit also exists (R3-3).
  test('R3-3 chart and day status agree on a failed earlier edit', () async {
    await edit(a);
    await edit(b);
    final failed = (await SleepEditStore.pending()).last;
    await SleepEditStore.advance(failed, SleepEditPhase.failed, error: 'disk');
    const day = '2026-11-14';
    final view = await SleepEditStore.view(day);
    final rows = await SleepEditStore.visibleRows([
      {'date': day, 'value': 55.0},
    ], key: 'rmssd');
    final chart = rows.single['sleep_edit'] as SleepEditView;
    expect(rows.single['value'], 55.0);
    expect(view.failed, isTrue);
    expect(view.dependsOn, b);
    expect(chart.toJson(), view.toJson());
  });

  // WHY: invalid input belongs inline; it is not an asynchronous save failure
  // that should follow the wearer across routes (R3-4).
  test(
    'R3-4 validation stays inline while persistence failure is retained',
    () async {
      var writes = 0;
      final coordinator = SleepCoordinator(
        persist: (_, _, _) async {
          writes++;
          throw StateError('disk');
        },
        derive: (_) async => {},
        saveSchedule: (_) async {},
      );
      try {
        final start = DateTime(2026, 11, 10, 23);
        final invalid = await coordinator.setOverride(a, start, start);
        expect(invalid.success, isFalse);
        expect(invalid.error, 'Wake time must be after the start of sleep.');
        expect(writes, 0);
        expect(coordinator.failures, isEmpty);
        final failed = await coordinator.setOverride(
          a,
          start,
          start.add(const Duration(hours: 8)),
        );
        expect(failed.success, isFalse);
        expect(writes, 1);
        expect(coordinator.failures.single.day, a);
        expect(coordinator.failures.single.message, contains('disk'));
      } finally {
        coordinator.dispose();
      }
    },
  );
  // WHY: the target already owns schema 87. Its upgrades must still run, while
  // the next rung creates edit jobs and same-version opens repair the table.
  test(
    'R3 merge migration and open repair create sleep jobs idempotently',
    () async {
      var db = await LocalDb.instance;
      await db.execute('DROP TABLE sleep_edit_job');
      await db.execute('PRAGMA user_version = ${LocalDb.schemaVersion - 1}');
      await LocalDb.close();
      db = await LocalDb.instance;
      expect(
        (await db.rawQuery('PRAGMA user_version')).single['user_version'],
        LocalDb.schemaVersion,
      );
      expect(await SleepEditStore.pending(), isEmpty);
      await edit(a);
      await LocalDb.close();
      db = await LocalDb.instance;
      expect((await SleepEditStore.pending()).map((j) => j.day), [a]);
      expect((await SleepEditStore.status(a))!['revision'], 1);
      await db.execute('DROP TABLE sleep_edit_job');
      await LocalDb.close();
      db = await LocalDb.instance;
      expect(await SleepEditStore.pending(), isEmpty);
      final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((row) => row['name']);
      expect(tables, containsAll(['sleep_edit_job', 'water_moment']));
    },
  );
}
