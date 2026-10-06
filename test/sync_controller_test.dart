// SyncController in isolation, with fake collaborators. The same
// behaviour is also pinned through AppState in the other sync tests; these
// prove the controller stands on its own and never reaches for AppState.
//
// The engine is the harness's [SyncFakeEngine] (no radio); every other
// collaborator is a recorder. Host callbacks write into the engine's own event
// list as `host:*`, so one list shows the true order of engine calls and host
// work. Long timers are the hand-fired ones from [SyncTimers].

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/state/derive_coordinator.dart';
import 'package:openstrap_edge/state/sync_controller.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';
import 'package:openstrap_edge/ble/ios_ble_restore.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'sync_controller_unit.db';

/// The host of the controller: every collaborator is a recorder.
class _Host {
  _Host() {
    BandOwnership.resetForTest();
    BleEngine.resetBandClaimForTest();
    ResetGate.resetForTest();
    IosBleRestore.foregroundActive = false;
    coordinator.debugDeriveRun = deriveHook(days: ['d1'], calls: passes);
  }

  final engine = SyncFakeEngine();
  PairedDevice? paired =
      PairedDevice(kRemoteId, kSerial, generation: 'gen4');
  final logs = <String>[];
  final passes = <HookCall>[];
  int notifies = 0;
  bool disposed = false;
  bool phoneSteps = false;
  bool reanalyzing = false;
  int bumps = 0;
  int nudges = 0;
  int ecgPauses = 0;
  int phoneStepSyncs = 0;
  DerivationEngine? derive;

  late final DeriveCoordinator coordinator = DeriveCoordinator(
    engine: () => derive ??= DerivationEngine(log: logs.add),
    profile: () => throw StateError('no profile in this test'),
    log: logs.add,
    notify: () {},
    isDisposed: () => disposed,
    repo: () => null,
    warmHeld: () => false,
    refreshPhoneStepsToday: () async {},
    maybeNotifyRecoveryReady: () async {},
    runHealthExport: () async => 0,
    healthSyncEnabled: () => false,
    telemetryConsent: () => false,
    healthShareConsent: () => false,
    maybeReclaimDiskSpace: () async {},
  );

  late final SyncController sync = SyncController(
    engine: () => engine,
    paired: () => paired,
    log: logs.add,
    notify: () => notifies++,
    isDisposed: () => disposed,
    isConnected: () => engine.state.connection == 'connected',
    deriveCoordinator: () => coordinator,
    deriveEngine: () => derive ??= DerivationEngine(log: logs.add),
    reanalyzing: () => reanalyzing,
    waitForDerivation: () async {},
    phoneStepsEnabled: () => phoneSteps,
    syncPhoneSteps: () async {
      phoneStepSyncs++;
    },
    ecgOnAppPaused: () async {
      ecgPauses++;
    },
    nudgeLive: () {
      nudges++;
      engine.events.add('host:nudge');
    },
    recoverOrphanedLiveSession: () async => engine.events.add('host:recover'),
    resetLivePedometer: () => engine.events.add('host:resetPedometer'),
    refreshHighFreqWakeWindow: () async => engine.events.add('host:prompt'),
    armNextAlarmOccurrence: () async => engine.events.add('host:armAlarm'),
    bumpInsights: () => bumps++,
  );

  bool logged(String part) => logs.any((l) => l.contains(part));

  Future<void> waitFor(bool Function() ok) =>
      until(ok, within: const Duration(seconds: 6));

  Future<void> close() async {
    final g = engine.syncGate;
    if (g != null && !g.isCompleted) g.complete();
    await settleMs(100);
    disposed = true;
    sync.dispose();
    sync.releaseForegroundLease();
    coordinator.dispose();
    await settleMs(60);
    BandOwnership.resetForTest();
    ResetGate.resetForTest();
    IosBleRestore.foregroundActive = false;
  }
}

