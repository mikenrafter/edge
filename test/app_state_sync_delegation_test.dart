// 8AJ seam 5 delegation guard: every public AppState member in the sync area is
// still there with the same shape, the collaborators the area is handed or
// hands out are still wired, and the source-level wiring that cannot be driven
// without the real AppState constructor stays put. Must pass before and after
// the SyncController move.
//
// Sync-owned in this seam (what moves): the session / reconnect / backfill
// orchestration (openSession, _reconnect, the supervisor, the 10 minute
// backfill timer, _kickSyncBurst / _runSyncBurst, forceResync,
// foregroundCatchUp, pauseForBackground, endSession, the sync part of unpair),
// the foreground/background flag, the foreground lease and intent, the manual
// sync (_manualSync, syncOperations), the band-prompt refresh, the sync
// activity window (syncingNow), and the data edge (_lastRecTs / lastRecordAt).
// Staying: the BLE engine and every policy inside it, _onRecord / _onLiveEvent
// and the rest of _onEngineState (only its connection-edge branch is sync),
// pairing and its persistence, resetAllData and ResetGate, the alarm arm
// machinery and its grace timer (a callback the sync paths call), and the
// headless entries (HeadlessSyncGate is not used by AppState at all).
//
// The source guards read lib/state/app_state.dart and, if it exists,
// lib/state/sync_controller.dart together, so a move does not break them; they
// look for names, and a rename in the move means touching the pattern.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/models.dart' show DeviceState;
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'split8aj_seam5_delegation.db';

String _src() {
  final app = File('lib/state/app_state.dart').readAsStringSync();
  final f = File('lib/state/sync_controller.dart');
  return f.existsSync() ? '$app\n${f.readAsStringSync()}' : app;
}

