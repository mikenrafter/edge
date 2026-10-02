// 8M — the sync coordinator publishes REAL step status: which step is running,
// how long each took, what the download has banked so far and which day the
// calculation is on. Every clock is injected; nothing here sleeps for a step.
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
    bool connected = false,
    Duration timeout = const Duration(seconds: 30),
    Duration interval = const Duration(milliseconds: 250),
    Duration retireGrace = const Duration(milliseconds: 20),
  }) => SyncCoordinator(
    run: run,
    isConnected: () => connected,
    reloadLocal: () async {},
    timeout: timeout,
    clock: () => t,
    log: logs.add,
    progressInterval: interval,
    retireGrace: retireGrace,
  );

  List<SyncStepStatus> statuses(SyncCoordinator c) => [
    for (final s in c.presentation.steps) s.status,
  ];

  test('publishes connect, download, calculate and done with timings', () async {
    late SyncCoordinator c;
    final seen = <List<SyncStepStatus>>[];
    c = make((progress) async {
      progress('connecting');
      t = t.add(const Duration(seconds: 2));
      progress('downloading');
      t = t.add(const Duration(seconds: 10));
      progress('deriving');
      t = t.add(const Duration(seconds: 4));
    });
    c.addListener(() => seen.add(statuses(c)));
    await c.syncNow();

    expect([for (final s in c.presentation.steps) s.id], [
      SyncStepId.connect,
      SyncStepId.download,
      SyncStepId.calculate,
      SyncStepId.done,
    ]);
    // Each phase change was published as it happened, not only at the end.
    expect(
      seen,
      contains(
        equals([
          SyncStepStatus.done,
          SyncStepStatus.running,
          SyncStepStatus.waiting,
          SyncStepStatus.waiting,
        ]),
      ),
    );
    expect(
      seen,
      contains(
        equals([
          SyncStepStatus.done,
          SyncStepStatus.done,
          SyncStepStatus.running,
          SyncStepStatus.waiting,
        ]),
      ),
    );
    expect(statuses(c), everyElement(SyncStepStatus.done));
    final p = c.presentation;
    expect(p.step(SyncStepId.connect).duration(), const Duration(seconds: 2));
    expect(p.step(SyncStepId.download).duration(), const Duration(seconds: 10));
    expect(p.step(SyncStepId.calculate).duration(), const Duration(seconds: 4));
    expect(
      p.step(SyncStepId.download).startedAt,
      DateTime(2026, 10, 2, 9, 0, 2),
    );
    expect(p.startedAt, DateTime(2026, 10, 2, 9));
    expect(p.finishedAt, t);
    expect(p.elapsed(t), const Duration(seconds: 16));
    expect(p.busy, isFalse);
    expect(p.lastSuccess, t);
    expect(p.phase, 'completed');
  });

  test('a link that is already up marks connect skipped, not done', () async {
    // _manualSync does not announce 'connecting' when the link is up.
    final c = make((progress) async {
      progress('downloading');
    }, connected: true);
    await c.syncNow();
    final connect = c.presentation.step(SyncStepId.connect);
    expect(connect.status, SyncStepStatus.skipped);
    expect(connect.note, 'Already connected');
  });

  test('a running elapsed time keeps counting until the sync ends', () async {
    final gate = Completer<void>();
    final c = make((progress) async {
      progress('downloading');
      await gate.future;
    });
    final f = c.syncNow();
    await Future<void>.delayed(Duration.zero);
    t = t.add(const Duration(seconds: 7));
    expect(c.presentation.elapsed(t), const Duration(seconds: 7));
    t = t.add(const Duration(seconds: 3));
    expect(c.presentation.elapsed(t), const Duration(seconds: 10));
    gate.complete();
    await f;
    t = t.add(const Duration(hours: 1));
    // Finished: the elapsed time is frozen at the end, not the wall clock.
    expect(c.presentation.elapsed(t), const Duration(seconds: 10));
  });

  group('download progress', () {
    test('counts advance from engine commits', () async {
      late SyncCoordinator c;
      final counts = <(int, int)>[];
      c = make((progress) async {
        progress('downloading');
        c.reportCommit(
          records: 300,
          newest: DateTime(2026, 10, 1, 22),
          bandNewest: DateTime(2026, 10, 2, 8),
        );
        counts.add((
          c.presentation.download!.records,
          c.presentation.download!.chunks,
        ));
        c.reportCommit(records: 450, newest: DateTime(2026, 10, 2, 1));
        counts.add((
          c.presentation.download!.records,
          c.presentation.download!.chunks,
        ));
      });
      await c.syncNow();
      expect(counts, [(300, 1), (750, 2)]);
      final d = c.presentation.download!;
      // "Synced through" is the newest committed record.
      expect(d.syncedThrough, DateTime(2026, 10, 2, 1));
      // The band's own newest was reported on the first commit and kept.
      expect(d.bandNewest, DateTime(2026, 10, 2, 8));
      expect(d.backlog, const Duration(hours: 7));
    });

    test('an older chunk never moves "synced through" backwards', () async {
      late SyncCoordinator c;
      c = make((progress) async {
        progress('downloading');
        c.reportCommit(records: 1, newest: DateTime(2026, 10, 2, 5));
        c.reportCommit(records: 1, newest: DateTime(2026, 10, 2, 3));
      });
      await c.syncNow();
      expect(
        c.presentation.download!.syncedThrough,
        DateTime(2026, 10, 2, 5),
      );
    });

    test('no backlog figure unless the band reported one', () async {
      late SyncCoordinator c;
      c = make((progress) async {
        progress('downloading');
        c.reportCommit(records: 10, newest: DateTime(2026, 10, 2, 5));
      });
      await c.syncNow();
      expect(c.presentation.download!.bandNewest, isNull);
      expect(c.presentation.download!.backlog, isNull);
    });

    test('a band newest behind what we hold is not a backlog', () async {
      late SyncCoordinator c;
      c = make((progress) async {
        progress('downloading');
        c.reportCommit(
          records: 10,
          newest: DateTime(2026, 10, 2, 5),
          bandNewest: DateTime(2026, 10, 2, 4),
        );
      });
      await c.syncNow();
      expect(c.presentation.download!.backlog, isNull);
    });

    test('commits outside a sync are ignored', () async {
      final c = make((progress) async => progress('downloading'));
      c.reportCommit(records: 99, newest: DateTime(2026, 10, 2));
      expect(c.presentation.download, isNull);
      await c.syncNow();
      c.reportCommit(records: 99, newest: DateTime(2026, 10, 2));
      expect(c.presentation.download!.records, 0);
    });

    test('a new sync starts its counts from zero', () async {
      late SyncCoordinator c;
      c = make((progress) async {
        progress('downloading');
        c.reportCommit(records: 40, newest: DateTime(2026, 10, 2));
      });
      await c.syncNow();
      expect(c.presentation.download!.records, 40);
      await c.syncNow();
      expect(c.presentation.download!.records, 40);
      expect(c.presentation.download!.chunks, 1);
    });
  });

  group('calculate progress', () {
    test('maps the derivation engine onDayDone to day i of n', () async {
      late SyncCoordinator c;
      final seen = <(int?, int?, String?)>[];
      c = make((progress) async {
        progress('deriving');
        c.reportDay('2026-10-02', 1, 5);
        seen.add((
          c.presentation.calculate!.dayIndex,
          c.presentation.calculate!.dayTotal,
          c.presentation.calculate!.day,
        ));
        c.reportDay('2026-10-01', 2, 5);
        seen.add((
          c.presentation.calculate!.dayIndex,
          c.presentation.calculate!.dayTotal,
          c.presentation.calculate!.day,
        ));
      });
      await c.syncNow();
      expect(seen, [(1, 5, '2026-10-02'), (2, 5, '2026-10-01')]);
    });

    test('before the first day finishes no day count is invented', () async {
      final gate = Completer<void>();
      final c = make((progress) async {
        progress('deriving');
        await gate.future;
      });
      final f = c.syncNow();
      await Future<void>.delayed(Duration.zero);
      final calc = c.presentation.calculate!;
      expect(
        c.presentation.step(SyncStepId.calculate).status,
        SyncStepStatus.running,
      );
      expect(calc.dayIndex, isNull);
      expect(calc.dayTotal, isNull);
      expect(calc.waiting, isFalse);
      gate.complete();
      await f;
    });

    test('says it is waiting while another calculation holds the lock', () async {
      late SyncCoordinator c;
      final waiting = <bool>[];
      c = make((progress) async {
        progress('deriving');
        c.reportWaitingForCalculation(true);
        waiting.add(c.presentation.calculate!.waiting);
        c.reportWaitingForCalculation(false);
        waiting.add(c.presentation.calculate!.waiting);
      });
      await c.syncNow();
      expect(waiting, [true, false]);
    });
  });

  group('failure', () {
    test('shows its reason in plain words and marks the step', () async {
      final c = make((progress) async {
        progress('connecting');
        throw StateError('Could not connect to the band');
      });
      final r = await c.syncNow();
      expect(r.success, isFalse);
      final p = c.presentation;
      expect(p.phase, 'failed');
      expect(p.busy, isFalse);
      expect(p.failureReason, 'Could not connect to the band');
      expect(p.step(SyncStepId.connect).status, SyncStepStatus.failed);
      expect(p.step(SyncStepId.download).status, SyncStepStatus.skipped);
      expect(p.step(SyncStepId.calculate).status, SyncStepStatus.skipped);
      expect(p.step(SyncStepId.done).status, SyncStepStatus.skipped);
      expect(p.finishedAt, isNotNull);
      // Existing callers keep working.
      expect(
        p.description,
        'Sync failed: Bad state: Could not connect to the band',
      );
    });

    test('a failure partway keeps the finished steps finished', () async {
      final c = make((progress) async {
        progress('connecting');
        progress('downloading');
        progress('deriving');
        throw StateError('x');
      });
      await c.syncNow();
      final p = c.presentation;
      expect(p.step(SyncStepId.connect).status, SyncStepStatus.done);
      expect(p.step(SyncStepId.download).status, SyncStepStatus.done);
      expect(p.step(SyncStepId.calculate).status, SyncStepStatus.failed);
    });

    test('plain-words mapping', () {
      expect(
        syncFailureReason(StateError('Band disconnected during sync')),
        'Band disconnected during sync',
      );
      expect(syncFailureReason(Exception('boom')), 'boom');
      expect(
        syncFailureReason(
          TimeoutException('Another calculation did not finish'),
        ),
        'Another calculation did not finish',
      );
      expect(
        syncFailureReason(TimeoutException(null)),
        'It took too long and was stopped.',
      );
    });
  });

  group('latches reset in finally', () {
    test('a throw leaves the coordinator able to sync again', () async {
      var calls = 0;
      final c = make((progress) async {
        calls++;
        if (calls == 1) throw StateError('first fails');
      });
      expect((await c.syncNow()).success, isFalse);
      expect(c.presentation.busy, isFalse);
      expect((await c.syncNow()).success, isTrue);
      expect(calls, 2);
      expect(c.presentation.phase, 'completed');
    });

    test(
      'a timeout retires the run: not busy, retry works, late finish ignored',
      () async {
        final stuck = Completer<void>();
        var calls = 0;
        late SyncCoordinator c;
        c = make((progress) async {
          calls++;
          progress('downloading');
          if (calls == 1) {
            await stuck.future;
            // A transport that finally answers after the deadline.
            c.reportCommit(records: 999, newest: DateTime(2026, 10, 2));
            progress('deriving');
          }
        }, timeout: const Duration(milliseconds: 40));
        final r = await c.syncNow();
        expect(r.success, isFalse);
        expect(c.presentation.busy, isFalse);
        expect(c.presentation.phase, 'failed');
        expect(c.presentation.failureReason, contains('too long'));
        expect(
          c.presentation.step(SyncStepId.download).status,
          SyncStepStatus.failed,
        );

        expect((await c.syncNow()).success, isTrue);
        expect(c.presentation.phase, 'completed');
        final before = c.presentation.download!.records;

        stuck.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // The retired run cannot touch the newer operation's counts or phase.
        expect(c.presentation.download!.records, before);
        expect(c.presentation.phase, 'completed');
      },
    );

    test(
      'dispose with a throttled notification pending does not throw',
      () async {
        late SyncCoordinator c;
        final gate = Completer<void>();
        c = make((progress) async {
          progress('downloading');
          c.reportCommit(records: 1, newest: DateTime(2026, 10, 2));
          c.reportCommit(records: 1, newest: DateTime(2026, 10, 2));
          await gate.future;
        });
        unawaited(c.syncNow());
        await Future<void>.delayed(Duration.zero);
        c.dispose();
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      },
    );
  });

  group('notification throttle', () {
    test(
      'a flood of commits inside one interval notifies at most twice',
      () async {
        late SyncCoordinator c;
        var notes = 0;
        c = make((progress) async {
          progress('downloading');
          c.addListener(() => notes++);
          for (var i = 0; i < 2000; i++) {
            c.reportCommit(records: 1, newest: DateTime(2026, 10, 2));
          }
        }, interval: const Duration(milliseconds: 30));
        await c.syncNow();
        // Counts are always current even when the notification is held back.
        expect(c.presentation.download!.records, 2000);
        // The final "completed" publish, plus at most one held-back refresh.
        expect(notes, lessThanOrEqualTo(2));
      },
    );

    test(
      'a long drain notifies about four times a second, not per chunk',
      () async {
        late SyncCoordinator c;
        var notes = 0;
        c = make((progress) async {
          progress('downloading');
          c.addListener(() => notes++);
          // 1000 chunks, 10 ms apart on the injected clock = 10 virtual s.
          for (var i = 0; i < 1000; i++) {
            t = t.add(const Duration(milliseconds: 10));
            c.reportCommit(records: 100, newest: DateTime(2026, 10, 2));
          }
        });
        await c.syncNow();
        expect(c.presentation.download!.records, 100000);
        expect(notes, lessThanOrEqualTo(10 * 4 + 3));
        expect(notes, greaterThan(10));
      },
    );

    test('the held-back update is delivered after the interval', () async {
      late SyncCoordinator c;
      final gate = Completer<void>();
      var lastSeen = -1;
      c = make((progress) async {
        progress('downloading');
        c.addListener(() => lastSeen = c.presentation.download!.records);
        c.reportCommit(records: 5, newest: DateTime(2026, 10, 2));
        c.reportCommit(records: 5, newest: DateTime(2026, 10, 2));
        await gate.future;
      }, interval: const Duration(milliseconds: 30));
      final f = c.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(lastSeen, 10);
      gate.complete();
      await f;
    });
  });

  group('[sync-timing] log', () {
    test('one line per sync with every step duration', () async {
      late SyncCoordinator c;
      c = make((progress) async {
        progress('connecting');
        t = t.add(const Duration(seconds: 2));
        progress('downloading');
        c.reportCommit(records: 250, newest: DateTime(2026, 10, 2));
        c.reportCommit(records: 350, newest: DateTime(2026, 10, 2));
        t = t.add(const Duration(seconds: 10));
        progress('deriving');
        c.reportWaitingForCalculation(true);
        t = t.add(const Duration(seconds: 3));
        c.reportWaitingForCalculation(false);
        t = t.add(const Duration(seconds: 4));
        c.reportDay('2026-10-02', 5, 5);
      });
      await c.syncNow();
      expect(logs, [
        '[sync-timing] connect=2000ms download=10000ms (600 records, 2 chunks) '
            'wait=3000ms calculate=4000ms (5 days) total=19000ms',
      ]);
    });

    test('a failed sync still logs once, naming what it never reached', () async {
      final c = make((progress) async {
        progress('connecting');
        t = t.add(const Duration(seconds: 6));
        throw StateError('Could not connect to the band');
      });
      await c.syncNow();
      expect(logs, hasLength(1));
      expect(
        logs.single,
        startsWith('[sync-timing] connect=6000ms download=-'),
      );
      expect(logs.single, contains('total=6000ms'));
      expect(logs.single, endsWith('FAILED'));
    });

    test('joined taps do not log extra lines', () async {
      final gate = Completer<void>();
      final c = make((progress) async => await gate.future, connected: true);
      final a = c.syncNow(), b = c.syncNow();
      gate.complete();
      await Future.wait([a, b]);
      expect(logs, hasLength(1));
    });
  });
}
