// 8AJ seam 5 characterization: what AppState.dispose does to the sync area
// (timers, the foreground claim, the live session) and what calls that arrive
// AFTER it still do. Through AppState with a [SyncFakeEngine]. Must pass before
// and after the SyncController move.
//
// Some of this is today's behaviour that looks like a gap (work and ownership
// that outlive the object). It is pinned as it is, marked LATENT, so the move
// cannot change it by accident and the follow-up has a test to flip.

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
    test('a drain finishing after dispose does not notify or throw, but its '
        'bookkeeping still runs (band prompt re-read, heavy derive queued)',
        syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      rig.app.dispose();
      rig.engine.events.clear();
      rig.engine.syncGate!.complete();
      await rig.jobQueued('derive_heavy');
      expect(rig.engine.count('prompt'), 1);
      await rig.quiesce();
    }, dispose: false));

    test('LATENT: an openSession parked in connect at dispose carries on '
        'after it: polls the band, starts the drain, and arms a fresh backfill '
        'timer on the disposed object', syncCase((rig, timers) async {
      final gate = rig.holdConnect();
      final open = rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      rig.app.dispose();
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
      gate.complete();
      await open;
      expect(rig.engine.count('getBattery'), 1);
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      await rig.quiesce();
    }, dispose: false));

    test('LATENT: a link drop reported after dispose still starts a reconnect '
        '(dispose does not stop wanting a link), which takes a foreground '
        'lease the disposed object never releases',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.app.dispose();
      expect(BandOwnership.owner, isNull);
      rig.engine.events.clear();
      rig.engine.drop();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      await rig.quiesce();
    }, dispose: false));
  });
}
