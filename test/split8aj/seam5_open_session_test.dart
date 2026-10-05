// 8AJ seam 5 characterization: openSession, the connect -> drain -> after-drain
// derive trigger path, through AppState. What it asks the engine and in what
// order, what flags and timers it leaves, how many times it notifies, and what
// each failure path does to the flags (AGENTS 4.3). Must pass before and after
// the SyncController move.
//
// The engine is a [SyncFakeEngine]; timers are hand-fired ([SyncTimers]); the
// derive trigger is read from the durable compute_jobs rows.
//
// Platform branches (Android Edge Tracking, the iOS restore central) cannot be
// taken on the Linux host. IosBleRestore.foregroundActive is a plain static,
// set with no platform check, so it is observable and pinned.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ios_ble_restore.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';

import 'support/sync_harness.dart';

const _db = 'split8aj_seam5_open_session.db';

List<String> _ev(SyncRig rig) => rig.engine.events;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  group('guards', () {
    test('no paired band: nothing is touched, nothing notifies',
        syncCase((rig, timers) async {
      final ticks = TickCounter(rig.app);
      await rig.app.openSession();
      expect(_ev(rig), isEmpty);
      expect(ticks.ticks, 0);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(rig.app.busy, isFalse);
      expect(timers.live, isEmpty);
      ticks.stop();
    }, paired: false));

    test('already busy: a second call is a no-op (no engine call, no tick, '
        'no intent)', syncCase((rig, timers) async {
      rig.app.busy = true;
      final ticks = TickCounter(rig.app);
      await rig.app.openSession();
      expect(_ev(rig), isEmpty);
      expect(ticks.ticks, 0);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(rig.app.busy, isTrue, reason: 'it must not clear someone else\'s latch');
      ticks.stop();
      rig.app.busy = false;
    }));

    test('two concurrent calls: the second returns at once while the first is '
        'parked in connect', syncCase((rig, timers) async {
      final gate = rig.holdConnect();
      final first = rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      expect(rig.app.busy, isTrue);
      await rig.app.openSession();
      expect(rig.engine.count('connect'), 1);
      gate.complete();
      await first;
      expect(rig.app.busy, isFalse);
    }));
  });

  group('a successful session', () {
    test('engine call order: foreground, connect with the band id and the '
        'pinned generation, polls, prompt, live reconcile, then the drain',
        syncCase((rig, timers) async {
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      await rig.jobQueued('derive_heavy');
      expect(_ev(rig).sublist(0, 6), [
        'setBackground:false',
        'connect:$kRemoteId:gen4',
        'getBattery',
        'getStrapName',
        'prompt:false',
        'reconcile',
      ]);
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
      expect(_ev(rig).sublist(6), ['runSync:180', 'prompt:false']);
      expect(rig.engine.count('requestHistorySync'), 0,
          reason: 'the connect already started the offload (kickFirst: false)');
    }));

    test('busy is true only while connecting, and the burst runs after '
        'openSession has returned', syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      final gate = rig.holdConnect();
      final open = rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      expect(rig.app.busy, isTrue);
      gate.complete();
      await open;
      expect(rig.app.busy, isFalse);
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      expect(rig.app.busy, isFalse, reason: 'the drain is concurrent, not awaited');
      expect(await rig.jobTypes(), isEmpty, reason: 'no trigger before the drain ends');
      rig.engine.syncGate!.complete();
      await rig.jobQueued('derive_heavy');
    }));

    test('ownership: intent on, foreground lease held, iOS restore flag set, '
        'and the supervisor and backfill timers armed', syncCase((rig, timers) async {
      await rig.app.openSession();
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      expect(IosBleRestore.foregroundActive, isTrue,
          reason: 'set with no platform check');
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      // A second headless claim is skipped, not queued.
      expect(BandOwnership.tryAcquireHeadless(), isNull);
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
    }));

    test('the post-drain step re-reads the band prompt FIRST and only then '
        'requests the heavy derive', syncCase((rig, timers) async {
      await rig.app.openSession();
      await rig.jobQueued('derive_heavy');
      // Two prompt writes, neither of which saw a queued job: the connect-time
      // one and the post-drain one, both ahead of the heavy request.
      expect(rig.engine.promptStamps, ['', '']);
      expect(await rig.jobTypes(), ['derive_heavy']);
    }));

    test('the heavy request is a scheduled job, held by a settle timer, and '
        'the pass it runs is the HEAVY, all-days one', syncCase((rig, timers) async {
      await rig.app.openSession();
      await rig.jobQueued('derive_heavy');
      await rig.waitFor(() => timers.activeOneShot(const Duration(seconds: 2)).isNotEmpty);
      expect(rig.app.derivePending, isTrue);
      timers.activeOneShot(const Duration(seconds: 2)).single.fire();
      await rig.waitFor(() => rig.passes.isNotEmpty);
      expect(rig.passes.single.heavy, isTrue);
    }));

    test('a drain that stopped early still requests the heavy derive (only '
        'the log differs)', syncCase((rig, timers) async {
      rig.engine.syncScript.add(SyncReport(40, 2, false));
      await rig.app.openSession();
      await rig.jobQueued('derive_heavy');
      expect(rig.app.logLines.any((l) => l.contains('Backlog drained: 40 records in 2 batches (stopped early)')), isTrue);
    }));

    test('notifies 3 times to open (busy, connected state, idle) and 4 more '
        'when the drain lands (derive queued, settle armed, completion, the '
        'last-sync stamp)',
        syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      final ticks = TickCounter(rig.app);
      await rig.app.openSession();
      expect(ticks.ticks, 3);
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      rig.engine.syncGate!.complete();
      await rig.jobQueued('derive_heavy');
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
      await rig.settleDerive();
      await rig.quiesce();
      expect(ticks.ticks, 7);
      ticks.stop();
    }));

    test('the engine is told it is foreground before anything else',
        syncCase((rig, timers) async {
      await rig.app.pauseForBackground();
      rig.engine.events.clear();
      await rig.app.openSession();
      expect(_ev(rig).first, 'setBackground:false');
      expect(rig.app.debugLiveOwners.foreground, isTrue);
    }));
  });

  group('failure paths', () {
    test('the band cannot be reached: busy, intent and lease are released, '
        'the backfill timer never starts, but the supervisor stays and the '
        'iOS restore flag stays set', syncCase((rig, timers) async {
      rig.engine.connectScript.add(false);
      await rig.app.openSession();
      expect(rig.app.busy, isFalse);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1),
          reason: 'we still WANT a link; the supervisor retries it');
      expect(_ev(rig), ['setBackground:false', 'connect:$kRemoteId:gen4']);
      expect(rig.app.logLines, contains('Session start: could not reach the band.'));
      // FIXED (was LATENT, AGENTS 4.3): the flag is set before the connect, so
      // the exit that leaves no link must clear it, or on iOS the native
      // restore wake no-ops until a connect lands. (Reset directly: the
      // recovery arm is iOS-only, and the flag is a plain static.)
      expect(IosBleRestore.foregroundActive, isFalse);
      expect(rig.app.status, 'disconnected');
    }));

    test('the connect throws: same cleanup, the throw is logged not rethrown',
        syncCase((rig, timers) async {
      rig.engine.connectScript.add(StateError('gatt 133'));
      await rig.app.openSession();
      expect(rig.app.busy, isFalse);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(BandOwnership.owner, isNull);
      // FIXED (was LATENT): the throw exit clears the iOS restore flag too.
      expect(IosBleRestore.foregroundActive, isFalse);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(rig.app.logLines, contains('Session start failed: Bad state: gatt 133'));
    }));

    test('a poll throws after the link is up: the half-built session is torn '
        'down (link dropped, not left up with no drain) and the reconnect loop '
        'that the drop starts brings it fully up: drain, backfill timer, intent '
        'and lease', syncCase((rig, timers) async {
      // FIXED (was LATENT): a throw after the connect used to leave the link
      // up with the intent and lease held, no drain and no backfill timer. A
      // session is fully up or torn down. One-shot so the retry's poll works.
      rig.engine.batteryThrowsOnce = StateError('no reply');
      await rig.app.openSession();
      expect(rig.app.busy, isFalse);
      expect(rig.app.logLines, contains('Session start failed: Bad state: no reply'));
      expect(rig.engine.count('disconnect'), 1,
          reason: 'the link is torn down, not left half open');
      // The disconnect edge starts the loop; it re-runs the whole setup.
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      await rig.waitFor(() => timers.activePeriodic(kBackfillEvery).isNotEmpty);
      expect(rig.engine.count('connect'), 2);
      expect(rig.engine.isConnected, isTrue);
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      await rig.jobQueued('derive_heavy');
    }));

    test('the link is gone by the time the session settles: the finally clears '
        'intent and lease even though the connect had answered true',
        syncCase((rig, timers) async {
      rig.engine.batteryHook = () async => rig.engine.link = false;
      await rig.app.openSession();
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(rig.app.busy, isFalse);
    }));

    test('the drain throws: logged, no derive request, the link and the '
        'intent stay, the backfill timer is armed', syncCase((rig, timers) async {
      rig.engine.syncScript.add(StateError('burst failed'));
      await rig.app.openSession();
      await rig.waitFor(() => rig.app.logLines.any((l) => l.contains('Background sync burst failed')));
      expect(rig.app.logLines, contains('Background sync burst failed: Bad state: burst failed'));
      await rig.quiesce();
      expect(await rig.jobTypes(), isEmpty);
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      expect(rig.app.busy, isFalse);
    }));

    test('the band is unpaired while the connect is parked: the session '
        'carries on with the band it captured and does not wedge busy',
        syncCase((rig, timers) async {
      final gate = rig.holdConnect();
      final open = rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      rig.app.paired = null;
      gate.complete();
      await open;
      expect(rig.app.busy, isFalse);
      expect(rig.engine.count('getBattery'), 1);
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
    }));

    test('a failed connect and a later openSession: the second attempt runs '
        '(nothing latched)', syncCase((rig, timers) async {
      rig.engine.connectScript.add(false);
      await rig.app.openSession();
      await rig.app.openSession();
      expect(rig.engine.count('connect'), 2);
      expect(rig.app.busy, isFalse);
      expect(BandOwnership.foregroundIntent, isTrue);
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
    }));
  });

  group('resuming from the background with the link still up', () {
    // A real engine never hands back 'connected' without data; the fake's
    // sinceLastRx / liveEnabled / probeAnswer say how quiet the link is.
    Future<void> open(SyncRig rig) async {
      await rig.openAndSettle();
      await rig.app.pauseForBackground();
      rig.engine.events.clear();
    }

    test('a fresh link is reclaimed: no connect, no busy, the foreground '
        'intent is raised again, and a foreground catch-up starts',
        syncCase((rig, timers) async {
      await open(rig);
      final ticks = TickCounter(rig.app);
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      expect(rig.engine.count('connect'), 0);
      expect(rig.engine.count('disconnect'), 0);
      expect(_ev(rig).first, 'setBackground:false');
      expect(rig.engine.count('requestForegroundSync'), 1);
      expect(rig.engine.count('requestHistorySync'), 0);
      expect(rig.app.busy, isFalse);
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(rig.app.debugLiveOwners.foreground, isTrue);
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      ticks.stop();
    }));

    test('a quiet link with a live stream armed is torn down and reconnected',
        syncCase((rig, timers) async {
      await open(rig);
      rig.engine.liveArmed = true;
      rig.engine.quiet = const Duration(seconds: 45);
      await rig.app.openSession();
      expect(rig.engine.count('probe'), 0);
      expect(rig.engine.count('disconnect'), 1);
      expect(rig.engine.count('connect'), greaterThanOrEqualTo(1));
      expect(rig.app.logLines.any((l) => l.contains('Resume: no BLE data for 45s with a live stream armed — stale link, reconnecting.')), isTrue);
      await rig.quiesce();
    }));

    test('a quiet link with NO stream armed is asked, and a reply keeps it '
        '(asked TWICE: the catch-up that follows asks again)',
        syncCase((rig, timers) async {
      await open(rig);
      rig.engine.liveArmed = false;
      rig.engine.quiet = const Duration(seconds: 200);
      rig.engine.probeAnswer = true;
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('probe') >= 2);
      expect(rig.engine.count('probe'), 2);
      expect(rig.engine.count('disconnect'), 0);
      expect(rig.engine.count('connect'), 0);
    }));

    test('no answer to the probe: the link is torn down and reconnected',
        syncCase((rig, timers) async {
      await open(rig);
      rig.engine.liveArmed = false;
      rig.engine.quiet = const Duration(seconds: 200);
      rig.engine.probeAnswer = false;
      await rig.app.openSession();
      expect(rig.engine.count('probe'), 1);
      expect(rig.engine.count('disconnect'), 1);
      expect(rig.engine.count('connect'), greaterThanOrEqualTo(1));
      await rig.quiesce();
    }));

    test('COUPLING: tearing a stale link down fires the disconnect edge, which '
        'starts the reconnect loop beside openSession\'s own connect',
        syncCase((rig, timers) async {
      await open(rig);
      rig.engine.liveArmed = true;
      rig.engine.quiet = const Duration(seconds: 45);
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('markReconnecting') >= 1);
      expect(rig.app.logLines.any((l) => l.contains('Connection dropped. Reconnecting…')), isTrue);
      // The fake does not serialise connects the way the real engine's single
      // in-flight guard does, so both callers reach it.
      expect(rig.engine.count('connect'), 2);
      await rig.quiesce();
    }));
  });
}
