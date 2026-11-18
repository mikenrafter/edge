import 'support/sleep_writes.dart';
import 'support/test_callable.dart';
import 'support/sleep_edit_effects.dart';
// WHY: review round 1 of responsiveness stages 1-2. The recalculation intent
// must survive routine paths (an edit on another night, a skipped or blank
// night, a long pass), never hide a day's other measurements, and never block
// later days. Drives the production AppState runner and the real engine.
// CLAIM(sleep-edit-fence), CLAIM(sleep-edit-masking) [F1 F2 F3 F15].
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sleep_block_store.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/day_label.dart' show todayLabel;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/sleep_edit_runner.dart';
import 'backup/backup_support.dart';

const x = '2026-11-13', y = '2026-11-10', later = '2026-11-14', old = '2026-10-01';
const profile = Profile(ageYears: 30, weightKg: 70, heightCm: 175, sex: 'm');

int noon(String d) {
  final p = d.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2], 12).millisecondsSinceEpoch ~/ 1000;
}

/// A window inside the night that ends on [d]: 23:00 the evening before to 07:00.
Future<void> editDay(String d, {String source = 'manual'}) {
  final p = d.split('-').map(int.parse).toList();
  final wake = DateTime(p[0], p[1], p[2], 7).millisecondsSinceEpoch ~/ 1000;
  return TestSleepWrites.putSleepOverride(
      dayId: d, onsetTs: wake - 8 * 3600, offsetTs: wake, source: source);
}

Future<void> seedRaw(String d) async {
  final db = await LocalDb.instance;
  for (final t in [noon(d), noon(d) + 1]) {
    await db.insert('decoded_onehz', {
      'device_id': '', 'ts_ms': t * 1000, 'rec_ts': t, 'counter': t,
      'hr': 60, 'device_family': 'gen4',
    });
  }
}

/// A stored day: sleep numbers (rmssd, tst_min) AND day numbers (strain, steps).
Future<void> seedStored(String d) => LocalDb.putDayResult(
      dayId: d,
      algoVersion: kAlgoVersion,
      payloadJson: '{"date":"$d","scalars":{"strain":5,"steps":1234,'
          '"rmssd":55,"tst_min":400,"readiness":70,"rhr":52},"clinical":{"hrv_time":{"rmssd":55}}}',
      windowJson: '{}',
      rmssd: 55,
      series: const {'strain': 5, 'rmssd': 55, 'tst_min': 400},
    );

