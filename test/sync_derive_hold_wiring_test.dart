// The manual sync's hold on the derive scheduler, driven through
// AppState with the sync harness. Each test records the order of what
// happened (scheduler hold, download, derive, release) and asserts on that
// trace. The behaviour behind each piece is also tested directly:
// DeriveScheduler (derive_scheduler_manual_sync_test), the engine's changedOnly
// pass (derive_changed_only_test), the coordinator and classifyDownload
// (sync_outcomes_test).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'controls_sync_perf_wiring.db';

/// What a sync leaves behind, in order. The scheduler hold is read at each
/// step, so "held" / "free" is what the scheduler saw at that moment.
class _Trace {
  _Trace(this.rig) {
    final inner = deriveHook(
        days: ['2026-01-01', '2026-01-02'], calls: rig.passes);
    rig.engine.onRunSync = () async {
      add('download');
      await onDownload?.call();
    };
    rig.app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      add('derive');
      if (deriveThrows) throw StateError('derive failed');
      final r = await inner(
        heavy: heavy,
        changedOnly: changedOnly,
        onScope: onScope,
        onScopeDays: onScopeDays,
        onDayDone: onDayDone,
        onCrossDay: onCrossDay,
      );
      add('derive done');
      return r;
    };
  }

  final SyncRig rig;
  final events = <String>[];
  Future<void> Function()? onDownload;
  bool deriveThrows = false;

  DeriveScheduler get scheduler => rig.app.debugDeriveScheduler;
  bool get held => scheduler.snapshot()['manual_sync_hold'] as bool;
  void add(String what) => events.add('$what:${held ? 'held' : 'free'}');
}

Future<_Trace> _open(SyncRig rig) async {
  await rig.openAndSettle();
  await rig.clearJobs();
  rig.engine.events.clear();
  return _Trace(rig);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  test('the scheduler hold is taken before the download, kept through the '
      'derive and released once the sync is done', syncCase((rig, timers) async {
    final t = await _open(rig);
    expect(t.held, isFalse);
    final result = await rig.app.syncOperations.syncNow();
    expect(result.success, isTrue);
    expect(t.events, ['download:held', 'derive:held', 'derive done:held']);
    expect(t.held, isFalse);
  }));

  test('the hold is released when the download fails', syncCase((rig, timers) async {
    final t = await _open(rig);
    rig.engine.syncScript.add(SyncReport(0, 0, false));
    final result = await rig.app.syncOperations.syncNow();
    expect(result.success, isFalse);
    expect(result.error,
        contains('Download stopped before completion. Retry sync.'));
    expect(t.events, ['download:held']);
    expect(t.held, isFalse);
  }));

  test('the hold is released when the derive fails', syncCase((rig, timers) async {
    final t = await _open(rig);
    t.deriveThrows = true;
    final result = await rig.app.syncOperations.syncNow();
    expect(result.success, isFalse);
    expect(t.events, ['download:held', 'derive:held']);
    expect(t.held, isFalse);
  }));

  test('the derive is the changed-only heavy pass and its scope reaches the '
      'panel', syncCase((rig, timers) async {
    final t = await _open(rig);
    await rig.app.syncOperations.syncNow();
    expect(rig.passes, hasLength(1));
    expect(rig.passes.single.heavy, isTrue);
    expect(rig.passes.single.changedOnly, isTrue);
    final calc = rig.app.syncPresentation.calculate;
    expect(calc?.dayTotal, 2);
    expect(calc?.dayIndex, 2);
    expect(t.events, contains('derive done:held'));
  }));

  group('the debounced light job the download queued', () {
    Future<void> queueLightDuringDownload(SyncRig rig, _Trace t) async {
      t.onDownload = () async {
        rig.app.debugDeriveScheduler.markStoredData();
        await rig.jobQueued('derive_light');
      };
    }

    test('is absorbed only after this sync\'s derive completed',
        syncCase((rig, timers) async {
      final t = await _open(rig);
      await queueLightDuringDownload(rig, t);
      await rig.app.syncOperations.syncNow();
      expect(t.events.last, 'derive done:held');
      expect(await rig.jobTypes(), isNot(contains('derive_light')));
    }));

    test('survives a derive that failed', syncCase((rig, timers) async {
      final t = await _open(rig);
      await queueLightDuringDownload(rig, t);
      t.deriveThrows = true;
      final result = await rig.app.syncOperations.syncNow();
      expect(result.success, isFalse);
      expect(await rig.jobTypes(), contains('derive_light'));
    }));

    test('survives a derive that never reported its scope',
        syncCase((rig, timers) async {
      final t = await _open(rig);
      await queueLightDuringDownload(rig, t);
      rig.app.debugDeriveRun = deriveHook(reportScope: false);
      final result = await rig.app.syncOperations.syncNow();
      expect(result.success, isFalse);
      expect(await rig.jobTypes(), contains('derive_light'));
    }));
  });

  test('a run the coordinator retired stops after its download, derives '
      'nothing and then releases the hold', syncCase((rig, timers) async {
    final t = await _open(rig);
    rig.engine.syncGate = Completer<void>();
    final first = rig.app.syncOperations.syncNow();
    await rig.waitFor(() => rig.engine.count('runSync') == 1);
    expect(t.held, isTrue);

    timers.activeOneShot(const Duration(minutes: 65)).single.fire();
    expect((await first).success, isFalse);
    expect(t.held, isTrue, reason: 'the retired run is still unwinding');

    rig.engine.syncGate!.complete();
    await rig.waitFor(() => !t.held);
    expect(t.held, isFalse);
    expect(rig.passes, isEmpty, reason: 'the cancel token stopped it');
    expect(t.events, ['download:held']);
  }));

  test('drain and ACK ordering is untouched by the sync-performance work', () {
    final ble = File('lib/ble/ble_engine.dart').readAsStringSync();
    expect(ble, isNot(contains('beginManualSync')));
    expect(ble, isNot(contains('changedOnly')));
  });
}
