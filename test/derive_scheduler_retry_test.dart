// The scheduler acts on how a pass ended.
//
// The bug: `_drain` called `LocalDb.completeComputeJob` (delete) whenever
// `run(kind:)` returned, and a pass that blew up, was refused because another
// pass held the engine, or skipped days transiently was reported as done. The
// durable job that should have been retried was gone.
//
// API:
//
//   lib/compute/derive_outcome.dart   DeriveOutcome, deriveRetryBackoff,
//                                     kDeriveMaxAttempts (see
//                                     derive_outcome_test.dart)
//
//   DeriveScheduler(
//     run: Future<DeriveOutcome> Function({required DeriveJobKind kind}),
//     ...existing parameters...,
//     Duration Function(int attempts) retryBackoff = deriveRetryBackoff,
//     int maxAttempts = kDeriveMaxAttempts,
//   )
//
//   LocalDb.retryComputeJob(String id, String error, Duration backoff)
//     -> state 'queued', next_run_at = now + backoff (epoch ms), reason =
//        error, attempts and type left as they are, updated_at = now.
//
//   `_drain` after `run` returns [outcome]:
//     * outcome.complete                    -> completeComputeJob (row deleted)
//     * !complete, attempts < maxAttempts   -> retryComputeJob(id,
//                                              outcome.error ?? <non-empty
//                                              text>, retryBackoff(attempts))
//     * !complete, attempts >= maxAttempts  -> failComputeJob (state 'failed')
//     * `run` throws                        -> the SAME retry path (not
//                                              straight to 'failed')
//   where `attempts` is the job's count after `takeNextComputeJob` claimed it
//   (1 on the first try). A retry must actually run: the scheduler arms a
//   timer for the earliest next_run_at of a queued job (no tight loop, no
//   other trigger needed), and `pendingLight` / `pendingHeavy` do NOT count a
//   not-yet-due job as drain-now work.
//
// Enqueue semantics: stored data that arrives while a pass
// is running (`markStoredData` mid-run) gets its own follow-up pass.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_outcome.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<List<Map<String, dynamic>>> _jobs() async {
  final db = await LocalDb.instance;
  return db.query('compute_jobs', where: "scope = 'derive'");
}

