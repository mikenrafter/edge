// 8AJ seam 5, sticky latches (AGENTS 4.3). The principle each case pins: every
// flag, lease and intent a path sets is released on success, error and give-up;
// a session is fully up (drain + backfill) or torn down; nothing new starts
// after dispose or after the loop was retired.
//
// The cases that flipped a LATENT characterization live next to it
// (seam5_open_session, seam5_reconnect, seam5_dispose, seam5_triggers, marked
// FIXED (was LATENT)). This file adds the exits those did not cover: every
// failure exit of openSession, the headless background start, and a bond-
// refusal pause that later expires.
//
// IosBleRestore.foregroundActive is a plain static set with no platform check
// in openSession, so it is observable here. The headless start sets it only on
// iOS, which the Linux host cannot take, so that path is covered through the
// lease and the intent (the two things a later headless wake is refused by).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ios_ble_restore.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/state/derive_coordinator.dart';
import 'package:openstrap_edge/state/sync_controller.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'split8aj_seam5_latch_fixes.db';

/// A later headless wake would be accepted: no foreground intent, no owner.
void _expectBandFree() {
  expect(BandOwnership.foregroundIntent, isFalse);
  expect(BandOwnership.owner, isNull);
  final lease = BandOwnership.tryAcquireHeadless();
  expect(lease, isNotNull, reason: 'a headless wake must not be refused');
  BandOwnership.release(lease!);
}

class _Host {
  _Host() {
    BandOwnership.resetForTest();
    BleEngine.resetBandClaimForTest();
    ResetGate.resetForTest();
    IosBleRestore.foregroundActive = false;
    coordinator.debugDeriveRun = deriveHook(days: ['d1'], calls: passes);
  }

  final engine = SyncFakeEngine();
  final PairedDevice paired =
      PairedDevice(kRemoteId, kSerial, generation: 'gen4');
  final logs = <String>[];
  final passes = <HookCall>[];
  bool disposed = false;
  DerivationEngine? derive;

  /// Thrown (once) from the band-prompt refresh the start runs after a connect.
  Object? promptThrowsOnce;

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
    notify: () {},
    isDisposed: () => disposed,
    isConnected: () => engine.state.connection == 'connected',
    deriveCoordinator: () => coordinator,
    deriveEngine: () => derive ??= DerivationEngine(log: logs.add),
    reanalyzing: () => false,
    waitForDerivation: () async {},
    phoneStepsEnabled: () => false,
    syncPhoneSteps: () async {},
    ecgOnAppPaused: () async {},
    nudgeLive: () {},
    recoverOrphanedLiveSession: () async => engine.events.add('host:recover'),
    resetLivePedometer: () => engine.events.add('host:resetPedometer'),
    refreshHighFreqWakeWindow: () async {
      engine.events.add('host:prompt');
      final once = promptThrowsOnce;
      promptThrowsOnce = null;
      if (once != null) throw once;
    },
    armNextAlarmOccurrence: () async => engine.events.add('host:armAlarm'),
    bumpInsights: () {},
  );

  bool logged(String part) => logs.any((l) => l.contains(part));

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

void Function() _hostCase(
        Future<void> Function(_Host h, SyncTimers t) body) =>
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

  group('openSession: every exit that leaves no link releases everything', () {
    // One body, three ways to end without a session. After any of them: the
    // iOS restore flag, the intent and the lease are all released (so a
    // headless wake is accepted), busy is down, no backfill timer runs, and the
    // supervisor stays because the app still WANTS a link.
    Future<void> expectReleased(SyncRig rig, SyncTimers timers) async {
      expect(rig.app.busy, isFalse);
      expect(IosBleRestore.foregroundActive, isFalse);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      _expectBandFree();
    }

    test('the connect answers false', syncCase((rig, timers) async {
      rig.engine.connectScript.add(false);
      await rig.app.openSession();
      await expectReleased(rig, timers);
    }));

    test('the connect throws', syncCase((rig, timers) async {
      rig.engine.connectScript.add(StateError('gatt 133'));
      await rig.app.openSession();
      await expectReleased(rig, timers);
    }));

    test('the link is gone by the time the session settles',
        syncCase((rig, timers) async {
      rig.engine.batteryHook = () async => rig.engine.link = false;
      await rig.app.openSession();
      await expectReleased(rig, timers);
    }));
  });

  group('the headless background start', () {
    test('a refused connect releases the lease and the intent it took, so a '
        'later headless wake is not refused; the supervisor stays to retry',
        _hostCase((h, timers) async {
      h.sync.background = true;
      h.engine.connectScript.add(false);
      await h.sync.startBackgroundSession();
      expect(h.logged('bg connect returned false'), isTrue);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      expect(IosBleRestore.foregroundActive, isFalse);
      _expectBandFree();
    }));

    test('a connect that throws does the same', _hostCase((h, timers) async {
      h.sync.background = true;
      h.engine.connectScript.add(StateError('gatt 133'));
      await h.sync.startBackgroundSession();
      expect(h.logged('bg connect failed: Bad state: gatt 133'), isTrue);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      expect(IosBleRestore.foregroundActive, isFalse);
      _expectBandFree();
    }));

    test('a throw after the link is up tears the link down (no half-open '
        'session) and releases the lease and intent; the supervisor stays',
        _hostCase((h, timers) async {
      h.sync.background = true;
      h.engine.drop();
      h.promptThrowsOnce = StateError('prompt write failed');
      await h.sync.startBackgroundSession();
      expect(h.logged('bg connect failed: Bad state: prompt write failed'), isTrue);
      expect(h.engine.count('disconnect'), 1);
      expect(h.engine.isConnected, isFalse);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      expect(IosBleRestore.foregroundActive, isFalse);
      _expectBandFree();
    }));

    test('control: a connect that lands keeps the lease and the intent (a '
        'session that is up owns the band)', _hostCase((h, timers) async {
      h.sync.background = true;
      await h.sync.startBackgroundSession();
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
    }));

    test('after a failed start the supervisor retries and the loop takes the '
        'band again', _hostCase((h, timers) async {
      h.sync.background = true;
      h.engine.connectScript.add(false);
      await h.sync.startBackgroundSession();
      _expectBandFree();
      timers.activePeriodic(kSuperviseEvery).single.fire();
      await until(() => h.engine.count('connect') == 2,
          within: const Duration(seconds: 6));
      await until(() => timers.activePeriodic(kBackfillEvery).isNotEmpty,
          within: const Duration(seconds: 6));
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      expect(BandOwnership.foregroundIntent, isTrue);
    }));
  });

  group('a bond-refusal pause that stands and then expires', () {
    test('released at the edge, and the supervisor takes the band again when '
        'the pause lifts (nothing the release did blocks the resume)',
        syncCase((rig, timers) async {
      await rig.openAndSettle();
      await rig.clearJobs();
      rig.engine.state.autoReconnectPaused = true;
      rig.engine.drop();
      await rig.quiesce();
      _expectBandFree();
      rig.engine.events.clear();
      rig.engine.state.autoReconnectPaused = false;
      timers.activePeriodic(kSuperviseEvery).single.fire();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      await rig.waitFor(() => timers.activePeriodic(kBackfillEvery).isNotEmpty);
      expect(rig.engine.isConnected, isTrue);
      expect(BandOwnership.foregroundIntent, isTrue);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
    }));
  });
}
