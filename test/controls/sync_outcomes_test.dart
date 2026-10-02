// 8M follow-up — the manual sync's outcomes and its cancellation.
//
//  * a download that stopped at the time cap AFTER making progress is a
//    partial sync, not a failure: Download is done with a note, Calculate runs
//    on what arrived, and the sync ends "Done (partial)";
//  * real errors and disconnects stay failures;
//  * a Calculate that has nothing to do reads "Skipped — nothing new";
//  * Calculate shows "day 0 of N" the moment the scope is known;
//  * when the coordinator times a run out it cancels the run's token, and a new
//    sync waits for the old one to unwind (or abandons it after a grace), so
//    two runs never overlap;
//  * [sync-timing] names the skipped and partial outcomes.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/control_operations.dart';

void main() {
  late DateTime t;
  late List<String> logs;
  setUp(() {
    t = DateTime(2026, 10, 2, 9);
    logs = [];
  });

  SyncCoordinator make(
    Future<void> Function(void Function(String)) run, {
    bool connected = true,
    Duration timeout = const Duration(seconds: 30),
    Duration retireGrace = const Duration(milliseconds: 30),
  }) => SyncCoordinator(
    run: run,
    isConnected: () => connected,
    reloadLocal: () async {},
    timeout: timeout,
    retireGrace: retireGrace,
    clock: () => t,
    log: logs.add,
  );

  group('classifyDownload', () {
    test('complete is complete', () {
      expect(
        classifyDownload(connected: true, complete: true, progressed: false, stuck: false),
        DownloadVerdict.complete,
      );
    });

    test('cut off at the cap after progress is partial, not a failure', () {
      expect(
        classifyDownload(connected: true, complete: false, progressed: true, stuck: false),
        DownloadVerdict.partial,
      );
    });

    test('cut off with nothing banked this sync is a failure', () {
      expect(
        classifyDownload(connected: true, complete: false, progressed: false, stuck: false),
        DownloadVerdict.failed,
      );
    });

    test('a dropped link is a failure even with progress', () {
      expect(
        classifyDownload(connected: false, complete: false, progressed: true, stuck: false),
        DownloadVerdict.failed,
      );
    });

    test('a terminal Stuck is a failure even with progress', () {
      expect(
        classifyDownload(connected: true, complete: false, progressed: true, stuck: true),
        DownloadVerdict.failed,
      );
    });
  });

  group('partial outcome', () {
    test('Download done with a note, Calculate runs, Done (partial)', () async {
      late SyncCoordinator c;
      c = make((progress) async {
        progress('downloading');
        c.reportCommit(records: 900, newest: DateTime(2026, 10, 2, 3));
        c.reportPartialDownload();
        progress('deriving');
        c.reportScope(2);
        c.reportDay('2026-10-02', 1, 2);
        c.reportDay('2026-10-01', 2, 2);
      });
      final r = await c.syncNow();

      expect(r.success, isTrue, reason: 'a partial sync is not an error');
      expect(r.partial, isTrue);
      final p = c.presentation;
      expect(p.phase, 'completed');
      expect(p.partial, isTrue);
      expect(p.failureReason, isNull);
      final download = p.step(SyncStepId.download);
      expect(download.status, SyncStepStatus.done);
      expect(
        download.note,
        'More remains on the band — sync again to continue',
      );
      expect(p.step(SyncStepId.calculate).status, SyncStepStatus.done);
      final done = p.step(SyncStepId.done);
      expect(done.status, SyncStepStatus.done);
      expect(done.note, 'Done (partial)');
      expect(p.lastSuccess, isNotNull);
    });

    test('an ordinary sync is not marked partial', () async {
      final c = make((progress) async => progress('downloading'));
      final r = await c.syncNow();
      expect(r.partial, isFalse);
      expect(c.presentation.partial, isFalse);
      expect(c.presentation.step(SyncStepId.done).note, isNull);
    });

    test('partial does not leak into the next sync', () async {
      late SyncCoordinator c;
      var first = true;
      c = make((progress) async {
        progress('downloading');
        if (first) c.reportPartialDownload();
        first = false;
      });
      await c.syncNow();
      expect(c.presentation.partial, isTrue);
      await c.syncNow();
      expect(c.presentation.partial, isFalse);
    });

    test('is logged', () async {
      late SyncCoordinator c;
      c = make((progress) async {
        progress('downloading');
        c.reportPartialDownload();
      });
      await c.syncNow();
      expect(logs.single, endsWith('PARTIAL'));
    });

    test('a real error after a partial download is still a failure', () async {
      late SyncCoordinator c;
      c = make((progress) async {
        progress('downloading');
        c.reportPartialDownload();
        progress('deriving');
        throw StateError('boom');
      });
      final r = await c.syncNow();
      expect(r.success, isFalse);
      expect(c.presentation.phase, 'failed');
      expect(c.presentation.partial, isFalse);
    });
  });

  group('calculate scope and skip', () {
    test('day 0 of N is shown as soon as the scope is known', () async {
      late SyncCoordinator c;
      final gate = Completer<void>();
      c = make((progress) async {
        progress('deriving');
        c.reportScope(4);
        await gate.future;
      });
      final f = c.syncNow();
      await Future<void>.delayed(Duration.zero);
      final calc = c.presentation.calculate!;
      expect(calc.dayIndex, 0);
      expect(calc.dayTotal, 4);
      expect(c.presentation.step(SyncStepId.calculate).status,
          SyncStepStatus.running);
      gate.complete();
      await f;
    });

    test('a finished day replaces day 0, keeping the total', () async {
      late SyncCoordinator c;
      c = make((progress) async {
        progress('deriving');
        c.reportScope(3);
        c.reportDay('2026-10-02', 1, 3);
      });
      await c.syncNow();
      expect(c.presentation.calculate!.dayIndex, 1);
      expect(c.presentation.calculate!.dayTotal, 3);
    });

    test('a scope of zero marks Calculate skipped: nothing new', () async {
      late SyncCoordinator c;
      c = make((progress) async {
        progress('downloading');
        progress('deriving');
        c.reportScope(0);
      });
      final r = await c.syncNow();
      expect(r.success, isTrue);
      final calc = c.presentation.step(SyncStepId.calculate);
      expect(calc.status, SyncStepStatus.skipped);
      expect(calc.note, 'Skipped — nothing new');
      expect(c.presentation.step(SyncStepId.done).status, SyncStepStatus.done);
      expect(c.presentation.phase, 'completed');
    });

    test('is logged as calculate=skipped', () async {
      late SyncCoordinator c;
      c = make((progress) async {
        progress('deriving');
        c.reportScope(0);
      });
      await c.syncNow();
      expect(logs.single, contains('calculate=skipped'));
    });

    test('scope outside a sync is ignored', () {
      final c = make((progress) async {});
      c.reportScope(5);
      expect(c.presentation.calculate, isNull);
    });
  });

  group('cancellation and overlap', () {
    test('a timeout cancels the run token', () async {
      late SyncCoordinator c;
      late SyncCancelToken token;
      final stuck = Completer<void>();
      c = make((progress) async {
        token = c.cancelToken;
        progress('downloading');
        expect(token.isCancelled, isFalse);
        await stuck.future;
      }, timeout: const Duration(milliseconds: 30));
      final r = await c.syncNow();
      expect(r.success, isFalse);
      expect(token.isCancelled, isTrue);
      expect(() => token.throwIfCancelled(), throwsA(isA<SyncCancelled>()));
      stuck.complete();
    });

    test('a normal finish does not cancel the token', () async {
      late SyncCoordinator c;
      late SyncCancelToken token;
      c = make((progress) async {
        token = c.cancelToken;
        progress('downloading');
      });
      await c.syncNow();
      expect(token.isCancelled, isFalse);
    });

    test('a new sync waits for the timed-out run to unwind', () async {
      final events = <String>[];
      final release = Completer<void>();
      var calls = 0;
      late SyncCoordinator c;
      c = make((progress) async {
        final n = ++calls;
        final token = c.cancelToken;
        events.add('start$n');
        progress('downloading');
        if (n == 1) {
          await release.future; // the old run is mid-step
          events.add('old-saw-cancel=${token.isCancelled}');
          events.add('end1');
          return;
        }
        events.add('end$n');
      },
          timeout: const Duration(milliseconds: 30),
          retireGrace: const Duration(seconds: 5));

      expect((await c.syncNow()).success, isFalse);

      final second = c.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(events, ['start1'], reason: 'the retired run is still unwinding');
      release.complete();
      expect((await second).success, isTrue);
      expect(events, ['start1', 'old-saw-cancel=true', 'end1', 'start2', 'end2']);
    });

    test('a retired run that never unwinds is abandoned after the grace',
        () async {
      var calls = 0;
      final never = Completer<void>();
      final c = make((progress) async {
        calls++;
        progress('downloading');
        if (calls == 1) await never.future;
      },
          timeout: const Duration(milliseconds: 30),
          retireGrace: const Duration(milliseconds: 60));
      await c.syncNow();
      final r = await c.syncNow();
      expect(r.success, isTrue);
      expect(calls, 2);
      never.complete();
    });

    test('a retired run that throws after cancel does not disturb the new one',
        () async {
      final release = Completer<void>();
      var calls = 0;
      late SyncCoordinator c;
      c = make((progress) async {
        final n = ++calls;
        final token = c.cancelToken;
        progress('downloading');
        if (n == 1) {
          await release.future;
          token.throwIfCancelled();
        }
      },
          timeout: const Duration(milliseconds: 30),
          retireGrace: const Duration(seconds: 5));
      await c.syncNow();
      final second = c.syncNow();
      release.complete();
      expect((await second).success, isTrue);
      expect(c.presentation.phase, 'completed');
      expect(c.presentation.busy, isFalse);
    });

    test('each sync gets its own token', () async {
      final tokens = <SyncCancelToken>[];
      late SyncCoordinator c;
      c = make((progress) async => tokens.add(c.cancelToken));
      await c.syncNow();
      await c.syncNow();
      expect(identical(tokens[0], tokens[1]), isFalse);
    });
  });
}
