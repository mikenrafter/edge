// "N ago" on Home is the last successful sync of ANY kind. A history drain the
// user never asked for (connect, reconnect, the backfill timer, a resync after
// a workout) that ends on a clean HISTORY_END records a success at its
// completion time; a failed, partial or dropped drain records nothing. Through
// AppState with a [SyncFakeEngine], plus the coordinator method on its own.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/control_operations.dart';

import 'support/sync_harness.dart';

const _db = 'split8aj_seam5_background_success.db';

/// A connected, drained foreground session. Its own opening drain already
/// counts, so tests read the value it left and compare against that.
Future<DateTime> _open(SyncRig rig) async {
  await rig.openAndSettle();
  await rig.clearJobs();
  rig.engine.events.clear();
  final first = rig.app.syncOperations.presentation.lastSuccess;
  expect(first, isNotNull, reason: 'the opening drain was a clean one');
  await settleMs(20); // so a later "now" is strictly later
  return first!;
}

DateTime? _last(SyncRig rig) => rig.app.syncOperations.presentation.lastSuccess;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  group('an automatic drain', () {
    test('that committed records sets the last success to its completion time',
        syncCase((rig, timers) async {
      final first = await _open(rig);
      rig.engine.syncScript.add(SyncReport(40, 2, true));
      final started = DateTime.now();
      await rig.app.forceResync();
      final last = _last(rig)!;
      expect(last.isAfter(first), isTrue);
      expect(last.isBefore(started), isFalse);
      expect(last.isAfter(DateTime.now()), isFalse);
      expect(rig.app.syncPresentation.phase, 'idle',
          reason: 'only the time moves; no run was published');
      expect(rig.app.syncPresentation.steps, isEmpty);
    }));

    test('that found nothing new (a clean HISTORY_END, no records) also does',
        syncCase((rig, timers) async {
      final first = await _open(rig);
      rig.engine.syncScript.add(SyncReport(0, 0, true));
      await rig.app.forceResync();
      expect(_last(rig)!.isAfter(first), isTrue);
    }));

    test('from the 10-minute backfill timer does too',
        syncCase((rig, timers) async {
      final first = await _open(rig);
      rig.engine.syncScript.add(SyncReport(5, 1, true));
      timers.activePeriodic(kBackfillEvery).single.fire();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      await rig.quiesce();
      expect(_last(rig)!.isAfter(first), isTrue);
    }));

    test('that stopped early (a partial drain) records nothing',
        syncCase((rig, timers) async {
      final first = await _open(rig);
      rig.engine.syncScript.add(SyncReport(12, 1, false));
      await rig.app.forceResync();
      expect(_last(rig), first);
    }));

    test('that failed records nothing', syncCase((rig, timers) async {
      final first = await _open(rig);
      rig.engine.syncScript.add(StateError('drain blew up'));
      await rig.app.forceResync();
      expect(_last(rig), first);
    }));

    test('on a link that dropped mid-drain records nothing',
        syncCase((rig, timers) async {
      final first = await _open(rig);
      rig.engine.onRunSync = () async => rig.engine.link = false;
      rig.engine.syncScript.add(SyncReport(1, 1, false));
      await rig.app.forceResync();
      expect(_last(rig), first);
    }));

    test('notifies the coordinator\'s listeners exactly once',
        syncCase((rig, timers) async {
      await _open(rig);
      var n = 0;
      void tick() => n++;
      rig.app.syncOperations.addListener(tick);
      await rig.app.forceResync();
      rig.app.syncOperations.removeListener(tick);
      expect(n, 1);
    }));

    test('finishing after the app was disposed records nothing and throws '
        'nothing', syncCase((rig, timers) async {
      await _open(rig);
      final ops = rig.app.syncOperations;
      final before = ops.presentation.lastSuccess;
      rig.engine.syncGate = Completer<void>();
      final resync = rig.app.forceResync();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      rig.app.dispose();
      rig.engine.syncGate!.complete();
      await resync;
      await rig.quiesce();
      expect(ops.presentation.lastSuccess, before);
    }, dispose: false));
  });

  group('a manual sync', () {
    test('still records its own success and settles on completed',
        syncCase((rig, timers) async {
      final first = await _open(rig);
      final result = await rig.app.syncOperations.syncNow();
      expect(result.success, isTrue);
      expect(rig.app.syncPresentation.phase, 'completed');
      expect(_last(rig)!.isAfter(first), isTrue);
    }));

    test('a failed one leaves the last success as it was',
        syncCase((rig, timers) async {
      final first = await _open(rig);
      rig.engine.syncScript.add(SyncReport(0, 0, false));
      final result = await rig.app.syncOperations.syncNow();
      expect(result.success, isFalse);
      expect(_last(rig), first);
    }));
  });

  group('SyncCoordinator.noteBackgroundSuccess', () {
    late DateTime t;
    setUp(() => t = DateTime(2026, 10, 4, 9));

    SyncCoordinator make(
      Future<void> Function(void Function(String)) run, {
      bool connected = true,
    }) => SyncCoordinator(
      run: run,
      isConnected: () => connected,
      reloadLocal: () async {},
      clock: () => t,
    );

    test('during a run moves the time only: phase, steps and busy untouched, '
        'one notification', () async {
      final gate = Completer<void>();
      final c = make((phase) async {
        phase('downloading');
        await gate.future;
      });
      final run = c.syncNow();
      await Future<void>.delayed(Duration.zero);
      final during = c.presentation;
      expect(during.phase, 'downloading');
      var n = 0;
      c.addListener(() => n++);
      final at = t.add(const Duration(minutes: 1));
      c.noteBackgroundSuccess(at);
      expect(c.presentation.lastSuccess, at);
      expect(c.presentation.phase, 'downloading');
      expect(c.presentation.busy, isTrue);
      expect(c.presentation.steps.length, during.steps.length);
      for (var i = 0; i < during.steps.length; i++) {
        expect(c.presentation.steps[i].status, during.steps[i].status);
      }
      expect(c.presentation.startedAt, during.startedAt);
      expect(n, 1);
      gate.complete();
      expect((await run).success, isTrue);
      expect(c.presentation.phase, 'completed');
      c.dispose();
    });

    test('never moves the time backwards', () {
      final c = make((_) async {});
      c.noteBackgroundSuccess(t);
      c.noteBackgroundSuccess(t.subtract(const Duration(hours: 1)));
      expect(c.presentation.lastSuccess, t);
      c.dispose();
    });

    test('after dispose it does nothing and does not throw', () {
      final c = make((_) async {});
      c.dispose();
      c.noteBackgroundSuccess(t);
      expect(c.presentation.lastSuccess, isNull);
    });
  });
}