Future<List<String>> phases() async => [
      for (final r in await (await LocalDb.instance).query('sleep_edit_job', orderBy: 'day_id'))
        '${r['day_id']}:${r['phase']}:${r['applied_revision']}/${r['revision']}'
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUp(() async {
    env = await BackupEnv.create('responsiveness_sleep_fix.db');
    await LocalDb.setForeground(true);
    await LocalDb.instance;
  });
  tearDown(() async {
    DerivationEngine.debugRunning = false;
    DerivationEngine.debugSecondHalfHook = null;
    await env.dispose();
  });

  Future<PreparedDerivationDay> prepared(String d, int generation) async {
    final t = noon(d);
    return PreparedDerivationDay(
        date: d, endSec: t + 2, confidence: .8, flags: const [],
        sleepJson: const {}, hypnoStages: const [], sleepOnsetSec: 0, sleepOffsetSec: 0,
        daySub: Substrate(tsSec: [t, t + 1], hr: [60, 61], rrMs: const [], rrTsMs: const [],
            ax: const [], ay: const [], az: const [], spo2Red: const [], spo2Ir: const [],
            skinTemp: const [], skinContact: const [], deviceFamily: 'gen4'),
        sleepSub: Substrate.empty,
        sleepEditGeneration: generation);
  }

  // F1: the fence is per night. An edit on a LATER night cannot change this
  // night's measurements, so it must not refuse this night's write.
  test('an edit on a later night does not refuse this night\'s in-flight write', () async {
    await editDay(x);
    final p = await prepared(x, await SleepEditStore.generation());
    await editDay('2026-11-15'); // the user fixes a night AFTER x meanwhile
    await DerivationEngine().debugDerivePreparedDay(p, profile, noon(x) + 3);
    expect(await LocalDb.dayResult(x), isNotNull, reason: 'x\'s write is not stale');
  });

  // The fence still protects: an edit on an EARLIER night changes this night's
  // baselines, so this night's old write is refused.
  test('an edit on an earlier night still refuses this night\'s old write', () async {
    await editDay(x);
    final p = await prepared(x, await SleepEditStore.generation());
    await editDay(y);
    await DerivationEngine().debugDerivePreparedDay(p, profile, noon(x) + 3);
    expect(await LocalDb.dayResult(x), isNull);
    expect((await SleepEditStore.status(x))!['applied_revision'], 0);
  });

  // F1 + F15: the production runner through a cross-night edit made mid-run.
  test('production runner: an earlier night edited mid-run requeues, never fails, no restart', () async {
    await seedRaw(y);
    await seedRaw(x);
    await editDay(x);
    final app = AppState.forTesting();
    var fired = false;
    var derivedX = 0;
    DerivationEngine.debugSecondHalfHook = TestCall1((day) async {
      if (day == x) derivedX++;
      if (day == x && !fired) {
        fired = true;
        await editDay(y);
      }
    });
    try {
      await app.sleepEditRunner.start().timeout(const Duration(seconds: 90));
      for (var i = 0; i < 100 && (await SleepEditStore.pending()).isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(fired, true, reason: 'the cross-night edit really happened mid-run');
      expect(await phases(), ['$y:done:1/1', '$x:done:1/1']);
      expect(await LocalDb.dayResult(x), isNotNull);
      // x's own run was refused, y's later-day pass wrote x, and the requeued
      // run of x derived it once more under its own revision.
      expect(derivedX, greaterThanOrEqualTo(3),
          reason: 'the refused run is retried, not marked applied');
    } finally {
      app.dispose();
    }
  });

  // F2: an old night with no raw. The pass writes the blank night; the job must
  // finish, and the day's other measurements must never have been hidden.
  test('an old night without raw: job applied, strain and steps never hidden', () async {
    await seedStored(old);
    await editDay(old);
    final repo = LocalRepositoryImpl(getProfileMap: () => {});
    // While queued: the day keeps strain, the stale sleep numbers are withheld.
    expect((await repo.getDayStrain(old))['strain'], isNotNull, reason: 'strain stays while queued');
    expect((await repo.getDayHrv(old))['rmssd'], isNull, reason: 'stale sleep numbers are withheld');
    final app = AppState.forTesting();
    try {
      await app.sleepEditRunner.start().timeout(const Duration(seconds: 60));
      expect(await phases(), ['$old:done:1/1']);
      expect(await SleepEditStore.dirty(old), false);
      expect((await repo.getDayStrain(old))['strain'], isNotNull,
          reason: 'the day\'s other measurements survive a blank night');
    } finally {
      app.dispose();
    }
  });

  test('"Not sleep" on an old night: job applied, day not hidden', () async {
    await seedStored(old);
    await editDay(old, source: 'rejected');
    final repo = LocalRepositoryImpl(getProfileMap: () => {});
    final app = AppState.forTesting();
    try {
      await app.sleepEditRunner.start().timeout(const Duration(seconds: 60));
      expect(await phases(), ['$old:done:1/1']);
      expect((await repo.getDayStrain(old))['strain'], isNotNull);
    } finally {
      app.dispose();
    }
  });

  // The engine may store nothing for an edited night at all: raw is gone and
  // the window is only confirmed, so the pass declines and keeps what it has.
  // That is an outcome; the job must still finish [F1].
  test('a pass that declines to store anything still finishes the job', () async {
    await seedStored(old);
    await editDay(old, source: 'confirmed');
    final repo = LocalRepositoryImpl(getProfileMap: () => {});
    final app = AppState.forTesting();
    try {
      await app.sleepEditRunner.start().timeout(const Duration(seconds: 60));
      expect(await phases(), ['$old:done:1/1']);
      expect(await SleepEditStore.dirty(old), false);
      expect((await repo.getDayStrain(old))['strain'], isNotNull);
    } finally {
      app.dispose();
    }
  });

  // F15 (mutation: dirty check in _bundleAtForDate / readers): the edited
  // night's sleep numbers are withheld from non-Sleep screens too.
  test('while an edit is outstanding the night\'s sleep numbers are withheld on other screens', () async {
    await seedStored(x);
    final repo = LocalRepositoryImpl(getProfileMap: () => {});
    expect((await repo.getDayHrv(x))['rmssd'], isNotNull, reason: 'positive control: shown before the edit');
    await editDay(x);
    expect((await repo.getDayHrv(x))['rmssd'], isNull);
    expect((await repo.getDayStrain(x))['strain'], isNotNull, reason: 'day numbers stay');
  });

  // F15 (mutations: the masking in _readBundle and in the latest-day fallback).
  test('every stored-day read path withholds the edited night\'s sleep numbers', () async {
    await seedStored(x);
    final repo = LocalRepositoryImpl(getProfileMap: () => {});
    expect((await repo.getDayOverview(x))['readiness'], 70, reason: 'positive control');
    expect((await repo.getDayOverview(todayLabel()))['readiness'], 70,
        reason: 'positive control: today falls back to the latest stored day');
    await editDay(x);
    expect((await repo.getDayOverview(x))['readiness'], isNull, reason: 'exact-day read');
    expect((await repo.getDayOverview(todayLabel()))['readiness'], isNull,
        reason: 'latest-day fallback');
    expect((await repo.getDayOverview(x))['resting_hr'], isNull);
  });

  // F3: later days keep their values while an earlier night recalculates.
  test('later days keep their values while an earlier night recalculates', () async {
    await seedStored(later);
    await editDay(x);
    final repo = LocalRepositoryImpl(getProfileMap: () => {});
    expect(await SleepEditStore.dirty(later), false, reason: 'a later day is not stale itself');
    expect((await repo.getDayStrain(later))['strain'], isNotNull);
    expect((await repo.getDayHrv(later))['rmssd'], isNotNull);
  });

  test('charts: later days keep points, the edited night loses only its sleep points', () async {
    await seedStored(x);
    await seedStored(later);
    final repo = LocalRepositoryImpl(getProfileMap: () => {});
    int at(String d) => DateTime.parse('$d 12:00:00').millisecondsSinceEpoch ~/ 1000;
    Map<int, Map> points(Map<String, dynamic> c) => {
          for (final p in (c['points'] as List? ?? const [])) (p as Map)['t'] as int: p
        };
    final sleepBefore = points(await repo.getChart('tst_min'));
    expect(sleepBefore.keys, containsAll([at(x), at(later)]), reason: 'positive control');
    await editDay(x);
    final sleep = points(await repo.getChart('tst_min'));
    expect(sleep.keys, contains(at(later)), reason: 'later days keep their points');
    expect((sleep[at(later)]!['sleep_edit'] as SleepEditView).recalculating, true,
        reason: 'and say they were scored against an edit still running');
    expect(sleep.keys, isNot(contains(at(x))), reason: 'the stale night is withheld');
    final strain = points(await repo.getChart('strain'));
    expect(strain.keys, contains(at(x)), reason: 'the night\'s other series are not its sleep');
  });

  // F1: a failed job stops hiding later days.
  test('a failed job no longer masks later days, and a retry needs no restart', () async {
    await seedStored(later);
    await editDay(y);
    final runner = SleepEditRunner(effects: TestSleepEditEffects(hold: (_) {},publish: () async {},run: (_) async => throw StateError('boom')),);
    await runner.start();
    expect((await SleepEditStore.status(y))!['phase'], 'failed');
    expect(await SleepEditStore.dirty(later), false);
    final repo = LocalRepositoryImpl(getProfileMap: () => {});
    expect((await repo.getDayStrain(later))['strain'], isNotNull);
    runner.dispose();
  });

  // F1: retention is not blocked by an unrelated failed night forever, and
  // later days' pruning is not blocked while their own inputs are free.
  test('a finished edit releases retention', () async {
    await env.seedData();
    await editDay(x);
    final job = (await SleepEditStore.pending()).single;
    expect(await LocalDb.pruneDecodedBeforeRecTs(1900000000), 0);
    await (await LocalDb.instance).rawUpdate(
        'UPDATE sleep_edit_job SET applied_revision = revision WHERE day_id = ?', [x]);
    await SleepEditStore.advance(job, SleepEditPhase.done);
    expect(await LocalDb.pruneDecodedBeforeRecTs(1900000000), greaterThan(0));
  });

  // F15 (mutation: the isCurrent re-check in _deriveSleepDay): an edit that
  // arrives while the worker waits must not be derived twice.
  test('a superseded job does not derive under its old revision', () async {
    await seedRaw(x);
    await editDay(x);
    final app = AppState.forTesting();
    final derived = <String>[];
    DerivationEngine.debugSecondHalfHook = TestCall1((d) async => derived.add(d));
    try {
      DerivationEngine.debugRunning = true; // a pass is running: the worker waits
      final run = app.sleepEditRunner.start();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await editDay(x); // revision 2 arrives while revision 1 waits
      DerivationEngine.debugRunning = false;
      await run.timeout(const Duration(seconds: 90));
      expect(derived.where((d) => d == x).length, 1,
          reason: 'only the latest revision derives the night');
      expect(await phases(), ['$x:done:2/2']);
    } finally {
      app.dispose();
    }
  });

  // F15 (mutation: _sleepEditHeld in heldBesidesPower).
  test('the sleep worker holds discretionary derives while it runs, then releases', () async {
    await seedRaw(x);
    await editDay(x);
    final app = AppState.forTesting();
    try {
      DerivationEngine.debugRunning = true; // keeps the worker inside its lane
      final run = app.sleepEditRunner.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(app.debugDeriveScheduler.heldBesidesPower, true);
      DerivationEngine.debugRunning = false;
      await run.timeout(const Duration(seconds: 90));
      expect(app.debugDeriveScheduler.heldBesidesPower, false);
    } finally {
      app.dispose();
    }
  });

  // F10: the activity review's window change is one transaction with its job.
  Future<void> extendMain() async {
    final db = await LocalDb.instance;
    final wake = (await LocalDb.getSleepOverride(x))!['offset_ts'] as int;
    // The approved merge of a nap reaching the main sleep: one transaction with
    // the override and its job (the owner's explicit-merge rule).
    await db.transaction((tx) async {
      final plan=await SleepBlockStore.plan(tx,x,[AddNap(wake-1800,wake+1800)]);
      final proposal=await SleepBlockStore.preflight(tx,plan);
      expect(proposal,isA<SleepProposalMergeRequired>());
      requireSleepSaved(await SleepBlockStore.apply(plan,tx:tx,
        merge:(proposal as SleepProposalMergeRequired).proposal.authorization));
    });
  }

  test('activity review window change commits its sleep edit job in the same transaction', () async {
    await editDay(x);
    final before = (await SleepEditStore.status(x))!['revision'] as int;
    await extendMain();
    expect((await LocalDb.getSleepOverride(x))!['offset_ts'],
        greaterThan((await LocalDb.getSleepOverride(x))!['onset_ts'] as int));
    expect((await SleepEditStore.status(x))!['revision'], before + 1,
        reason: 'the window changed, so a recalculation is owed in the same commit');
    expect(await SleepEditStore.dirty(x), true);
  });

  test('activity review: a failing job write rolls the window change back', () async {
    await editDay(x);
    final window = Map.of((await LocalDb.getSleepOverride(x))!);
    await (await LocalDb.instance).execute(
        "CREATE TRIGGER reject_job_update BEFORE UPDATE ON sleep_edit_job BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END");
    await expectLater(extendMain(), throwsA(anything));
    expect((await LocalDb.getSleepOverride(x))!['offset_ts'], window['offset_ts'],
        reason: 'no new assertion without its job');
  });
}