String _appOnly() => File('lib/state/app_state.dart').readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  test('every public member of the area is still on AppState with its shape',
      () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    // Methods: a tear-off of each type-checks the signature.
    final Future<void> Function() openSession = app.openSession;
    final Future<void> Function() endSession = app.endSession;
    final Future<void> Function() pause = app.pauseForBackground;
    final Future<void> Function() unpair = app.unpair;
    final Future<void> Function() forceResync = app.forceResync;
    final Future<void> Function() catchUp = app.foregroundCatchUp;
    final Future<void> Function() syncNow = app.syncNow;
    final Future<void> Function() refresh = app.refreshData;
    final Future<bool> Function() bluetoothReady = app.bluetoothReady;
    final Future<bool> Function() accessory = app.accessorySetupSupported;
    final Future<void> Function() init = app.debugInit;
    final void Function() armTimers = app.debugArmOwnedTimers;
    final void Function(String, DeviceState) feed = app.debugFeedEngineState;
    for (final f in [openSession, endSession, pause, unpair, forceResync,
        catchUp, syncNow, refresh, bluetoothReady, accessory, init, armTimers, feed]) {
      expect(f, isNotNull);
    }
    // Reads: each has the type the screens rely on.
    final String status = app.status;
    final bool connected = app.isConnected;
    final bool busy = app.busy;
    final bool syncing = app.syncingNow;
    final bool deriving = app.deriving;
    final bool pending = app.derivePending;
    final DateTime? edge = app.lastRecordAt;
    final DateTime? rx = app.lastDataAt;
    final SyncCoordinator ops = app.syncOperations;
    final SyncPresentationState view = app.syncPresentation;
    final bool paired = app.isPaired;
    final BleEngine engine = app.engine;
    expect([status, connected, busy, syncing, deriving, pending, edge, rx,
        ops, view, paired, engine], hasLength(12));
    // Writable fields the existing tests and the lifecycle code poke.
    app.busy = false;
    app.paired = null;
    expect(app.logLines, isA<List<String>>());
  });

  test('syncOperations and the engine are one object for the life of the app, '
      'and dispose disposes the coordinator (a late refresh is inert)',
      syncCase((rig, timers) async {
    final ops = rig.app.syncOperations;
    final engine = rig.app.engine;
    await rig.app.refreshData();
    expect(identical(rig.app.syncOperations, ops), isTrue);
    expect(identical(rig.app.engine, engine), isTrue);
    rig.app.dispose();
    await ops.refresh();
    expect(ops.presentation.phase, isNotNull);
  }, paired: false, dispose: false));

  group('collaborators the area is handed or hands out (source)', () {
    test('what other controllers take from this area', () {
      final s = _src();
      // The workout controller re-syncs through AppState's forceResync.
      expect(RegExp(r'forceResync:\s*(_sync\.)?forceResync').hasMatch(s), isTrue);
      // The live-stream controller reads the foreground flag.
      expect(RegExp(r'isBackground:\s*\(\)\s*=>\s*(_sync\.)?_?background').hasMatch(s)
          || s.contains('isBackground: () => _background'), isTrue);
      // The derive coordinator's warmer holds while backgrounded.
      expect(RegExp(r'warmHeld:\s*\(\)\s*=>\s*_liveSessionActive\s*\|\|\s*(_sync\.)?_?background').hasMatch(s)
          || s.contains('warmHeld: () => _liveSessionActive || _background'), isTrue);
      // The derive engine is built with the launch-time background flag.
      expect(s.contains('DerivationEngine(log: _log, background: _background)')
          || RegExp(r'DerivationEngine\(log: _log, background:').hasMatch(s), isTrue);
    });

    test('what this area hands the engine and the plugins (real constructor)',
        () {
      final s = _src();
      expect(s.contains('onDataStored: _onDataStored,'), isTrue);
      expect(s.contains('onOffloadState: (active) => _deriveScheduler.setOffloadActive(active),'), isTrue);
      expect(RegExp(r'isForegroundActive:\s*\(\)\s*=>\s*!_?(_sync\.)?_?background').hasMatch(s)
          || s.contains('isForegroundActive: () => !_background,'), isTrue);
      expect(s.contains('IosBgTask.foregroundPull = foregroundCatchUp;')
          || RegExp(r'IosBgTask\.foregroundPull\s*=').hasMatch(s), isTrue);
      // The launch-time background state is seeded into the engine and the
      // scheduler (a headless start begins backgrounded).
      expect(s.contains('engine.setBackground(_background);'), isTrue);
      expect(s.contains('_deriveScheduler.setBackground(_background);'), isTrue);
      // The manual sync is the coordinator's run callback and re-notifies AppState.
      expect(RegExp(r'SyncCoordinator\(\s*run:\s*_manualSync,').hasMatch(s), isTrue);
      expect(s.contains('..addListener(notifyListeners)') || s.contains('..addListener(_notify)'), isTrue);
    });

    test('_onDataStored marks the sync activity synchronously, BEFORE the '
        'async cursor read, and re-arms the light derive after notifying', () {
      final s = _src();
      final start = s.indexOf('void _onDataStored()');
      final body = s.substring(start, s.indexOf('void _onLiveEvent', start));
      final mark = body.indexOf('_markSyncActivity();');
      final read = body.indexOf("getCursorInt('rec_ts_hw')");
      final notify = body.indexOf('notifyListeners();');
      final stored = body.indexOf('markStoredData()');
      expect(mark, greaterThan(0));
      expect(read, greaterThan(mark));
      expect(notify, greaterThan(read));
      expect(stored, greaterThan(notify));
    });

    test('the drain callbacks: the ACK gate refuses a commit during a reset',
        () {
      final s = _src();
      // The commit-then-report order is run in controls/sync_wiring_guard_test.
      expect(s.contains("throw StateError('data reset in progress — refusing to commit');"), isTrue);
    });

    test('the data edge is read by the engine as a staleness', () {
      final s = _src();
      final at = s.indexOf('deriveDataStaleness: () {');
      expect(at, greaterThan(0));
      expect(s.substring(at, at + 300).contains('_lastRecTs'), isTrue);
    });

    test('the manual sync still hands the derive to the coordinator\'s '
        'afterDrain, as the changed-only heavy pass', () {
      final s = _src();
      final start = s.indexOf('Future<void> _manualSync');
      final body = s.substring(start, s.indexOf('@visibleForTesting', start));
      expect(body, contains('afterDrain('));
      expect(body, contains('heavy: true'));
      expect(body, contains('changedOnly: true'));
      // LATENT GUARD: test/sync_derive_hold_wiring_test.dart:30 searches the
      // body for "_afterDrain(" (the pre-seam-1 name), finds nothing (-1), and
      // its assertion `flag > run` passes vacuously. It must be repointed to
      // "afterDrain(" with the move.
      expect(body.contains('_afterDrain('), isFalse);
    });
  });

  group('lifecycle wiring in dispose (source)', () {
    test('dispose stops the timers through the controller, releases the claim '
        'and disposes the coordinator', () {
      final s = _appOnly();
      final start = s.indexOf('  void dispose() {');
      final body = s.substring(start, s.indexOf('void debugArmOwnedTimers', start));
      expect(body, contains('_sync.dispose();'));
      expect(body, contains('BandOwnership.markForegroundIntent(false);'));
      expect(body.indexOf('_sync.releaseForegroundLease();'),
          greaterThan(body.indexOf('BandOwnership.markForegroundIntent(false);')));
      expect(body, contains('syncOperations.dispose();'));
      // The controller's dispose cancels all three timers it owns.
      final c = File('lib/state/sync_controller.dart').readAsStringSync();
      final cStart = c.indexOf('  void dispose() {');
      final cBody = c.substring(cStart);
      expect(cBody, contains('_syncQuietTimer?.cancel()'));
      expect(cBody, contains('_stopBackfillTimer();'));
      expect(cBody, contains('_stopReconnectSupervisor();'));
    });

    test('every path that stops wanting a link stops both timers: the link '
        'half of unpair and endSession', () {
      final s = _src();
      for (final sig in ['Future<void> unpairSession() async', 'Future<void> endSession() async']) {
        final at = s.indexOf(sig);
        expect(at, greaterThan(0), reason: sig);
        final body = s.substring(at, at + 700);
        expect(body, contains('_keepAlive = false;'), reason: sig);
        expect(body, contains('_stopBackfillTimer();'), reason: sig);
        expect(body, contains('_stopReconnectSupervisor();'), reason: sig);
        expect(body, contains('BandOwnership.markForegroundIntent(false);'), reason: sig);
      }
    });

    test('the reconnect loop clears its flags in a finally and checks its '
        'generation before touching shared state', () {
      final s = _src();
      final at = s.indexOf('Future<void> _reconnect() async');
      final body = s.substring(at, s.indexOf('Future<void> forceResync()', at));
      final fin = body.lastIndexOf('} finally {');
      expect(fin, greaterThan(0));
      final tail = body.substring(fin);
      expect(tail, contains('generation != _reconnectGeneration'));
      expect(tail, contains('_reconnecting = false;'));
      expect(tail, contains('_attemptStartedAt = null;'));
      expect(tail, contains('engine.clearReconnecting();'));
      expect(tail, contains('BandOwnership.markForegroundIntent(false);'));
    });

    test('openSession\'s finally releases the claim only when the link is '
        'gone or the wish for one is', () {
      final s = _src();
      final at = s.indexOf('Future<void> openSession() async');
      final body = s.substring(at, s.indexOf('static const int _directAttemptsBeforeOsFallback', at));
      final fin = body.lastIndexOf('} finally {');
      final tail = body.substring(fin);
      expect(tail, contains('if (!engine.isConnected || !_keepAlive) {'));
      expect(tail, contains('_stopBackfillTimer();'));
      expect(tail, contains('_releaseClaimsUnlessLooping();'));
      expect(tail, contains('_setBusy(false);'));
    });

    test('the engine\'s reset-sensitive callbacks keep their gate',
        () {
      final s = _src();
      for (final sig in [
        'void _onEngineState(String deviceId, DeviceState s) {',
        'Future<void> _onRecord(Sample? sample, RawRecord raw) async {',
        'void _onLiveEvent(StrapEvent e) {',
      ]) {
        final at = s.indexOf(sig);
        expect(at, greaterThan(0), reason: sig);
        expect(s.substring(at, at + sig.length + 80),
            contains('if (_resetting) return;'),
            reason: sig);
      }
    });
  });
}
