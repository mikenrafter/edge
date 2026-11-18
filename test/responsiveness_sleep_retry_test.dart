import 'support/sleep_writes.dart';
import 'support/sleep_edit_effects.dart';
// WHY: a recalculation that did not finish must come back on its own. A
// refused or interrupted run is requeued, a failed one is retried in-process
// with a backoff, and waiting on a long pass is not a failure [F1].
// CLAIM(sleep-edit-retry).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/sleep_edit_runner.dart';
import 'backup/backup_support.dart';

const day = '2026-11-13';
Future<void> edit(String d, [int start = 1000]) => TestSleepWrites.putSleepOverride(
    dayId: d, onsetTs: localDayStartSec(d)!+start, offsetTs: localDayStartSec(d)!+start+3600, source: 'manual');
Future<void> finish(SleepEditJob job) async {
  await (await LocalDb.instance).rawUpdate(
      'UPDATE sleep_edit_job SET applied_revision = revision WHERE day_id = ?', [job.day]);
  await SleepEditStore.advance(job, SleepEditPhase.done);
}

Future<void> until(Future<bool> Function() ok) async {
  for (var i = 0; i < 200; i++) {
    if (await ok()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUp(() async {
    env = await BackupEnv.create('responsiveness_sleep_retry.db');
    await LocalDb.setForeground(true);
    await LocalDb.instance;
  });
  tearDown(() async {
    DerivationEngine.debugRunning = false;
    await env.dispose();
  });

  test('the fence counts the edited night and earlier nights, not later ones', () async {
    await edit('2026-11-10');
    await edit(day);
    await edit('2026-11-15');
    expect(await SleepEditStore.generation(upTo: '2026-11-10'), 1);
    expect(await SleepEditStore.generation(upTo: day), 2);
    expect(await SleepEditStore.generation(), 3);
    await edit('2026-11-15', 2000);
    expect(await SleepEditStore.generation(upTo: day), 2,
        reason: 'a later night\'s edit does not move this night\'s fence');
  });

  test('a requeued run is attempted again without a restart and never marked failed', () async {
    await edit(day);
    final calls = <int>[];
    final phasesSeen = <String>[];
    final runner = SleepEditRunner(effects: TestSleepEditEffects(hold: (_) {},publish: () async {},run: (job) async {
          calls.add(job.revision);
          phasesSeen.add('${(await SleepEditStore.status(day))!['phase']}');
          if (calls.length == 1) throw const SleepEditRequeue('an earlier night was edited');
          await finish(job);
        }),);
    await runner.start();
    expect(calls, [1, 1]);
    expect(phasesSeen, ['queued', 'queued'], reason: 'requeued, never failed');
    expect((await SleepEditStore.status(day))!['phase'], 'done');
    runner.dispose();
  });

  test('a run that keeps being refused ends as a visible failure, not a hot loop', () async {
    await edit(day);
    var calls = 0;
    final runner = SleepEditRunner(effects: TestSleepEditEffects(hold: (_) {},publish: () async {},run: (job) async {
          calls++;
          throw const SleepEditRequeue('refused again');
        }),maxRequeues: 3,retryDelays: const []);
    await runner.start();
    expect(calls, 3);
    final status = (await SleepEditStore.status(day))!;
    expect(status['phase'], 'failed');
    expect(status['error'], contains('refused again'));
    runner.dispose();
  });

  test('a failed job is retried in-process with a backoff', () async {
    await edit(day);
    var calls = 0;
    final runner = SleepEditRunner(effects: TestSleepEditEffects(hold: (_) {},publish: () async {},run: (job) async {
          calls++;
          if (calls == 1) throw StateError('disk busy');
          await finish(job);
        }),retryDelays: const [Duration(milliseconds: 30)]);
    await runner.start();
    expect((await SleepEditStore.status(day))!['phase'], 'failed');
    await until(() async => (await SleepEditStore.status(day))!['phase'] == 'done');
    expect(calls, 2, reason: 'retried without start(restart: true) and without a new edit');
    runner.dispose();
  });

  test('disposing the runner cancels a scheduled retry', () async {
    await edit(day);
    var calls = 0;
    final runner = SleepEditRunner(effects: TestSleepEditEffects(hold: (_) {},publish: () async {},run: (job) async {
          calls++;
          throw StateError('still failing');
        }),retryDelays: const [Duration(milliseconds: 50)]);
    await runner.start();
    runner.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(calls, 1);
  });

  test('a new edit supersedes a failed job and runs at once', () async {
    await edit(day);
    final revisions = <int>[];
    final runner = SleepEditRunner(effects: TestSleepEditEffects(hold: (_) {},publish: () async {},run: (job) async {
          revisions.add(job.revision);
          if (job.revision == 1) throw StateError('first fails');
          await finish(job);
        }),retryDelays: const [Duration(hours: 1)]);
    await runner.start();
    await SleepEditStore.recalculate(day);
    await runner.start();
    expect(revisions, [1, 2]);
    expect((await SleepEditStore.status(day))!['phase'], 'done');
    runner.dispose();
  });

  // F1: a pass that outlasts the wait is not a failure of the edit.
  test('production runner: waiting out a long pass requeues instead of failing', () async {
    await edit(day);
    final app = AppState.forTesting();
    app.sleepEditWaitLimit = const Duration(milliseconds: 250);
    try {
      DerivationEngine.debugRunning = true;
      final run = app.sleepEditRunner.start();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect((await SleepEditStore.status(day))!['phase'], isNot('failed'),
          reason: 'several waits have expired by now');
      DerivationEngine.debugRunning = false;
      await run.timeout(const Duration(seconds: 90));
      await until(() async => (await SleepEditStore.pending()).isEmpty);
      expect((await SleepEditStore.status(day))!['phase'], 'done');
    } finally {
      app.dispose();
    }
  });
}
