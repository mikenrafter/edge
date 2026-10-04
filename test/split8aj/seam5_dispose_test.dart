// 8AJ seam 5 characterization: what AppState.dispose does to the sync area
// (timers, the foreground claim, the live session) and what calls that arrive
// AFTER it still do. Through AppState with a [SyncFakeEngine]. Must pass before
// and after the SyncController move.
//
// The calls that arrive after dispose used to be pinned as they were (work and
// ownership that outlived the object, marked LATENT). They are now asserted as
// they should be, marked FIXED (was LATENT): nothing new starts after dispose.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ios_ble_restore.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';

import 'support/sync_harness.dart';

const _db = 'split8aj_seam5_dispose.db';

Future<void> _open(SyncRig rig) => rig.openAndSettle();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  group('timers', () {
    test('dispose cancels the supervisor and the backfill timer',
        syncCase((rig, timers) async {
      await _open(rig);
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      rig.app.dispose();
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      await rig.quiesce();
    }, dispose: false));

    test('debugArmOwnedTimers arms the backfill timer and dispose cancels it',
        syncCase((rig, timers) async {
      rig.app.debugArmOwnedTimers();
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      expect(timers.activeOneShot(const Duration(minutes: 5)), hasLength(1),
          reason: 'the alarm grace timer (alarm-owned, not sync)');
      rig.app.dispose();
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(timers.activeOneShot(const Duration(minutes: 5)), isEmpty);
    }, dispose: false));

    test('with nothing open it arms nothing and leaves nothing',
        syncCase((rig, timers) async {
      rig.app.dispose();
      expect(timers.live.where((t) => t.periodic), isEmpty);
    }, dispose: false));
  });

  group('what dispose leaves alone', () {
    test('the foreground claim is released, the link is not disconnected and '
        'the iOS restore flag is not touched', syncCase((rig, timers) async {
      await _open(rig);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      rig.engine.events.clear();
      rig.app.dispose();
      expect(BandOwnership.owner, isNull);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(rig.engine.count('disconnect'), 0);
      expect(rig.engine.isConnected, isTrue);
      expect(IosBleRestore.foregroundActive, isTrue);
      await rig.quiesce();
    }, dispose: false));

    test('dispose twice: the only failure is ChangeNotifier\'s own "disposed '
        'more than once" FlutterError', syncCase((rig, timers) async {
      rig.app.dispose();
      Object? thrown;
      try {
        rig.app.dispose();
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<FlutterError>());
    }, dispose: false));
  });

  group('calls that arrive after dispose', () {
    test('a drain finishing after dispose does nothing more: no throw, no '
        'band prompt re-read, no heavy derive queued',
        syncCase((rig, timers) async {
      // FIXED (was LATENT): the bookkeeping behind a drain used to run on the
      // disposed object and queue the heavy derive.
      rig.engine.syncGate = Completer<void>();
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      rig.app.dispose();
      rig.engine.events.clear();
      rig.engine.syncGate!.complete();
      // A negative: the continuation has no signal to wait on once it is
      // fixed, so give the in-flight work time to run (it is a few awaits and
      // one DB write on today's code).
      await rig.quiesce();
      await rig.quiesce();
      expect(rig.engine.count('prompt'), 0);
      expect(await rig.jobTypes(), isEmpty);
    }, dispose: false));

    test('an openSession parked in connect at dispose does nothing after it '
        'resumes: no poll, no drain, no backfill timer, and it leaves no '
        'intent or lease behind', syncCase((rig, timers) async {
      // FIXED (was LATENT): it used to poll, start the drain and arm a fresh
      // backfill timer on the disposed object. The link it just won is dropped.
      final gate = rig.holdConnect();
      final open = rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      rig.app.dispose();
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
      gate.complete();
      await open;
      expect(rig.engine.count('getBattery'), 0);
      expect(rig.engine.count('getStrapName'), 0);
      expect(rig.engine.count('prompt'), 0);
      expect(rig.engine.count('reconcile'), 0);
      expect(rig.engine.count('runSync'), 0);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(rig.app.busy, isFalse);
      await rig.quiesce();
      expect(rig.engine.count('runSync'), 0);
      // dispose means no link: the link the connect won is dropped, once.
      expect(rig.engine.count('disconnect'), 1);
      expect(rig.engine.isConnected, isFalse);
    }, dispose: false));

    test('a link drop reported after dispose starts no reconnect and takes no '
        'foreground lease', syncCase((rig, timers) async {
      // FIXED (was LATENT): dispose did not stop wanting a link, so the drop
      // started a reconnect that took a lease the disposed object never
      // released.
      await _open(rig);
      rig.app.dispose();
      expect(BandOwnership.owner, isNull);
      rig.engine.events.clear();
      rig.engine.drop();
      await rig.quiesce();
      await rig.quiesce();
      expect(rig.engine.count('markReconnecting'), 0);
      expect(rig.engine.count('connect'), 0);
      expect(rig.engine.count('runSync'), 0);
      expect(BandOwnership.owner, isNull);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
    }, dispose: false));
  });
}
