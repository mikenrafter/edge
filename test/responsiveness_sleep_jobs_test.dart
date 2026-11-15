// WHY: a durable assertion receipt must not wait for its worker; old workers
// cannot publish under newer times. CLAIM(sleep-edit-fence), CLAIM(sleep-receipt).
import 'dart:async';
import 'dart:io';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/sleep_edit_runner.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'backup/backup_support.dart';

const day = '2026-11-13';
Future<void> edit(int start) => LocalDb.putSleepOverride(
  dayId: day,
  onsetTs: start,
  offsetTs: start + 3600,
  source: 'manual',
);
Future<bool> result(int generation, int duration) => LocalDb.putDayResult(
  dayId: day,
  algoVersion: kAlgoVersion,
  payloadJson:
      '{"date":"$day","sleep_source":"manual","sleep":{"accounting":{"value":{"tst_sec":${duration * 60}}}}}',
  windowJson: '{}',
  reason: DayResultWrite.userOverride,
  sleepEditGeneration: generation,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUp(() async {
    env = await BackupEnv.create('responsiveness_sleep_jobs.db');
    await LocalDb.setForeground(true);
    await LocalDb.instance;
  });
  tearDown(() async {
    DerivationEngine.debugRunning = false;
    await env.dispose();
  });

  test(
    'production Save returns after durable receipt during an existing pass',
    () async {
      final app = AppState.forTesting();
      DerivationEngine.debugRunning = true;
      final clock = Stopwatch()..start();
      try {
        final saved = await app
            .setSleepOverride(
              day,
              DateTime.fromMillisecondsSinceEpoch(1000000),
              DateTime.fromMillisecondsSinceEpoch(4600000),
            )
            .timeout(const Duration(seconds: 5));
        expect(saved.success, true);
        expect(saved.recalculating, true);
        expect((await LocalDb.getSleepOverride(day))!['onset_ts'], 1000);
        expect((await SleepEditStore.pending()).single.revision, 1);
        expect(DerivationEngine().running, true);
        final newer = await app.setSleepOverride(
          day,
          DateTime.fromMillisecondsSinceEpoch(2000000),
          DateTime.fromMillisecondsSinceEpoch(5600000),
        );
        expect(newer.success, true);
        expect((await LocalDb.getSleepOverride(day))!['onset_ts'], 2000);
        expect((await SleepEditStore.pending()).single.revision, 2);
        // ignore: avoid_print
        print(
          'Sleep durable receipt with derive held ${clock.elapsedMilliseconds}ms',
        );
      } finally {
        // Dispose before releasing the synthetic pass; no unrelated real compute.
        app.dispose();
        DerivationEngine.debugRunning = false;
        await app.sleepEditRunner.start();
      }
    },
  );

  test(
    'A then B coalesces and a stale result cannot clear B or expose A metrics',
    () async {
      final repo = LocalRepositoryImpl(getProfileMap: () => {});
      await edit(1000);
      final jobA = (await SleepEditStore.pending()).single;
      final revA = await SleepEditStore.generation();
      await edit(2000);
      expect(
        await result(revA, 60),
        false,
        reason: 'stale calculation must be refused at the commit seam',
      );
      expect(
        await SleepEditStore.advance(jobA, SleepEditPhase.done),
        SleepEditAdvance.superseded,
      );
      expect((await repo.getDaySleep(day))['onset_ts'], 2000);
      expect((await repo.getDaySleep(day))['duration_min'], isNull);
      final jobs = await SleepEditStore.pending();
      expect(jobs.map((j) => j.revision), [2]);
      expect(await result(await SleepEditStore.generation(), 30), true);
      expect(
        await SleepEditStore.advance(jobs.single, SleepEditPhase.dependents),
        SleepEditAdvance.applied,
      );
      expect(await SleepEditStore.dirty(day), false);
      expect(
        await SleepEditStore.dirty('2026-11-14'),
        true,
        reason: 'dependent days stay masked until their pass completes',
      );
      expect(
        await SleepEditStore.advance(jobs.single, SleepEditPhase.done),
        SleepEditAdvance.applied,
      );
      expect((await repo.getDaySleep(day))['duration_min'], 30);
    },
  );

  test(
    'the engine carries the prepared revision to its atomic write seam',
    () async {
      final t = DateTime(2026, 11, 13, 12).millisecondsSinceEpoch ~/ 1000;
      final substrate = Substrate(
        tsSec: [t, t + 1],
        hr: [60, 61],
        rrMs: const [],
        rrTsMs: const [],
        ax: const [],
        ay: const [],
        az: const [],
        spo2Red: const [],
        spo2Ir: const [],
        skinTemp: const [],
        skinContact: const [],
        deviceFamily: 'gen4',
      );
      final prepared = PreparedDerivationDay(
        date: day,
        endSec: t + 2,
        confidence: .8,
        flags: const [],
        sleepJson: const {},
        hypnoStages: const [],
        sleepOnsetSec: 0,
        sleepOffsetSec: 0,
        daySub: substrate,
        sleepSub: Substrate.empty,
        sleepEditGeneration: await SleepEditStore.generation(),
      );
      final engine = DerivationEngine();
      const profile = Profile(
        ageYears: 30,
        weightKg: 70,
        heightCm: 175,
        sex: 'm',
      );
      await engine.debugDerivePreparedDay(prepared, profile, t + 3);
      expect(
        (await LocalDb.dayResult(day))!['day_id'],
        day,
        reason: 'positive control reaches persistence',
      );
      await (await LocalDb.instance).update('day_result', {'computed_at': 7});
      await edit(2000);
      await engine.debugDerivePreparedDay(prepared, profile, t + 3);
      expect(
        (await LocalDb.dayResult(day))!['computed_at'],
        7,
        reason: 'an old prepared worker must not publish after the edit',
      );
      expect((await SleepEditStore.status(day))!['applied_revision'], 0);
    },
  );

  test(
    'returning to the edited night publishes saved times while the writer is busy',
    () async {
      await edit(2500);
      final writer = await LocalDb.instance;
      final acquired = Completer<void>(), release = Completer<void>();
      final transaction = writer.transaction((tx) async {
        acquired.complete();
        await release.future;
      });
      await acquired.future;
      final primary = Completer<SleepData>();
      final load = SleepData.load(
        LocalRepositoryImpl(getProfileMap: () => {}),
        want: day,
        onPrimary: primary.complete,
      );
      try {
        final returned = await primary.future.timeout(
          const Duration(seconds: 5),
        );
        expect(returned.day, day);
        expect(returned.night['onset_ts'], 2500);
        expect(returned.night['wake_ts'], 6100);
        expect(returned.night['recalculating'], true);
        expect(returned.night['duration_min'], isNull);
      } finally {
        release.complete();
        await transaction;
        await load;
      }
    },
  );

  test(
    'commit and queued work survive closing and reopening the store',
    () async {
      await edit(3000);
      await LocalDb.close();
      final repo = LocalRepositoryImpl(getProfileMap: () => {});
      final returning = await repo.getDaySleep(day);
      expect(returning['onset_ts'], 3000);
      expect(returning['recalculating'], true);
      final order = <String>[];
      final runner = SleepEditRunner(
        hold: (_) {},
        publish: () async {},
        run: (job) async {
          order.add('edited');
          await result(await SleepEditStore.generation(), 20);
          await SleepEditStore.advance(job, SleepEditPhase.dependents);
          order.add('publish');
          expect(await SleepEditStore.dirty(day), false);
          order.add('later');
          await SleepEditStore.advance(job, SleepEditPhase.done);
        },
      );
      await runner.start(restart: true);
      expect(order, ['edited', 'publish', 'later']);
      expect(await SleepEditStore.pending(), isEmpty);
      expect((await repo.getDaySleep(day))['duration_min'], 20);
      runner.dispose();
    },
  );

  test(
    'worker failure keeps saved times, clears its hold and can retry',
    () async {
      await edit(4000);
      final holds = <bool>[];
      final runner = SleepEditRunner(
        hold: holds.add,
        publish: () async {},
        run: (_) => throw StateError('worker failed'),
      );
      await runner.start();
      expect(holds, [true, false]);
      expect((await SleepEditStore.status(day))!['phase'], 'failed');
      expect((await LocalDb.getSleepOverride(day))!['onset_ts'], 4000);
      expect(await SleepEditStore.dirty(day), true);
      await SleepEditStore.recalculate(day);
      expect((await SleepEditStore.pending()).single.revision, 2);
      runner.dispose();
    },
  );

  test(
    'worker timeout reports failure without cancelling its real future',
    () async {
      await edit(5000);
      final gate = Completer<void>(), failed = Completer<void>();
      final holds = <bool>[];
      final runner = SleepEditRunner(
        timeout: Duration.zero,
        hold: holds.add,
        run: (_) => gate.future,
        publish: () async {
          failed.complete();
        },
      );
      final work = runner.start();
      await failed.future;
      expect((await SleepEditStore.status(day))!['phase'], 'failed');
      expect(holds, [true]);
      await edit(6000);
      expect((await LocalDb.getSleepOverride(day))!['onset_ts'], 6000);
      runner.dispose();
      gate.complete();
      await work;
      expect(holds, [true, false]);
      expect((await SleepEditStore.pending()).single.revision, 2);
    },
  );

  test(
    'an edit protects decoded inputs from retention until it is derived',
    () async {
      await env.seedData();
      await edit(8000);
      expect(await LocalDb.pruneDecodedBeforeRecTs(1900000000), 0);
      final rows = await (await LocalDb.instance).query('decoded_onehz');
      expect(rows.length, 30, reason: 'the edit needs all retained inputs');
    },
  );

  test(
    'deleting the edited day cancels its job without replaying the assertion',
    () async {
      await edit(9000);
      final before = (await SleepEditStore.pending()).single;
      await LocalDb.deleteDays({day});
      expect(await LocalDb.getSleepOverride(day), isNull);
      expect(await SleepEditStore.pending(), isEmpty);
      expect(
        await SleepEditStore.advance(before, SleepEditPhase.done),
        SleepEditAdvance.superseded,
      );
      expect(await SleepEditStore.dirty(day), false);
    },
  );

  test('restoring a pending edit recreates local durable work', () async {
    await edit(10000);
    final file = await LocalDb.exportCopy(extras: BackupExtras.none);
    try {
      await LocalDb.wipeAll();
      await LocalDb.importFromDbFile(file);
      expect((await LocalDb.getSleepOverride(day))!['onset_ts'], 10000);
      expect((await SleepEditStore.pending()).single.day, day);
      expect(await SleepEditStore.dirty(day), true);
    } finally {
      await File(file).delete();
    }
  });

  test(
    'assertion and dirty intent both roll back when the receipt fails',
    () async {
      final db = await LocalDb.instance;
      await db.execute(
        "CREATE TRIGGER reject_sleep_job BEFORE INSERT ON sleep_edit_job BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END",
      );
      await expectLater(edit(7000), throwsA(anything));
      final app = AppState.forTesting();
      final refused = await app.setSleepOverride(
        day,
        DateTime.fromMillisecondsSinceEpoch(7000000),
        DateTime.fromMillisecondsSinceEpoch(10600000),
      );
      expect(
        refused.success,
        false,
        reason: 'the UI must never receive a saved receipt after rollback',
      );
      app.dispose();
      expect(await LocalDb.getSleepOverride(day), isNull);
      expect(await SleepEditStore.pending(), isEmpty);
    },
  );
}
