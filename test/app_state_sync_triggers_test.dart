// 8AJ seam 5 characterization: the ways a sync is started over a live link
// (forceResync, foregroundCatchUp, the manual / pull-to-sync path, the burst
// loop they share), the single-flight rule, and what each leaves behind: the
// derive trigger, the data edge, the log and the notify count. Through
// AppState with a [SyncFakeEngine]. Must pass before and after the
// SyncController move.
//
// IosBgTask.foregroundPull is assigned only by the real AppState constructor
// (forTesting does not), so the BGTask -> foregroundCatchUp hook is pinned by
// source in seam5_delegation_test.dart.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/ios_bg_task.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'split8aj_seam5_triggers.db';

bool _logged(SyncRig rig, String text) =>
    rig.app.logLines.any((l) => l.contains(text));

/// A connected, drained foreground session with a clean slate behind it.
Future<void> _open(SyncRig rig) async {
  await rig.openAndSettle();
  await rig.clearJobs();
  rig.engine.events.clear();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  test('forTesting leaves the BGTask hook unwired', () {
    expect(IosBgTask.foregroundPull, isNull);
  });

  group('forceResync', () {
    test('with no link it does nothing at all', syncCase((rig, timers) async {
      final ticks = TickCounter(rig.app);
      await rig.app.forceResync();
      expect(rig.engine.events, isEmpty);
      expect(ticks.ticks, 0);
      expect(await rig.jobTypes(), isEmpty);
      ticks.stop();
    }));

    test('over a live link: a KICKED offload (history request, then the '
        'drain), then a light derive and a notify', syncCase((rig, timers) async {
      await _open(rig);
      final ticks = TickCounter(rig.app);
      await rig.app.forceResync();
      expect(rig.engine.events, ['requestHistorySync', 'runSync:180']);
      await rig.jobQueued('derive_light');
      await rig.settleDerive(const Duration(seconds: 8));
      await rig.quiesce();
      expect(await rig.jobTypes(), ['derive_light']);
      expect(ticks.ticks, 4, reason: 'its own notify, the clean drain\'s last-sync stamp, and two from the scheduler queueing the job');
      ticks.stop();
    }));

    test('a drain that moved nothing still asks for the light derive',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncScript.add(SyncReport(0, 0, false));
      await rig.app.forceResync();
      await rig.jobQueued('derive_light');
    }));

    test('it waits out a burst already in flight, then runs its own',
        syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      rig.engine.events.clear();
      var done = false;
      final resync = rig.app.forceResync().then((_) => done = true);
      await rig.quiesce();
      expect(rig.engine.count('requestHistorySync'), 0);
      expect(done, isFalse);
      rig.engine.syncGate!.complete();
      await resync;
      expect(rig.engine.count('requestHistorySync'), 1);
      expect(rig.engine.count('runSync'), 1, reason: 'its own, after the first one finished');
      await rig.quiesce();
    }));

    test('a failure is logged, never thrown, and the single-flight latch is '
        'clear for the next call', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.requestSyncThrows = StateError('no link');
      final ticks = TickCounter(rig.app);
      await rig.app.forceResync();
      expect(_logged(rig, 'Resync failed: Bad state: no link'), isTrue);
      expect(ticks.ticks, 0);
      await rig.quiesce();
      expect(await rig.jobTypes(), isEmpty);
      rig.engine.requestSyncThrows = null;
      await rig.app.forceResync();
      expect(rig.engine.count('runSync'), 1);
      ticks.stop();
    }));

    test('if the burst it waits on fails, that failure is not its own: it '
        'goes on to run its own offload and the light derive',
        syncCase((rig, timers) async {
      // FIXED (was LATENT): the awaited burst's throw used to surface as
      // "Resync failed" and skip the caller's own offload, so a workout
      // window the failed burst never pulled stayed unpulled until the next
      // periodic tick. The code's own comment is "wait out the burst, THEN
      // re-trigger"; the burst's owner already logged its failure.
      rig.engine.syncGate = Completer<void>();
      rig.engine.syncScript.add(StateError('first burst failed'));
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      final resync = rig.app.forceResync();
      rig.engine.syncGate!.complete();
      await resync;
      expect(_logged(rig, 'Resync failed'), isFalse);
      await rig.waitFor(() => _logged(rig, 'Background sync burst failed: Bad state: first burst failed'));
      expect(rig.engine.count('requestHistorySync'), 1);
      expect(rig.engine.count('runSync'), 2, reason: 'the failed one, then its own');
      await rig.jobQueued('derive_light');
      await rig.quiesce();
    }));

    test('after waiting out a failed burst, a failure of its OWN offload is '
        'still logged, never thrown', syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      rig.engine.syncScript
          .addAll([StateError('first burst failed'), StateError('own failed')]);
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      final resync = rig.app.forceResync();
      rig.engine.syncGate!.complete();
      await resync;
      expect(_logged(rig, 'Resync failed: Bad state: own failed'), isTrue);
      expect(rig.engine.count('requestHistorySync'), 1);
      await rig.quiesce();
    }));
  });

  group('foregroundCatchUp', () {
    test('with no link it does nothing', syncCase((rig, timers) async {
      await rig.app.foregroundCatchUp();
      expect(rig.engine.events, isEmpty);
    }));

    test('a granted catch-up JOINS the offload (no history request) and '
        'queues a light derive when records came', syncCase((rig, timers) async {
      await _open(rig);
      final ticks = TickCounter(rig.app);
      await rig.app.foregroundCatchUp();
      expect(rig.engine.events, ['requestForegroundSync', 'runSync:180']);
      expect(_logged(rig, 'Foreground catch-up: 3 records pulled.'), isTrue);
      await rig.jobQueued('derive_light');
      await rig.settleDerive(const Duration(seconds: 8));
      await rig.quiesce();
      expect(ticks.ticks, 4, reason: 'its own notify, the clean drain\'s last-sync stamp, and two from the scheduler queueing the job');
      ticks.stop();
    }));

    test('a catch-up that brought nothing queues nothing; its only notify is '
        'the clean drain\'s last-sync stamp',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncScript.add(SyncReport(0, 1, true));
      final ticks = TickCounter(rig.app);
      await rig.app.foregroundCatchUp();
      await rig.quiesce();
      expect(await rig.jobTypes(), isEmpty);
      expect(ticks.ticks, 1);
      expect(_logged(rig, 'Foreground catch-up: 0 records pulled.'), isTrue);
      ticks.stop();
    }));

    test('floored by the engine (90 s): asked, nothing else', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.foregroundSyncAllowed = false;
      await rig.app.foregroundCatchUp();
      expect(rig.engine.events, ['requestForegroundSync']);
    }));

    test('a burst already in flight: it does not even ask the engine',
        syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      rig.engine.events.clear();
      await rig.app.foregroundCatchUp();
      expect(rig.engine.events, isEmpty);
    }));

    test('a stale link is torn down instead (which re-arms the reconnect '
        'through the disconnect edge)', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.liveArmed = true;
      rig.engine.quiet = const Duration(seconds: 31);
      await rig.app.foregroundCatchUp();
      expect(rig.engine.count('disconnect'), 1);
      expect(rig.engine.count('requestForegroundSync'), 0);
      await rig.waitFor(() => rig.engine.count('markReconnecting') >= 1);
      await rig.quiesce();
    }));

    test('a failing drain is logged', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncScript.add(StateError('burst failed'));
      await rig.app.foregroundCatchUp();
      expect(_logged(rig, 'Foreground catch-up sync failed: Bad state: burst failed'), isTrue);
      expect(await rig.jobTypes(), isEmpty);
    }));
  });

  group('the burst loop (every trigger shares it)', () {
    test('no batch acknowledged: one session and out', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncScript.add(SyncReport(0, 0, false));
      await rig.app.forceResync();
      expect(rig.engine.count('runSync'), 1);
      expect(_logged(rig, 'Backfill stop — no batch ACKs; trim did not advance.'), isTrue);
    }));

    test('complete with no backlog: out after one session',
        syncCase((rig, timers) async {
      await _open(rig);
      await rig.app.forceResync();
      expect(rig.engine.count('runSync'), 1);
      expect(_logged(rig, 'Backfill stop — history complete acknowledged by strap.'), isTrue);
    }));

    test('a frontier that did not move with nothing behind it ends the loop',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncScript.add(SyncReport(2, 1, false));
      await rig.app.forceResync();
      expect(rig.engine.count('runSync'), 1);
      expect(_logged(rig, 'Backfill stop — frontier did not advance and no backlog remains'), isTrue);
    }));

    test('while the frontier advances and the strap still reports newer data, '
        'it continues: a history request before EVERY session, the data edge '
        'follows the frontier and each advance notifies',
        syncCase((rig, timers) async {
      await _open(rig);
      const newest = 1800000000;
      rig.engine.newestTs = newest;
      var n = 0;
      rig.engine.onRunSync = () async {
        n++;
        await LocalDb.setCursor('rec_ts_hw', '${newest - 1000 + n * 300}');
      };
      rig.engine.syncScript.addAll([
        SyncReport(5, 1, false),
        SyncReport(5, 1, false),
        SyncReport(5, 1, true),
      ]);
      final ticks = TickCounter(rig.app);
      await rig.app.forceResync();
      expect(rig.engine.events.where((e) => e.startsWith('request') || e.startsWith('runSync')).toList(), [
        'requestHistorySync', 'runSync:180',
        'requestHistorySync', 'runSync:180',
        'requestHistorySync', 'runSync:180',
      ]);
      expect(rig.app.lastRecordAt,
          DateTime.fromMillisecondsSinceEpoch((newest - 1000 + 3 * 300) * 1000));
      expect(_logged(rig, 'Backfill continuation 1/20 — frontier still behind strap newest'), isTrue);
      await rig.quiesce();
      expect(ticks.ticks, greaterThanOrEqualTo(4), reason: 'three advances plus the final notify');
      ticks.stop();
    }));

    test('a frontier stuck on a stale-timestamp block with a backlog behind '
        'it is drained THROUGH, bounded at 20 sessions',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.newestTs = 1800000000;
      await LocalDb.setCursor('rec_ts_hw', '1700000000');
      rig.engine.syncScript.addAll([for (var i = 0; i < 30; i++) SyncReport(1, 1, false)]);
      await rig.app.forceResync();
      expect(rig.engine.count('runSync'), 20);
      expect(_logged(rig, 'Backfill continuation 1/20 — frontier stuck on a stale-timestamp block'), isTrue);
      await rig.quiesce();
    }));

    test('a terminal Stuck connection runs no session at all',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.stuck = true;
      await rig.app.forceResync();
      expect(rig.engine.count('runSync'), 0);
      expect(_logged(rig, 'Backfill stop — history is terminal (Stuck) for this connection'), isTrue);
    }));

    test('the data edge never moves backwards', syncCase((rig, timers) async {
      await _open(rig);
      await LocalDb.setCursor('rec_ts_hw', '1750000500');
      rig.engine.onRunSync = () async {};
      await rig.app.forceResync();
      expect(rig.app.lastRecordAt,
          DateTime.fromMillisecondsSinceEpoch(1750000500 * 1000));
      await LocalDb.setCursor('rec_ts_hw', '1750000100');
      await rig.app.forceResync();
      expect(rig.app.lastRecordAt,
          DateTime.fromMillisecondsSinceEpoch(1750000500 * 1000));
      await rig.quiesce();
    }));

    test('the link dropping mid-loop ends it with the last report',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.newestTs = 1800000000;
      rig.engine.onRunSync = () async => rig.engine.link = false;
      rig.engine.syncScript.addAll([SyncReport(1, 1, false), SyncReport(1, 1, false)]);
      await rig.app.forceResync();
      expect(rig.engine.count('runSync'), 1);
      await rig.quiesce();
    }));
  });

  group('the manual sync (Sync now, pull-to-sync)', () {
    test('over a live link: kicked offload, then the changed-only HEAVY derive; '
        'the presentation settles on completed', syncCase((rig, timers) async {
      await _open(rig);
      expect(rig.app.syncPresentation.phase, 'idle');
      await rig.app.syncNow(); // the AppState entry: same coordinator
      expect(rig.engine.events, ['requestHistorySync', 'runSync:180']);
      expect(rig.passes, hasLength(1));
      expect(rig.passes.single.heavy, isTrue);
      expect(rig.passes.single.changedOnly, isTrue);
      expect(rig.app.syncPresentation.phase, 'completed');
      expect(rig.app.syncPresentation.busy, isFalse);
      expect(rig.app.syncPresentation.lastSuccess, isNotNull);
    }));

    test('with the link down it opens the session first, then JOINS the burst '
        'openSession already started (single flight): no history request of '
        'its own, one drain', syncCase((rig, timers) async {
      final result = await rig.app.syncOperations.syncNow();
      expect(result.success, isTrue);
      expect(rig.engine.count('connect'), 1);
      expect(rig.engine.count('requestHistorySync'), 0);
      expect(rig.engine.count('runSync'), 1);
      await rig.quiesce();
    }));

    test('no band paired: a failure with the reason, no engine call',
        syncCase((rig, timers) async {
      final result = await rig.app.syncOperations.syncNow();
      expect(result.success, isFalse);
      expect(result.error, contains('Pair a band before syncing'));
      expect(rig.app.syncPresentation.phase, 'failed');
      expect(rig.engine.events, isEmpty);
    }, paired: false));

    test('the band cannot be reached: a failure', syncCase((rig, timers) async {
      rig.engine.connectScript.add(false);
      final result = await rig.app.syncOperations.syncNow();
      expect(result.success, isFalse);
      expect(result.error, contains('Could not connect to the band'));
      expect(rig.app.syncPresentation.phase, 'failed');
      expect(rig.engine.count('requestHistorySync'), 0);
    }));

    test('a download that stopped with nothing banked is a failure and runs '
        'no derive', syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncScript.add(SyncReport(0, 0, false));
      final result = await rig.app.syncOperations.syncNow();
      expect(result.success, isFalse);
      expect(result.error, contains('Download stopped before completion. Retry sync.'));
      expect(rig.passes, isEmpty);
    }));

    test('a download that stopped early WITH progress is a partial success '
        'and still calculates', syncCase((rig, timers) async {
      await _open(rig);
      var n = 0;
      rig.engine.onRunSync = () async =>
          LocalDb.setCursor('rec_ts_hw', '${1750000000 + ++n}');
      rig.engine.syncScript.add(SyncReport(10, 1, false));
      final result = await rig.app.syncOperations.syncNow();
      expect(result.success, isTrue);
      expect(result.partial, isTrue);
      expect(rig.passes, hasLength(1));
      expect(rig.app.syncPresentation.partial, isTrue);
    }));

    test('a terminal Stuck connection is a failure even with progress',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.stuck = true;
      final result = await rig.app.syncOperations.syncNow();
      expect(result.success, isFalse);
    }));

    test('a derive that never reports its scope is reported as another '
        'calculation holding the lock', syncCase((rig, timers) async {
      await _open(rig);
      rig.app.debugDeriveRun = deriveHook(reportScope: false, calls: rig.passes);
      final result = await rig.app.syncOperations.syncNow();
      expect(result.success, isFalse);
      expect(result.error, contains('Another calculation was running. Retry sync.'));
    }));

    test('a second call while one runs joins it (one download)',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncGate = Completer<void>();
      final a = rig.app.syncOperations.syncNow();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      final b = rig.app.syncOperations.syncNow();
      rig.engine.syncGate!.complete();
      final ra = await a;
      final rb = await b;
      expect(identical(ra, rb), isTrue);
      expect(rig.engine.count('runSync'), 1);
    }));

    test('the coordinator\'s deadline: the run is retired, the presentation '
        'fails and is not busy, and a later sync runs normally',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.engine.syncGate = Completer<void>();
      final first = rig.app.syncOperations.syncNow();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      timers.activeOneShot(const Duration(minutes: 65)).single.fire();
      final r = await first;
      expect(r.success, isFalse);
      expect(rig.app.syncPresentation.busy, isFalse);
      expect(rig.app.syncPresentation.phase, 'failed');
      rig.engine.syncGate!.complete();
      await rig.quiesce();
      rig.engine.syncGate = null;
      final again = await rig.app.syncOperations.syncNow();
      expect(again.success, isTrue);
    }));

    test('refreshData (pull-to-refresh) with no link reloads local data and '
        'never touches the band', syncCase((rig, timers) async {
      final before = rig.app.insightsRevision.value;
      await rig.app.refreshData();
      expect(rig.app.syncPresentation.phase, 'offline');
      expect(rig.app.insightsRevision.value, before + 1);
      expect(rig.engine.events, isEmpty);
    }));

    test('refreshData over a live link is a real sync', syncCase((rig, timers) async {
      await _open(rig);
      await rig.app.refreshData();
      expect(rig.engine.count('runSync'), 1);
      expect(rig.app.syncPresentation.phase, 'completed');
    }));
  });
}
