// The sync panel's progress plumbing, driven through AppState with the
// sync harness. The ACK ordering itself is pinned by ble_safe_trim_test
// and ack_commit_sync_full_test; these pin that the progress plumbing stays
// AFTER the commit and can never throw into the drain.
//
// forTesting does not hand the engine its commit callback, so the tests call
// the same method the real constructor wires in (AppState.debugCommitSyncBatch)
// with the native commit held or failed by the test.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/models.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'controls_sync_wiring_guard.db';

/// A record whose timestamp read throws, so the progress report fails.
class _ThrowingRecTs extends RawRecord {
  _ThrowingRecTs() : super(counter: 1, hex: '00', capturedAt: 0);
  @override
  int? get recTs => throw StateError('progress read failed');
}

RawRecord _raw(int n) =>
    RawRecord(counter: n, hex: '0$n', capturedAt: 0, recTs: 1750000000 + n);

/// A running manual sync parked in its download, so the panel is on the
/// Download step and a commit can report into it.
Future<Future<dynamic>> _downloading(SyncRig rig) async {
  await rig.openAndSettle();
  await rig.clearJobs();
  rig.engine.syncGate = Completer<void>();
  final sync = rig.app.syncOperations.syncNow();
  await rig.waitFor(() => rig.engine.count('runSync') == 1);
  expect(rig.app.syncPresentation.phase, 'downloading');
  return sync;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  test('the progress report runs after the commit returns, never before',
      syncCase((rig, timers) async {
    final sync = await _downloading(rig);
    final commitGate = Completer<void>();
    rig.app.debugNativeCommit = (raws, samples, token,
            {archives, ecgRawPackets, deviceFamily}) =>
        commitGate.future;

    final commit = rig.app.debugCommitSyncBatch([_raw(1), _raw(2)], [null, null], 'tok');
    await settleMs(40);
    expect(rig.app.syncPresentation.download?.records, 0,
        reason: 'nothing is reported while the commit is still open');

    commitGate.complete();
    await commit;
    final download = rig.app.syncPresentation.download!;
    expect(download.records, 2);
    expect(download.chunks, 1);

    rig.engine.syncGate!.complete();
    await sync;
  }));

  test('a commit that fails reports no progress and still throws',
      syncCase((rig, timers) async {
    final sync = await _downloading(rig);
    rig.app.debugNativeCommit = (raws, samples, token,
            {archives, ecgRawPackets, deviceFamily}) async =>
        throw StateError('disk full');

    await expectLater(
      rig.app.debugCommitSyncBatch([_raw(1)], [null], 'tok'),
      throwsA(isA<StateError>()),
    );
    expect(rig.app.syncPresentation.download?.records, 0);

    rig.engine.syncGate!.complete();
    await sync;
  }));

  test('the progress report cannot throw into the drain',
      syncCase((rig, timers) async {
    final sync = await _downloading(rig);
    var committed = 0;
    rig.app.debugNativeCommit = (raws, samples, token,
        {archives, ecgRawPackets, deviceFamily}) async {
      committed++;
    };

    // The report reads the records' timestamps and fails on this one; the
    // commit already banked them, so the call must still complete normally.
    await rig.app.debugCommitSyncBatch([_ThrowingRecTs()], [null], 'tok');
    expect(committed, 1);
    expect(rig.app.syncPresentation.download?.records, 0);

    rig.engine.syncGate!.complete();
    await sync;
  }));

  test('manual sync forwards each finished day and clears waiting when the '
      'other calculation ends', syncCase((rig, timers) async {
    await rig.openAndSettle();
    await rig.clearJobs();
    final hold = Completer<void>();
    rig.app.debugDeriveRun = deriveHook(
        days: ['2026-01-01', '2026-01-02'], calls: rig.passes, gate: hold);

    // Another calculation holds the lock: the sync waits its turn and says so.
    rig.app.reanalyzing = true;
    final result = rig.app.syncOperations.syncNow();
    await rig.waitFor(
        () => rig.app.syncPresentation.calculate?.waiting ?? false);
    expect(rig.passes, isEmpty);

    rig.app.reanalyzing = false;
    // The derive has reported its scope and is parked before its first day:
    // the waiting flag is already cleared, not left on until a day lands.
    await rig.waitFor(() => rig.app.syncPresentation.calculate?.dayTotal == 2);
    expect(rig.app.syncPresentation.calculate?.waiting, isFalse);
    hold.complete();
    expect((await result).success, isTrue);
    final calc = rig.app.syncPresentation.calculate;
    expect(calc?.waiting, isFalse);
    expect(calc?.dayIndex, 2);
    expect(calc?.dayTotal, 2);
    expect(calc?.day, '2026-01-02');
  }));

  test('Home has no second sync button or tap latch', () {
    final home = File('lib/ui2/screens/home_screen.dart').readAsStringSync();
    expect(home, isNot(contains('_tapSync')));
    expect(home, isNot(contains('_syncTapped')));
    expect(home, isNot(contains('syncingNowOf')));
  });
}