/// Poll the job table until [ok] holds (the scheduler writes the outcome of a
/// pass just after `running` flips).
Future<void> _jobsSettle(bool Function(List<Map<String, dynamic>>) ok) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    final jobs = await _jobs();
    try {
      if (ok(jobs)) return;
    } on StateError {
      // `single` on an empty or longer list: not settled yet.
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<Map<String, dynamic>?> _job() async {
  final jobs = await _jobs();
  return jobs.isEmpty ? null : jobs.single;
}

const _settle = Duration(milliseconds: 10);
const _ok = DeriveOutcome(computed: 1);
const _transient = DeriveOutcome(computed: 0, transientFailures: 1);
const _busy = DeriveOutcome(failed: true, error: 'busy');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_scheduler_retry_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() => LocalDb.close());

  setUp(() async {
    final db = await LocalDb.instance;
    await db.delete('compute_jobs');
  });

  late DeriveScheduler s;
  DeriveScheduler? made;
  tearDown(() {
    made?.dispose();
    made = null;
  });

  /// A scheduler whose run callback answers from [answers] in order (the last
  /// one repeats) and records each call.
  DeriveScheduler build(
    List<Object> answers, {
    List<DeriveJobKind>? kinds,
    Duration Function(int attempts)? backoff,
    int? maxAttempts,
    Future<void> Function()? during,
  }) {
    var i = 0;
    return made = s = DeriveScheduler(
      run: ({required DeriveJobKind kind}) async {
        kinds?.add(kind);
        await during?.call();
        final a = answers[i < answers.length ? i : answers.length - 1];
        i++;
        if (a is DeriveOutcome) return a;
        throw a;
      },
      log: (_) {},
      onChanged: () {},
      lightSettle: _settle,
      heavySettle: _settle,
      retryBackoff: backoff ?? deriveRetryBackoff,
      maxAttempts: maxAttempts ?? kDeriveMaxAttempts,
    );
  }

  group('retryComputeJob (db)', () {
    test('requeues with a due time and the error, attempts kept', () async {
      await LocalDb.enqueueDeriveJob(type: 'derive_light', reason: 'test');
      final taken = (await LocalDb.takeNextComputeJob())!;
      expect(taken['attempts'], 1);

      final before = DateTime.now().millisecondsSinceEpoch;
      await LocalDb.retryComputeJob(
          taken['id'] as String, 'busy', const Duration(seconds: 30));
      final after = DateTime.now().millisecondsSinceEpoch;

      final row = (await _job())!;
      expect(row['state'], 'queued');
      expect(row['reason'], 'busy');
      expect(row['attempts'], 1, reason: 'a retry is still an attempt');
      expect(row['type'], 'derive_light');
      final due = row['next_run_at'] as int;
      expect(due, inInclusiveRange(before + 30000, after + 30000));
    });

    test('a job that is not due is not claimed; once due, it is, and the '
        'attempt count goes on', () async {
      await LocalDb.enqueueDeriveJob(type: 'derive_light', reason: 'test');
      final taken = (await LocalDb.takeNextComputeJob())!;
      await LocalDb.retryComputeJob(
          taken['id'] as String, 'x', const Duration(minutes: 5));
      expect(await LocalDb.takeNextComputeJob(), isNull);

      final db = await LocalDb.instance;
      await db.update('compute_jobs', {'next_run_at': 1});
      final again = await LocalDb.takeNextComputeJob();
      expect(again, isNotNull);
      expect(again!['attempts'], 2);
    });
  });

  group('what _drain does with an outcome', () {
    test('complete => the job is deleted', () async {
      final kinds = <DeriveJobKind>[];
      build([_ok], kinds: kinds);
      s.markStoredData();
      await _until(() => kinds.length == 1);
      await _until(() => !s.running);
      await _jobsSettle((jobs) => jobs.isEmpty);
      expect(await _jobs(), isEmpty);
    });

    test('an incomplete pass keeps the job: queued, attempts 1, due in 30 s, '
        'reason from the outcome', () async {
      final kinds = <DeriveJobKind>[];
      build([_busy], kinds: kinds);
      final before = DateTime.now().millisecondsSinceEpoch;
      s.markStoredData();
      await _until(() => kinds.length == 1);
      await _until(() => !s.running);

      final row = (await _job())!;
      expect(row['state'], 'queued');
      expect(row['attempts'], 1);
      expect(row['reason'], 'busy');
      expect(row['type'], 'derive_light');
      final due = row['next_run_at'] as int;
      expect(due - before, inInclusiveRange(30000, 30000 + 5000),
          reason: '30 s * 2^(1-1), measured from when the pass ended');
      expect(kinds, hasLength(1), reason: 'no tight loop: not due yet');
    });

    test('a transient-only outcome (no pass error) is retried too', () async {
      final kinds = <DeriveJobKind>[];
      build([_transient], kinds: kinds);
      s.markStoredData();
      await _until(() => kinds.length == 1);
      await _until(() => !s.running);

      final row = (await _job())!;
      expect(row['state'], 'queued');
      expect((row['reason'] as String?) ?? '', isNotEmpty,
          reason: 'say why it is waiting even when the outcome has no error');
    });

    test('a heavy job is retried as a heavy job', () async {
      final kinds = <DeriveJobKind>[];
      build([_busy], kinds: kinds);
      s.requestHeavy();
      await _until(() => kinds.length == 1);
      await _until(() => !s.running);
      expect(kinds, [DeriveJobKind.heavy]);
      final row = (await _job())!;
      expect(row['type'], 'derive_heavy');
      expect(row['state'], 'queued');
    });

    test('a thrown error is a retry, not a straight failure', () async {
      final kinds = <DeriveJobKind>[];
      build([StateError('boom')], kinds: kinds);
      s.markStoredData();
      await _until(() => kinds.length == 1);
      await _until(() => !s.running);

      final row = (await _job())!;
      expect(row['state'], 'queued');
      expect(row['reason'], contains('boom'));
      expect(row['attempts'], 1);
      expect(row['next_run_at'], isNotNull);
    });

    test('the second failure waits 60 s and keeps counting attempts',
        () async {
      final kinds = <DeriveJobKind>[];
      build([_busy], kinds: kinds);
      s.markStoredData();
      await _until(() => kinds.length == 1);
      await _until(() => !s.running);

      // Make the retry due now, then hand the scheduler a reason to look.
      final db = await LocalDb.instance;
      await db.update('compute_jobs', {'next_run_at': 1});
      await s.init();
      await _until(() => kinds.length == 2);
      await _until(() => !s.running);

      final before = DateTime.now().millisecondsSinceEpoch;
      final row = (await _job())!;
      expect(row['state'], 'queued');
      expect(row['attempts'], 2);
      final due = row['next_run_at'] as int;
      expect(due - before, inInclusiveRange(55000, 60000 + 2000),
          reason: '30 s * 2^(2-1)');
    });
  });

  group('with a short backoff the retry runs by itself', () {
    test('a due retry is drained by the scheduler\'s own timer', () async {
      final kinds = <DeriveJobKind>[];
      final stamps = <int>[];
      build(
        [_busy, _ok],
        kinds: kinds,
        backoff: (_) => const Duration(milliseconds: 250),
        during: () async => stamps.add(DateTime.now().millisecondsSinceEpoch),
      );
      s.markStoredData();
      await _until(() => kinds.length == 2);

      expect(kinds, [DeriveJobKind.light, DeriveJobKind.light],
          reason: 'nothing else triggered it: a timer did');
      expect(stamps[1] - stamps[0], greaterThanOrEqualTo(240),
          reason: 'not before it is due');
      await _until(() => !s.running);
      expect(await _jobs(), isEmpty, reason: 'the second pass was complete');
    });

    test('while the retry waits out its backoff nothing runs and the '
        'pending flags stay down', () async {
      final kinds = <DeriveJobKind>[];
      build([_busy, _ok],
          kinds: kinds, backoff: (_) => const Duration(milliseconds: 600));
      s.markStoredData();
      await _until(() => kinds.length == 1);
      await _until(() => !s.running);

      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(kinds, hasLength(1), reason: 'not due yet: no tight loop');
      expect(s.pendingLight, isFalse,
          reason: 'a not-yet-due job is not drain-now work');
      expect((await _job())!['state'], 'queued');

      await _until(() => kinds.length == 2);
      expect(kinds, hasLength(2));
    });

    test('five failures park the job as failed, and it stops retrying',
        () async {
      final kinds = <DeriveJobKind>[];
      build([_busy],
          kinds: kinds, backoff: (_) => const Duration(milliseconds: 20));
      s.markStoredData();
      await _until(() => kinds.length >= 5);
      await _until(() => !s.running);
      await _jobsSettle((jobs) => jobs.single['state'] == 'failed');

      final row = (await _job())!;
      expect(row['state'], 'failed');
      expect(row['attempts'], 5);
      expect(row['reason'], 'busy');

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(kinds, hasLength(5), reason: 'a failed job is not retried again');
    });

    test('five thrown errors park it too', () async {
      final kinds = <DeriveJobKind>[];
      build([StateError('disk gone')],
          kinds: kinds, backoff: (_) => const Duration(milliseconds: 20));
      s.markStoredData();
      await _until(() => kinds.length >= 5);
      await _until(() => !s.running);
      await _jobsSettle((jobs) => jobs.single['state'] == 'failed');

      final row = (await _job())!;
      expect(row['state'], 'failed');
      expect(row['reason'], contains('disk gone'));
    });

    test('maxAttempts is honoured', () async {
      final kinds = <DeriveJobKind>[];
      build([_busy],
          kinds: kinds,
          maxAttempts: 2,
          backoff: (_) => const Duration(milliseconds: 20));
      s.markStoredData();
      await _until(() => kinds.length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(kinds, hasLength(2));
      expect((await _job())!['state'], 'failed');
    });
  });

  group('enqueue: data stored mid-run gets its own follow-up pass', () {
    test('markStoredData while a light pass runs => a second pass afterwards',
        () async {
      final kinds = <DeriveJobKind>[];
      final inFlight = Completer<void>();
      final release = Completer<void>();
      var firstCall = true;
      build(
        [_ok],
        kinds: kinds,
        during: () async {
          if (!firstCall) return;
          firstCall = false;
          inFlight.complete();
          await release.future; // new data lands while this pass runs
        },
      );
      s.markStoredData();
      await inFlight.future;
      expect(s.running, isTrue);

      s.markStoredData(); // the drain stored more rows
      await _until(() => s.pendingLight);
      expect(s.pendingLight, isTrue,
          reason: 'the running job does not absorb it');

      release.complete();
      await _until(() => kinds.length == 2);
      expect(kinds, [DeriveJobKind.light, DeriveJobKind.light]);
      await _until(() => !s.running);
      expect(await _jobs(), isEmpty);
    });

    test('three stored-data ticks mid-run still produce ONE follow-up',
        () async {
      final kinds = <DeriveJobKind>[];
      final inFlight = Completer<void>();
      final release = Completer<void>();
      var firstCall = true;
      build(
        [_ok],
        kinds: kinds,
        during: () async {
          if (!firstCall) return;
          firstCall = false;
          inFlight.complete();
          await release.future;
        },
      );
      s.markStoredData();
      await inFlight.future;
      s.markStoredData();
      s.markStoredData();
      s.markStoredData();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      release.complete();
      await _until(() => kinds.length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(kinds, hasLength(2));
    });
  });
}