void Function() _case(Future<void> Function(_Host h, SyncTimers t) body) =>
    () async {
      final timers = SyncTimers();
      await timers.run(() async {
        final h = _Host();
        try {
          await body(h, timers);
        } finally {
          await h.close();
        }
      });
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  group('construction', () {
    test('touches no collaborator, arms no timer and starts in the foreground',
        _case((h, timers) async {
      final c = h.sync;
      expect(h.engine.events, isEmpty);
      expect(h.logs, isEmpty);
      expect(h.notifies, 0);
      expect(timers.all, isEmpty);
      expect(c.background, isFalse);
      expect(c.busy, isFalse);
      expect(c.lastRecTs, isNull);
      expect(c.lastRecordAt, isNull);
      expect(c.syncingNow, isFalse);
    }));

    test('syncOperations is one object, built on first use',
        _case((h, timers) async {
      final c = h.sync;
      expect(identical(c.syncOperations, c.syncOperations), isTrue);
    }));
  });

  group('openSession', () {
    test('engine calls and host work in order: background off, connect, poll, '
        'alarm arm, band prompt, orphan recovery, pedometer reset, live '
        'reconcile, then the burst (no history request of its own), then the '
        'alarm and the prompt again once the backlog landed',
        _case((h, timers) async {
      await h.sync.openSession();
      await h.waitFor(() => h.engine.count('host:armAlarm') == 2);
      expect(h.engine.events, [
        'setBackground:false',
        'connect:$kRemoteId:gen4',
        'getBattery',
        'getStrapName',
        'host:armAlarm',
        'host:prompt',
        'host:recover',
        'host:resetPedometer',
        'reconcile',
        'runSync:180',
        'host:armAlarm',
        'host:prompt',
      ]);
      expect(h.sync.busy, isFalse);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
    }));

    test('a foreground resume over a link that stayed up arms the alarm '
        'before the prompt (the fast path skips the connect flow)',
        _case((h, timers) async {
      await h.sync.openSession();
      await h.waitFor(() => h.engine.count('host:armAlarm') == 2);
      await h.sync.pauseForBackground();
      h.engine.events.clear();
      await h.sync.openSession();
      await h.waitFor(() => h.engine.count('host:armAlarm') == 1);
      final arm = h.engine.events.indexOf('host:armAlarm');
      final prompt = h.engine.events.indexOf('host:prompt');
      expect(arm, greaterThanOrEqualTo(0));
      expect(prompt, greaterThan(arm));
    }));

    test('busy is held for the session start and lowered in the finally, '
        'also when the start throws', _case((h, timers) async {
      h.engine.batteryThrows = StateError('boom');
      final seen = <bool>[];
      h.engine.batteryHook = () async => seen.add(h.sync.busy);
      await h.sync.openSession();
      expect(seen, [true]);
      expect(h.sync.busy, isFalse);
      expect(h.logged('Session start failed: Bad state: boom'), isTrue);
    }));

    test('busy or unpaired: it does nothing at all', _case((h, timers) async {
      h.sync.busy = true;
      await h.sync.openSession();
      h.sync.busy = false;
      h.paired = null;
      await h.sync.openSession();
      expect(h.engine.events, isEmpty);
      expect(BandOwnership.foregroundIntent, isFalse);
    }));

    test('a connect that is refused releases the claim and the backfill timer '
        'is never armed', _case((h, timers) async {
      h.engine.connectScript.add(false);
      await h.sync.openSession();
      expect(h.logged('could not reach the band'), isTrue);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(h.sync.busy, isFalse);
    }));
  });

  group('background flag', () {
    test('pauseForBackground sets it, tells the engine, nudges the live '
        'owners and pauses ECG',
        _case((h, timers) async {
      await h.sync.pauseForBackground();
      expect(h.sync.background, isTrue);
      expect(h.engine.events, ['setBackground:true', 'host:nudge']);
      expect(h.ecgPauses, 1);
      // (The scheduler only defers derivation on iOS, so its own flag is not
      // observable on the test host.)
    }));

    test('openSession brings it back down: the engine hears it and phone steps resync',
        _case((h, timers) async {
      await h.sync.pauseForBackground();
      h.phoneSteps = true;
      h.engine.events.clear();
      await h.sync.openSession();
      expect(h.sync.background, isFalse);
      expect(h.engine.events.first, 'setBackground:false');
      expect(h.phoneStepSyncs, 1);
    }));

    test('a backgrounded backfill tick refreshes the wake window once and '
        'asks for no offload', _case((h, timers) async {
      await h.sync.openSession();
      await h.waitFor(() => h.engine.count('host:armAlarm') == 2);
      await h.sync.pauseForBackground();
      h.engine.events.clear();
      timers.activePeriodic(kBackfillEvery).single.fire();
      await h.waitFor(() => h.logged('skipped — backgrounded'));
      expect(h.engine.events, ['host:prompt']);
      h.engine.events.clear();
      timers.activePeriodic(kBackfillEvery).single.fire();
      await settleMs(60);
      expect(h.engine.events, isEmpty, reason: 'throttled to one per 25 min');
    }));
  });

  group('the backfill tick', () {
    test('foreground: prompt, a history request, one drain, and a stored-data '
        'mark when records came', _case((h, timers) async {
      await h.sync.openSession();
      await h.waitFor(() => h.engine.count('host:armAlarm') == 2);
      h.engine.events.clear();
      h.engine.syncScript.add(SyncReport(5, 1, true));
      timers.activePeriodic(kBackfillEvery).single.fire();
      await h.waitFor(() => h.logged('Periodic backlog check: 5 records'));
      expect(h.engine.events, [
        'host:prompt',
        'requestHistorySync',
        'runSync:180',
      ]);
    }));

    test('it does nothing while busy, unpaired or not connected',
        _case((h, timers) async {
      await h.sync.openSession();
      await h.waitFor(() => h.engine.count('host:armAlarm') == 2);
      final tick = timers.activePeriodic(kBackfillEvery).single;
      for (final off in <void Function()>[
        () => h.sync.busy = true,
        () => h.paired = null,
        () => h.engine.link = false,
      ]) {
        h.engine.events.clear();
        h.sync.busy = false;
        h.paired = PairedDevice(kRemoteId, kSerial, generation: 'gen4');
        h.engine.link = true;
        off();
        tick.fire();
        await settleMs(40);
        expect(h.engine.events, isEmpty);
      }
    }));
  });

  group('the reconnect loop', () {
    test('a link drop starts a loop; endSession retires it and a late failure '
        'does not touch the flags', _case((h, timers) async {
      await h.sync.openSession();
      await h.waitFor(() => h.engine.count('host:armAlarm') == 2);
      final gate = h.engine.connectGate = Completer<void>();
      h.engine.connectScript.add(false);
      h.engine.events.clear();
      h.engine.drop();
      h.sync.onLinkDropped();
      await h.waitFor(() => h.engine.count('connect') == 1);
      await h.sync.endSession();
      final clears = h.engine.count('clearReconnecting');
      gate.complete();
      await h.waitFor(() => h.logged('was superseded'));
      await settleMs(60);
      expect(h.engine.count('connect'), 1, reason: 'no second attempt');
      expect(h.engine.count('clearReconnecting'), clears);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
    }));

    test('with no wish for a link a drop starts nothing and releases the '
        'claim', _case((h, timers) async {
      h.engine.drop();
      h.sync.onLinkDropped();
      await settleMs(40);
      expect(h.engine.events, isNot(contains(startsWith('connect'))));
      expect(BandOwnership.owner, isNull);
    }));

    test('the supervisor starts a loop when disconnected with none running',
        _case((h, timers) async {
      await h.sync.openSession();
      await h.waitFor(() => h.engine.count('host:armAlarm') == 2);
      h.engine.drop();
      h.engine.events.clear();
      timers.activePeriodic(kSuperviseEvery).single.fire();
      await h.waitFor(() => h.engine.count('connect') == 1);
      expect(h.logged('supervisor: disconnected with no loop running'), isTrue);
    }));
  });

  group('the manual sync', () {
    test('the scheduler hold is taken for the download and handed back in the '
        'finally when the download throws', _case((h, timers) async {
      h.engine.up();
      h.engine.syncGate = Completer<void>();
      final run = h.sync.syncOperations.syncNow();
      await h.waitFor(() => h.engine.count('runSync') == 1);
      expect(h.coordinator.scheduler.snapshot()['manual_sync_hold'], isTrue);
      h.engine.syncScript.add(StateError('band went away'));
      h.engine.syncGate!.complete();
      await run;
      expect(h.coordinator.scheduler.snapshot()['manual_sync_hold'], isFalse);
      expect(h.sync.syncOperations.presentation.phase, 'failed');
      expect(h.passes, isEmpty, reason: 'a failed download runs no derive');
    }));

    test('a good one hands the derive to the coordinator as the changed-only '
        'heavy pass and ends the hold', _case((h, timers) async {
      h.engine.up();
      await h.sync.syncOperations.syncNow();
      expect(h.passes.single.heavy, isTrue);
      expect(h.passes.single.changedOnly, isTrue);
      expect(h.coordinator.scheduler.snapshot()['manual_sync_hold'], isFalse);
    }));

    test('no band paired: a failure with the reason and no engine call',
        _case((h, timers) async {
      h.paired = null;
      final result = await h.sync.syncOperations.syncNow();
      expect(h.engine.events, isEmpty);
      expect(result.error, contains('Pair a band before syncing'));
    }));
  });

  group('the data edge, the activity window and busy', () {
    test('lastRecordAt follows lastRecTs (epoch seconds)',
        _case((h, timers) async {
      h.sync.lastRecTs = 1700000000;
      expect(h.sync.lastRecordAt,
          DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
      h.sync.lastRecTs = null;
      expect(h.sync.lastRecordAt, isNull);
    }));

    test('markSyncActivity lights syncingNow and arms ONE quiet timer that '
        'notifies once when it fires; a second mark replaces it',
        _case((h, timers) async {
      h.sync.markSyncActivity();
      expect(h.sync.syncingNow, isTrue);
      final first = timers.activeOneShot(const Duration(milliseconds: 6000));
      expect(first, hasLength(1));
      h.sync.markSyncActivity();
      expect(first.single.cancelled, isTrue);
      final second = timers.activeOneShot(const Duration(milliseconds: 6000));
      expect(second, hasLength(1));
      expect(h.notifies, 0);
      second.single.fire();
      expect(h.notifies, 1);
    }));

    test('reportSyncCommit never throws, whatever it is handed',
        _case((h, timers) async {
      h.sync.reportSyncCommit(3, [1700000000, null, 1700000100]);
      h.sync.reportSyncCommit(0, const []);
      h.disposed = true;
    }));
  });

  group('endSession and dispose', () {
    test('endSession stops wanting a link: disconnects, releases the claim, '
        'cancels both timers', _case((h, timers) async {
      await h.sync.openSession();
      await h.waitFor(() => h.engine.count('host:armAlarm') == 2);
      h.engine.events.clear();
      await h.sync.endSession();
      expect(h.engine.events.where((e) => e == 'disconnect'), hasLength(1));
      expect(BandOwnership.owner, isNull);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
    }));

    test('dispose cancels the supervisor, the backfill timer and the quiet '
        'timer, and nothing else (the claim stays until released)',
        _case((h, timers) async {
      await h.sync.openSession();
      await h.waitFor(() => h.engine.count('host:armAlarm') == 2);
      h.sync.markSyncActivity();
      h.sync.dispose();
      expect(timers.live.where((t) => t.periodic), isEmpty);
      expect(timers.activeOneShot(const Duration(milliseconds: 6000)), isEmpty);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      h.sync.releaseForegroundLease();
      expect(BandOwnership.owner, isNull);
    }));

    test('debugArmBackfillTimer arms it and dispose cancels it',
        _case((h, timers) async {
      h.sync.debugArmBackfillTimer();
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      h.sync.dispose();
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
    }));
  });

  group('the headless background start', () {
    test('wants a link, supervises, takes the lease, connects, arms the alarm, '
        'recovers and arms the backfill timer; it polls nothing and starts no '
        'drain',
        _case((h, timers) async {
      h.sync.background = true;
      await h.sync.startBackgroundSession();
      expect(h.engine.events, [
        'connect:$kRemoteId:gen4',
        'host:armAlarm',
        'host:recover',
        'host:resetPedometer',
        'reconcile',
        'host:prompt',
      ]);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
    }));

    test('a refused connect is logged and arms no backfill timer',
        _case((h, timers) async {
      h.sync.background = true;
      h.engine.connectScript.add(false);
      await h.sync.startBackgroundSession();
      expect(h.logged('bg connect returned false'), isTrue);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
    }));
  });

  group('unpairSession', () {
    test('stops wanting a link, stops both timers, disconnects and releases '
        'the claim; the pairing itself is the host\'s',
        _case((h, timers) async {
      await h.sync.openSession();
      await h.waitFor(() => h.engine.count('host:armAlarm') == 2);
      await h.sync.unpairSession();
      expect(h.engine.count('disconnect'), 1);
      expect(BandOwnership.owner, isNull);
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(IosBleRestore.foregroundActive, isFalse);
      expect(h.paired, isNotNull);
    }));
  });
}
