import 'support/sleep_writes.dart';
import 'support/test_callable.dart';
import 'support/sleep_edit_effects.dart';
// WHY: durable sleep edits must survive failed calculations and unrelated edits.
// CLAIM(sleep-edit-r2): regression cases for R2-1 through R2-4.
// catches: cancelling A retry on B; marking partial/declined applied; hiding dependent failures.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/sleep_edit_runner.dart';
import 'backup/backup_support.dart';

const a = '2026-11-10', b = '2026-11-13';
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

class _FlakyQueue implements SleepEditQueue {
  int reads = 0;
  @override
  Future<List<SleepEditJob>> pending({bool retryFailed = false}) {
    if (++reads == 1) throw StateError('queue read failed');
    return SleepEditStore.pending(retryFailed: retryFailed);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUp(() async {
    env = await BackupEnv.create('responsiveness_sleep_r2.db');
    await LocalDb.setForeground(true);
    await LocalDb.instance;
  });
  tearDown(() async {
    DerivationEngine.debugSecondHalfHook = null;
    DerivationEngine.debugRunning = false;
    await env.dispose();
  });

  test(
    'R2-1 another successful edit preserves the failed nights retry',
    () async {
      await edit(a);
      final calls = <String>[];
      final recovered = Completer<void>();
      final runner = SleepEditRunner(
        effects: TestSleepEditEffects(
          hold: (_) {},
          publish: () async {},
          run: (j) async {
            calls.add(j.day);
            if (j.day == a && calls.where((d) => d == a).length == 1) {
              throw StateError('transient');
            }
            await finish(j);
            if (j.day == a) recovered.complete();
          },
        ),
        retryDelays: const [Duration(milliseconds: 200), Duration(minutes: 1)],
      );
      try {
        await runner.start();
        expect((await SleepEditStore.status(a))!['phase'], 'failed');
        await edit(b);
        await runner.start();
        final outcome = await recovered.future
            .then((_) => 'recovered')
            .timeout(const Duration(seconds: 3), onTimeout: () => 'no retry');
        expect(
          outcome,
          'recovered',
          reason: 'failed durable work must retry without another start',
        );

        expect(calls, [a, b, a]);
        expect((await SleepEditStore.status(a))!['phase'], 'done');
      } finally {
        runner.dispose();
      }
    },
  );

  test(
    'R2-3 dependent failure remains visible after own-night publication',
    () async {
      await raw(a);
      await raw(b);
      await edit(a);
      await (await LocalDb.instance).execute(
        "CREATE TRIGGER reject_dependent_day BEFORE INSERT ON day_result WHEN NEW.day_id = '$b' BEGIN SELECT RAISE(ABORT, 'dependent write failed'); END",
      );
      final app = AppState.forTesting();
      try {
        await app.sleepEditRunner.start().timeout(const Duration(seconds: 90));
        final repo = LocalRepositoryImpl(getProfileMap: () => {});
        final night = await repo.getDaySleep(a),
            job = (await SleepEditStore.status(a))!;

        expect(
          job['phase'],
          'failed',
          reason: 'real dependent pass hit its write failure',
        );
        expect(
          job['applied_revision'],
          job['revision'],
          reason: 'the edited night committed first',
        );
        expect(night['calculation_error'], contains('Retry'));
        expect(night['recalculating'], false);
        expect((await SleepEditStore.view(a)).withholdNight, false);
        expect((await SleepEditStore.view(a)).isNone, false);
        expect(
          night['onset_ts'],
          (await LocalDb.getSleepOverride(a))!['onset_ts'],
        );
      } finally {
        app.dispose();
      }
    },
  );

  test(
    'R2-2 partial edited night retains unapplied work and recovers on retry',
    () async {
      await raw(b);
      await edit(b);
      DerivationEngine.debugSecondHalfHook = TestCall1((_) async =>
          throw StateError('transient second-half failure'));
      final app = AppState.forTesting();
      try {
        await app.sleepEditRunner.start().timeout(const Duration(seconds: 90));
        final row = await LocalDb.dayResult(b),
            job = await SleepEditStore.status(b);

        expect(row?['partial'], 1);
        expect(job!['phase'], 'failed');
        expect(job['applied_revision'], 0);
        expect(
          (await SleepEditStore.pending(retryFailed: true)).map((j) => j.day),
          [b],
        );
        DerivationEngine.debugSecondHalfHook = null;
        await app.sleepEditRunner.start(restart: true);
        expect((await LocalDb.dayResult(b))!['partial'], 0);
        expect((await SleepEditStore.status(b))!['phase'], 'done');
      } finally {
        app.dispose();
      }
    },
  );

  test(
    'R2-2 no-input confirmed window clears stale sleep values and keeps daytime values',
    () async {
      const old = '2026-10-01';
      await stored(old);
      await edit(old, source: 'confirmed');
      final repo = LocalRepositoryImpl(getProfileMap: () => {});
      expect((await repo.getDayHrv(old))['rmssd'], isNull);
      final app = AppState.forTesting();
      try {
        await app.sleepEditRunner.start().timeout(const Duration(seconds: 90));
        final hrv = await repo.getDayHrv(old),
            job = await SleepEditStore.status(old);

        expect(hrv['rmssd'], isNull);
        expect((await repo.getDayOverview(old))['readiness'], isNull);
        expect((await repo.getDayStrain(old))['strain'], 5);
        expect((await repo.getDaySleep(old))['duration_min'], isNull);
        final chart = await repo.getChart('rmssd');
        expect(chart['points'], isEmpty);
        expect(job!['phase'], 'done');
      } finally {
        app.dispose();
      }
    },
  );
  // WHY: retained values must disclose queued/failed edits even with no active pass.
  // CLAIM(sleep-edit-r2-status); catches: dropping sleep_edit in public projections.
  test(
    'R2-4 public metric and Home projections retain durable edit status',
    () async {
      await stored(b);
      await edit(a);
      final repo = LocalRepositoryImpl(getProfileMap: () => {});
      for (final phase in [SleepEditPhase.queued, SleepEditPhase.failed]) {
        await SleepEditStore.advance(
          (await SleepEditStore.pending(retryFailed: true)).single,
          phase,
        );
        for (final model in [
          await repo.getDayHrv(b),
          await repo.getDayOverview(b),
        ]) {
          expect(
            model['sleep_edit'],
            isNotNull,
            reason: 'status survives public projection: $phase',
          );
        }
        expect((await repo.getDayHrv(b))['rmssd'], 55);
        expect((await repo.getDayOverview(b))['readiness'], 70);
      }
    },
  );

  // WHY: a queue-read failure occurs outside the individual job handler.
  // CLAIM(sleep-edit-retry); catches: retry scheduled only for run failures.
  test(
    'R2-1 queue read failure retries durable work without another start',
    () async {
      await edit(a);
      final completed = Completer<void>(), errors = <Object>[];
      final runner = SleepEditRunner(
        queue: _FlakyQueue(),
        retryDelays: const [Duration(milliseconds: 10)],
        effects: TestSleepEditEffects(
          hold: (_) {},
          publish: () async {},
          onError: errors.add,
          run: (job) async {
            await finish(job);
            completed.complete();
          },
        ),
      );
      try {
        await runner.start();
        await completed.future.timeout(const Duration(seconds: 5));
        await runner.start();
        expect((await SleepEditStore.status(a))!['phase'], 'done');
        expect(errors.map((e) => '$e'), ['Bad state: queue read failed']);
      } finally {
        runner.dispose();
      }
    },
  );

  // WHY: the own night committing does not complete a failed later calculation.
  // CLAIM(sleep-edit-r2); catches: using only the own applied marker as success.
  test(
    'R2-2 dependent partial calculation retains the edit for retry',
    () async {
      await raw(a);
      await raw(b);
      await edit(a);
      DerivationEngine.debugSecondHalfHook = TestCall1((day) async {
        if (day == b) throw StateError('dependent partial');
      });
      final app = AppState.forTesting();
      try {
        await app.sleepEditRunner.start();
        expect((await LocalDb.dayResult(b))!['partial'], 1);
        final job = (await SleepEditStore.status(a))!;
        expect(job['applied_revision'], job['revision']);
        expect(job['phase'], 'failed');
        expect(
          (await SleepEditStore.pending(retryFailed: true)).map((j) => j.day),
          [a],
        );
      } finally {
        app.dispose();
      }
    },
  );
  // WHY: a confirmed window may reuse measurements only with exact bounds.
  // CLAIM(sleep-edit-r2); catches: blanking measured, matching windows.
  test(
    'R2-2 identical measured confirmed window is reused atomically',
    () async {
      await stored(a);
      await edit(a, source: 'confirmed');
      final assertion = (await LocalDb.getSleepOverride(a))!;
      final start = (assertion['onset_ts'] as int) * 1000;
      final end = (assertion['offset_ts'] as int) * 1000;
      await (await LocalDb.instance).rawUpdate(
        'UPDATE day_result SET window_json = ? WHERE day_id = ?',
        ['{"value":{"onset_ms":$start,"offset_ms":$end}}', a],
      );
      final staleFence = await SleepEditStore.generation(upTo: a);
      await edit(a, source: 'confirmed');
      expect(
        await SleepEditStore.reuseMeasuredNightIfCurrent(
          a,
          staleFence,
          algoVersion: kAlgoVersion,
        ),
        false,
      );
      expect(
        (await SleepEditStore.status(a))!['applied_revision'],
        0,
        reason: 'matching bounds cannot bypass the revision fence',
      );
      final app = AppState.forTesting();
      try {
        await app.sleepEditRunner.start();
        final repo = LocalRepositoryImpl(getProfileMap: () => {});
        expect((await SleepEditStore.status(a))!['phase'], 'done');
        expect((await repo.getDayHrv(a))['rmssd'], 55);
        expect((await repo.getDayOverview(a))['readiness'], 70);
      } finally {
        app.dispose();
      }
    },
  );

  // WHY: after own-night publication, a busy engine can refuse both passes.
  // CLAIM(sleep-edit-r2); catches: counting an unstarted pass as complete.
  test(
    'R2-2 busy engine refuses dependent retry even when own night is applied',
    () async {
      await raw(a);
      await raw(b);
      await edit(a);
      await (await LocalDb.instance).rawUpdate(
        "UPDATE sleep_edit_job SET applied_revision = revision, phase = 'dependents' WHERE day_id = ?",
        [a],
      );
      final entered = Completer<void>(), release = Completer<void>();
      DerivationEngine.debugSecondHalfHook = TestCall1((day) async {
        if (day == b) {
          entered.complete();
          await release.future;
        }
      });
      final engine = DerivationEngine();
      final otherPass = engine.runDays(const Profile(), {b}, force: true);
      try {
        await entered.future.timeout(const Duration(seconds: 10));
        expect(
          await engine.rederiveAfterSleepEdit(const Profile(), a),
          SleepEditCalculation.incomplete,
        );
        expect((await SleepEditStore.status(a))!['phase'], 'dependents');
      } finally {
        release.complete();
        await otherPass;
      }
    },
  );
}
