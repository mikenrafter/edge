import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/fake_time.dart';
import 'support/fakes.dart';
import 'support/git_fixture.dart';

const source = 'bool lt(int a, int b) { return a < b; }\nbool gt(int a, int b) { return a > b; }\n';

Mutant mutant(String original, String mutated, {int occurrence = 0, int line = 1}) {
  var at = -1;
  for (var i = 0; i <= occurrence; i++) {
    at = source.indexOf(original, at + 1);
  }
  return Mutant(
    id: 'lib/a.dart:$at:relational:${mutated.hashCode.toRadixString(16)}',
    file: 'lib/a.dart',
    line: line,
    column: at + 1,
    byteOffset: at,
    byteLength: original.length,
    operator: MutationOperator.relational,
    original: original,
    mutated: mutated,
  );
}

AuditConfig config({List<String> flaky = const []}) => AuditConfig(
      repo: '/dev/checkout',
      sha: 'abc',
      files: const ['lib/a.dart'],
      testCmd: 'dart test',
      outDir: '/out',
      flakyTests: flaky,
      timeout: const Duration(seconds: 90),
    );

/// The progress output of the audit loop, against a fake process runner that
/// takes fake time.
void main() {
  late Directory root;
  late File file;
  late FakeTime time;
  late List<String> lines;

  setUp(() {
    root = scratch('mutaudit_progress_run_');
    file = File(p.join(root.path, 'lib/a.dart'))..createSync(recursive: true);
    file.writeAsStringSync(source);
    time = FakeTime();
    lines = [];
  });
  tearDown(() => root.deleteSync(recursive: true));

  ProgressReporter reporter({Duration heartbeat = const Duration(seconds: 60)}) =>
      ProgressReporter(now: time.now, write: lines.add, heartbeat: heartbeat, alarm: time.alarm);

  /// Strips the timestamp: the order and the wording are under test here.
  List<String> messages() => [for (final l in lines) l.substring(l.indexOf(' ') + 1)];

  /// Every run takes [takes]; "a <= b" fails the tests.
  FakeProcessRunner byFile({Duration takes = const Duration(seconds: 10)}) => FakeProcessRunner((call) async {
        await time.advance(takes);
        if (file.readAsStringSync().contains('a <= b')) return outcomeOf(failing('lt boundary'), exitCode: 1);
        return outcomeOf(passing());
      });

  test('baseline, then per mutant a start and an end line, in order', () async {
    await AuditRunner(runner: byFile(), progress: reporter()).run(
        config: config(),
        root: root.path,
        mutants: [mutant('<', '<=', line: 1), mutant('>', '>=', line: 2)]);
    final id1 = mutant('<', '<=').id, id2 = mutant('>', '>=').id;
    expect(messages(), [
      'baseline start',
      'baseline done in 10s: 1 test passed',
      "[1/2] $id1 lib/a.dart:1 relational '<'→'<='",
      '[1/2] killed (1 killing, 0 discounted) 10s; elapsed 10s; ETA 10s',
      "[2/2] $id2 lib/a.dart:2 relational '>'→'>='",
      '[2/2] survived (0 killing, 0 discounted) 10s; elapsed 20s; ETA 0.0s',
    ]);
  });

  test('timestamps come from the injected clock', () async {
    await AuditRunner(runner: byFile(), progress: reporter()).run(config: config(), root: root.path, mutants: [mutant('>', '>=')]);
    expect(lines.first, startsWith('2026-10-09T08:00:00Z baseline start'));
    expect(lines[1], startsWith('2026-10-09T08:00:10Z baseline done'));
    expect(lines.last, startsWith('2026-10-09T08:00:20Z [1/1] survived'));
  });

  test('ETA uses the mean duration so far when the mutants take different times', () async {
    var n = 0;
    final durations = [const Duration(seconds: 10), const Duration(seconds: 10), const Duration(seconds: 50)]; // baseline, #1, #2
    final runner = FakeProcessRunner((call) async {
      await time.advance(durations[n++]);
      return outcomeOf(passing());
    });
    await AuditRunner(runner: runner, progress: reporter()).run(
        config: config(), root: root.path, mutants: [mutant('<', '<='), mutant('>', '>=')]);
    // after #1: mean 10 s, one left -> ETA 10 s
    expect(messages().where((m) => m.contains('survived')), [
      '[1/2] survived (0 killing, 0 discounted) 10s; elapsed 10s; ETA 10s',
      '[2/2] survived (0 killing, 0 discounted) 50s; elapsed 1m00s; ETA 0.0s',
    ]);
  });

  test('a rerun has its own start and end line, inside the mutant it belongs to', () async {
    final runner = FakeProcessRunner((call) async {
      await time.advance(const Duration(seconds: 5));
      if (file.readAsStringSync() == source) return outcomeOf(StreamBuilder().loaded('test/a_test.dart').pass('test/a_test.dart', 'flaky one').done());
      return outcomeOf(StreamBuilder().loaded('test/a_test.dart').fail('test/a_test.dart', 'flaky one').done(success: false), exitCode: 1);
    });
    await AuditRunner(runner: runner, progress: reporter()).run(
        config: config(flaky: ['test/a_test.dart::flaky one']), root: root.path, mutants: [mutant('<', '<=')]);
    expect(runner.calls, hasLength(3));
    expect(messages().skip(2).toList(), [
      "[1/1] ${mutant('<', '<=').id} lib/a.dart:1 relational '<'→'<='",
      '[1/1] rerun test/a_test.dart::flaky one',
      '[1/1] rerun test/a_test.dart::flaky one: exit 1 in 5.0s',
      '[1/1] killed (1 killing, 0 discounted) 10s; elapsed 10s; ETA 0.0s',
    ]);
  });

  group('heartbeat while a child runs', () {
    /// A run that streams `first`, stays up for [stays], and streams the rest.
    FakeProcessRunner streaming({
      required Duration stays,
      List<String> head = const [],
      List<String> tail = const [],
      int pid = 4242,
    }) =>
        FakeProcessRunner((call) async {
          call.observer?.onStart?.call(pid);
          head.forEach((l) => call.observer?.onStdoutLine?.call(l));
          await time.advance(stays);
          tail.forEach((l) => call.observer?.onStdoutLine?.call(l));
          return outcomeOf(passing());
        });

    test('the baseline: every interval, pid, tests done so far; the line shape of the spec', () async {
      final b = StreamBuilder().loaded('test/a_test.dart').pass('test/a_test.dart', 'g one').fail('test/a_test.dart', 'g two');
      final head = b.build();
      final runner = streaming(stays: const Duration(seconds: 130), head: head);
      await AuditRunner(runner: runner, progress: reporter()).runBaseline(config(), root.path);
      final beats = messages().where((m) => m.startsWith('…')).toList();
      expect(beats, [
        '… still running baseline for 1m00s (pid 4242): 2 tests done (1 passed, 1 failed), last: g two',
        '… still running baseline for 2m00s (pid 4242): 2 tests done (1 passed, 1 failed), last: g two',
      ]);
      expect(time.pending, 0);
    });

    test('a mutant and its rerun are labelled with their position and stop when they end', () async {
      var call = 0;
      final runner = FakeProcessRunner((c) async {
        call++;
        c.observer?.onStart?.call(1000 + call);
        await time.advance(const Duration(seconds: 70));
        if (file.readAsStringSync() == source) return outcomeOf(passing());
        // the mutant run (call 2) fails a flaky test; its rerun (call 3) fails again
        return outcomeOf(StreamBuilder().loaded('test/a_test.dart').fail('test/a_test.dart', 'flaky one').done(success: false), exitCode: 1);
      });
      await AuditRunner(runner: runner, progress: reporter()).run(
          config: config(flaky: ['test/a_test.dart::flaky one']), root: root.path, mutants: [mutant('<', '<=')]);
      final beats = messages().where((m) => m.startsWith('…')).toList();
      expect(beats, [
        '… still running baseline for 1m00s (pid 1001): 0 tests done (0 passed, 0 failed)',
        '… still running mutant [1/1] for 1m00s (pid 1002): 0 tests done (0 passed, 0 failed)',
        '… still running rerun test/a_test.dart::flaky one [1/1] for 1m00s (pid 1003): 0 tests done (0 passed, 0 failed)',
      ]);
      expect(time.pending, 0);
    });

    test('a run shorter than the interval prints no heartbeat', () async {
      await AuditRunner(runner: streaming(stays: const Duration(seconds: 59)), progress: reporter()).runBaseline(config(), root.path);
      expect(messages().where((m) => m.startsWith('…')), isEmpty);
    });

    test('heartbeat 0 disables it, however long the run', () async {
      await AuditRunner(runner: streaming(stays: const Duration(hours: 2)), progress: reporter(heartbeat: Duration.zero))
          .runBaseline(config(), root.path);
      expect(messages(), ['baseline start', 'baseline done in 2h00m00s: 1 test passed']);
    });

    test('a cancelled run stops its heartbeat too', () async {
      final token = CancelToken();
      final runner = FakeProcessRunner((c) async {
        if (file.readAsStringSync() == source) return outcomeOf(passing());
        await time.advance(const Duration(seconds: 61));
        token.cancel();
        return outcomeOf(StreamBuilder().loaded('test/a_test.dart'), exitCode: -15, cancelled: true);
      });
      await expectLater(
          AuditRunner(runner: runner, progress: reporter()).run(config: config(), root: root.path, mutants: [mutant('<', '<=')], cancel: token),
          throwsA(isA<InterruptedError>()));
      expect(time.pending, 0);
      expect(messages().where((m) => m.startsWith('…')), hasLength(1));
    });
  });

  test('without a reporter nothing is printed and the audit behaves as before', () async {
    final runner = byFile();
    final run = await AuditRunner(runner: runner).run(config: config(), root: root.path, mutants: [mutant('<', '<=')]);
    expect(run.results.single.classification.status, MutantStatus.killed);
    expect(lines, isEmpty);
  });
}
