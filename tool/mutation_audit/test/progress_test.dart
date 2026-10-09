import 'dart:convert';
import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/fake_time.dart';
import 'support/git_fixture.dart';

Mutant mutant({int line = 12, String id = 'lib/a.dart:30:relational:ab12cd34'}) => Mutant(
      id: id,
      file: 'lib/a.dart',
      line: line,
      column: 5,
      byteOffset: 30,
      byteLength: 1,
      operator: MutationOperator.relational,
      original: '<',
      mutated: '<=',
    );

void main() {
  late FakeTime time;
  late List<String> lines;

  ProgressReporter reporter({Duration heartbeat = const Duration(seconds: 60), String? logPath}) => ProgressReporter(
        now: time.now,
        write: lines.add,
        heartbeat: heartbeat,
        alarm: time.alarm,
        logPath: logPath,
      );

  setUp(() {
    time = FakeTime();
    lines = [];
  });

  group('formatDuration', () {
    test('seconds with a decimal under ten, whole seconds under a minute, then m and h', () {
      String f(int ms) => ProgressReporter.formatDuration(Duration(milliseconds: ms));
      expect(f(0), '0.0s');
      expect(f(3400), '3.4s');
      expect(f(12000), '12s');
      expect(f(59400), '59s');
      expect(f(60000), '1m00s');
      expect(f(125000), '2m05s');
      expect(f(3723000), '1h02m03s');
      expect(f(7200000), '2h00m00s');
    });
  });

  group('lines', () {
    test('every line carries the wall-clock time of the injected clock, and is written at once', () async {
      final r = reporter();
      r.line('export created: /tmp/x at abc');
      await time.advance(const Duration(seconds: 75));
      r.line('later');
      expect(lines, ['2026-10-09T08:00:00Z export created: /tmp/x at abc', '2026-10-09T08:01:15Z later']);
    });

    test('a step prints start, then done with how long it took (and what it found)', () async {
      final r = reporter();
      final setup = r.step('setup');
      await time.advance(const Duration(seconds: 90));
      setup();
      final baseline = r.step('baseline');
      await time.advance(const Duration(milliseconds: 3400));
      baseline('12 tests passed');
      expect(lines, [
        '2026-10-09T08:00:00Z setup start',
        '2026-10-09T08:01:30Z setup done in 1m30s',
        '2026-10-09T08:01:30Z baseline start',
        '2026-10-09T08:01:33Z baseline done in 3.4s: 12 tests passed',
      ]);
    });

    test('the silent reporter writes nothing and sets no timer', () async {
      final r = ProgressReporter.silent();
      r.line('x');
      r.step('s')();
      expect(await r.tracked('mutant', (o) async => 5), 5);
    });
  });

  group('mutants: start line, end line, ETA from the mean so far', () {
    test('lines have the documented shape', () async {
      final r = reporter();
      final m = mutant();
      r.mutantStarted(1, 3, m);
      await time.advance(const Duration(seconds: 10));
      r.mutantFinished(
          1,
          3,
          m,
          const Classification(status: MutantStatus.killed, killers: [
            KillingTest('test/a_test.dart::g one', FailureKind.assertion),
            KillingTest('test/a_test.dart::g two', FailureKind.exception),
          ], discounted: [
            DiscountedFailure('test/guard_test.dart::g scan', ['reads lib']),
          ]));
      expect(lines, [
        "2026-10-09T08:00:00Z [1/3] lib/a.dart:30:relational:ab12cd34 lib/a.dart:12 relational '<'→'<='",
        '2026-10-09T08:00:10Z [1/3] killed (2 killing, 1 discounted) 10s; elapsed 10s; ETA 20s',
      ]);
    });

    test('ETA is the mean duration so far times what is left; elapsed counts from the first start', () async {
      final r = reporter();
      const none = Classification(status: MutantStatus.survived);
      final ends = <String>[];
      for (final (i, secs) in [(1, 10), (2, 20), (3, 60), (4, 10)]) {
        r.mutantStarted(i, 4, mutant());
        await time.advance(Duration(seconds: secs));
        r.mutantFinished(i, 4, mutant(), none);
        ends.add(lines.last);
      }
      expect(ends, [
        '2026-10-09T08:00:10Z [1/4] survived (0 killing, 0 discounted) 10s; elapsed 10s; ETA 30s',
        // mean (10+20)/2 = 15, two left
        '2026-10-09T08:00:30Z [2/4] survived (0 killing, 0 discounted) 20s; elapsed 30s; ETA 30s',
        // mean (10+20+60)/3 = 30, one left
        '2026-10-09T08:01:30Z [3/4] survived (0 killing, 0 discounted) 1m00s; elapsed 1m30s; ETA 30s',
        // nothing left
        '2026-10-09T08:01:40Z [4/4] survived (0 killing, 0 discounted) 10s; elapsed 1m40s; ETA 0.0s',
      ]);
    });

    test('time between mutants counts in "elapsed" but the mean is of the mutants themselves', () async {
      final r = reporter();
      const none = Classification(status: MutantStatus.survived);
      r.mutantStarted(1, 2, mutant());
      await time.advance(const Duration(seconds: 10));
      r.mutantFinished(1, 2, mutant(), none);
      await time.advance(const Duration(seconds: 5)); // restoring the file, integrity checks
      r.mutantStarted(2, 2, mutant());
      await time.advance(const Duration(seconds: 30));
      r.mutantFinished(2, 2, mutant(), none);
      expect(lines.last, endsWith('30s; elapsed 45s; ETA 0.0s'));
    });
  });

  group('memory on the mutant lines', () {
    test('the end line shows the peak when it is known; resource-limit is a status like any other', () async {
      final r = reporter();
      r.mutantStarted(1, 2, mutant());
      await time.advance(const Duration(seconds: 4));
      r.mutantFinished(1, 2, mutant(), const Classification(status: MutantStatus.survived), memoryPeakBytes: 812 * 1024 * 1024);
      r.mutantStarted(2, 2, mutant());
      await time.advance(const Duration(seconds: 6));
      r.mutantFinished(2, 2, mutant(), const Classification(status: MutantStatus.resourceLimit), memoryPeakBytes: 4 * 1024 * 1024 * 1024);
      expect(lines[1], endsWith('[1/2] survived (0 killing, 0 discounted) 4.0s, peak 812M; elapsed 4.0s; ETA 4.0s'));
      expect(lines[3], endsWith('[2/2] resource-limit (0 killing, 0 discounted) 6.0s, peak 4.0G; elapsed 10s; ETA 0.0s'));
    });

    test('progress.jsonl carries memoryPeakBytes when known, and leaves the key out when not', () {
      final dir = scratch('mutaudit_progress_mem_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'progress.jsonl');
      final r = reporter(logPath: path);
      r.mutantStarted(1, 2, mutant());
      r.mutantFinished(1, 2, mutant(), const Classification(status: MutantStatus.survived), memoryPeakBytes: 123456);
      r.mutantStarted(2, 2, mutant());
      r.mutantFinished(2, 2, mutant(), const Classification(status: MutantStatus.resourceLimit));
      final rows = [for (final l in File(path).readAsLinesSync()) jsonDecode(l) as Map<String, dynamic>];
      expect(rows[0]['memoryPeakBytes'], 123456);
      expect(rows[1].containsKey('memoryPeakBytes'), isFalse);
      expect(rows[1]['status'], 'resource-limit');
    });
  });

  group('heartbeat', () {
    test('every interval while the run is in progress, with pid, counts from the stream and the last test; none after', () async {
      final r = reporter();
      final stream = StreamBuilder().loaded('test/a_test.dart').pass('test/a_test.dart', 'g one').fail('test/a_test.dart', 'g two').unfinished('test/a_test.dart', 'g three');
      late RunObserver watcher;
      final body = r.tracked('mutant', (o) async {
        watcher = o;
        o.onStart!(4242);
        stream.lines.forEach(o.onStdoutLine!);
        await time.advance(const Duration(seconds: 150));
        return 'done';
      }, position: '[3/10]');
      expect(await body, 'done');
      expect(watcher, isNotNull);
      expect(lines, [
        '2026-10-09T08:01:00Z … still running mutant [3/10] for 1m00s (pid 4242): 2 tests done (1 passed, 1 failed), last: g three',
        '2026-10-09T08:02:00Z … still running mutant [3/10] for 2m00s (pid 4242): 2 tests done (1 passed, 1 failed), last: g three',
      ]);
      expect(time.pending, 0, reason: 'the heartbeat timer was dropped with the run');
      await time.advance(const Duration(minutes: 10));
      expect(lines, hasLength(2), reason: 'no heartbeat after the run ended');
    });

    test('numbers follow the stream between beats', () async {
      final r = reporter();
      final b = StreamBuilder();
      final first = b.loaded('test/a_test.dart').pass('test/a_test.dart', 'g one').build();
      final more = (b..pass('test/a_test.dart', 'g two')..pass('test/a_test.dart', 'g three')).build().skip(first.length);
      await r.tracked('baseline', (o) async {
        first.forEach(o.onStdoutLine!);
        await time.advance(const Duration(seconds: 60));
        more.forEach(o.onStdoutLine!);
        await time.advance(const Duration(seconds: 60));
      });
      expect(lines.map((l) => l.replaceFirst(RegExp(r'^.*? for \S+: '), '')), ['1 tests done (1 passed, 0 failed), last: g one', '3 tests done (3 passed, 0 failed), last: g three']);
    });

    test('before any output or pid: counts are zero, no last test, no pid', () async {
      final r = reporter();
      await r.tracked('setup', (o) => time.advance(const Duration(seconds: 61)));
      expect(lines, ['2026-10-09T08:01:00Z … still running setup for 1m00s: 0 tests done (0 passed, 0 failed)']);
    });

    test('--heartbeat 0 (a zero interval) sets no timer and prints nothing', () async {
      final r = reporter(heartbeat: Duration.zero);
      await r.tracked('mutant', (o) async {
        expect(time.pending, 0);
        o.onStdoutLine!('{"type":"x"}');
        await time.advance(const Duration(hours: 3));
      });
      expect(lines, isEmpty);
    });

    test('a body that throws still stops the heartbeat', () async {
      final r = reporter();
      await expectLater(
          r.tracked('baseline', (o) async {
            await time.advance(const Duration(seconds: 61));
            throw StateError('boom');
          }),
          throwsStateError);
      expect(lines, hasLength(1));
      expect(time.pending, 0);
      await time.advance(const Duration(minutes: 5));
      expect(lines, hasLength(1));
    });

    test('a second run gets its own count and its own interval', () async {
      final r = reporter();
      await r.tracked('mutant', (o) async {
        o.onStdoutLine!(StreamBuilder().pass('test/a_test.dart', 'g one').lines.where((l) => l.contains('testStart') || l.contains('testDone')).first);
        await time.advance(const Duration(seconds: 61));
      }, position: '[1/2]');
      await r.tracked('rerun test/a_test.dart::g one', (o) async {
        await time.advance(const Duration(seconds: 61));
      }, position: '[1/2]');
      expect(lines.last, endsWith('still running rerun test/a_test.dart::g one [1/2] for 1m00s: 0 tests done (0 passed, 0 failed)'));
    });
  });

  group('progress.jsonl', () {
    late Directory dir;
    late String path;
    setUp(() {
      dir = scratch('mutaudit_progress_');
      path = p.join(dir.path, 'progress.jsonl');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    List<Map<String, dynamic>> rows() =>
        [for (final l in File(path).readAsLinesSync()) jsonDecode(l) as Map<String, dynamic>];

    test('meta first, then one line per finished mutant, each written as it happens; all marked partial', () async {
      final r = reporter(logPath: path);
      r.writeMeta({'sha': 'abc123', 'seed': 7, 'selected': 2, 'candidates': 9});
      expect(rows(), [
        {'type': 'meta', 'partial': true, 'sha': 'abc123', 'seed': 7, 'selected': 2, 'candidates': 9},
      ]);

      r.mutantStarted(1, 2, mutant());
      await time.advance(const Duration(milliseconds: 2500));
      r.mutantFinished(
          1,
          2,
          mutant(),
          const Classification(status: MutantStatus.killed, killers: [
            KillingTest('test/a_test.dart::g one', FailureKind.assertion, confirmedKind: FailureKind.assertion),
          ], discounted: [
            DiscountedFailure('test/guard_test.dart::g scan', ['reads lib']),
          ]));
      // on disk before the second mutant even starts
      final first = rows()[1];
      expect(first, {
        'type': 'mutant',
        'partial': true,
        'index': 1,
        'total': 2,
        'id': 'lib/a.dart:30:relational:ab12cd34',
        'file': 'lib/a.dart',
        'line': 12,
        'operator': 'relational',
        'status': 'killed',
        'killers': [
          {'test': 'test/a_test.dart::g one', 'kind': 'assertion'}
        ],
        'discounted': ['test/guard_test.dart::g scan'],
        'durationMs': 2500,
      });

      r.mutantStarted(2, 2, mutant(id: 'lib/a.dart:40:relational:ffff0000', line: 20));
      r.mutantFinished(2, 2, mutant(id: 'lib/a.dart:40:relational:ffff0000', line: 20), const Classification(status: MutantStatus.survived));
      expect(rows(), hasLength(3));
      expect(rows()[2]['status'], 'survived');
      expect(rows()[2]['killers'], isEmpty);
    });

    test('a new run starts the file afresh (meta replaces what an earlier run left)', () {
      File(path).writeAsStringSync('{"old":true}\n{"old":true}\n');
      reporter(logPath: path).writeMeta({'sha': 'x'});
      expect(rows(), hasLength(1));
      expect(rows().single['sha'], 'x');
    });

    test('a log that cannot be written is said once on the progress stream and does not stop the audit', () {
      File(p.join(dir.path, 'file.txt')).writeAsStringSync('');
      final r = reporter(logPath: p.join(dir.path, 'file.txt', 'progress.jsonl'));
      r.writeMeta({'sha': 'x'});
      r.mutantStarted(1, 1, mutant());
      r.mutantFinished(1, 1, mutant(), const Classification(status: MutantStatus.survived));
      expect(lines.where((l) => l.contains('progress.jsonl')), hasLength(1));
      expect(lines.last, contains('[1/1] survived'));
    });

    test('no log path: no file', () {
      reporter().writeMeta({'sha': 'x'});
      expect(File(path).existsSync(), isFalse);
    });
  });
}
