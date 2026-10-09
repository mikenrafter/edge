import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/fakes.dart';
import 'support/git_fixture.dart';

const source = 'bool lt(int a, int b) { return a < b; }\nbool gt(int a, int b) { return a > b; }\n';

Mutant mutant(String original, String mutated, {int occurrence = 0}) {
  var at = -1;
  for (var i = 0; i <= occurrence; i++) {
    at = source.indexOf(original, at + 1);
  }
  return Mutant(
    id: 'lib/a.dart:$at:relational:${mutated.hashCode.toRadixString(16)}',
    file: 'lib/a.dart',
    line: 1,
    column: at + 1,
    byteOffset: at,
    byteLength: original.length,
    operator: MutationOperator.relational,
    original: original,
    mutated: mutated,
  );
}

AuditConfig config({
  List<String> tests = const [],
  List<String> flaky = const [],
  List<String> guards = const [],
  Duration timeout = const Duration(seconds: 90),
  String testCmd = 'dart test',
}) =>
    AuditConfig(
      repo: '/dev/checkout',
      sha: 'abc',
      files: const ['lib/a.dart'],
      testCmd: testCmd,
      outDir: '/out',
      tests: tests,
      flakyTests: flaky,
      guardPatterns: guards,
      timeout: timeout,
    );

void main() {
  late Directory root;
  late File file;

  setUp(() {
    root = scratch('mutaudit_run_');
    file = File(p.join(root.path, 'lib/a.dart'))..createSync(recursive: true);
    file.writeAsStringSync(source);
  });
  tearDown(() => root.deleteSync(recursive: true));

  String current() => file.readAsStringSync();

  /// Fails when a "<=" mutant is applied, passes otherwise (baseline included).
  FakeProcessRunner byFile({String killer = 'a <= b'}) => FakeProcessRunner((call) {
        final s = current();
        if (s.contains(killer)) return outcomeOf(failing('lt boundary'), exitCode: 1);
        return outcomeOf(passing());
      });

  group('baseline', () {
    test('runs once on the untouched tree and reports the tests it ran', () async {
      final runner = byFile();
      final baseline = await AuditRunner(runner: runner).runBaseline(config(), root.path);
      expect(baseline.passed, isTrue);
      expect(baseline.testsRun, 1);
      expect(runner.calls, hasLength(1));
      expect(runner.calls.single.cwd, root.path);
      expect(current(), source);
    });

    test('a failing baseline aborts the audit before any mutant is written', () async {
      var mutatedSeen = false;
      final runner = FakeProcessRunner((call) {
        if (current() != source) mutatedSeen = true;
        return outcomeOf(failing('already broken'), exitCode: 1);
      });
      await expectLater(
          AuditRunner(runner: runner).run(config: config(), root: root.path, mutants: [mutant('<', '<=')]),
          throwsA(isA<BaselineFailedError>().having((e) => e.message, 'message', contains('already broken'))));
      expect(mutatedSeen, isFalse);
      expect(runner.calls, hasLength(1));
      expect(current(), source);
    });

    test('a baseline that does not load fails, and names the load error', () async {
      final runner = FakeProcessRunner((call) => outcomeOf(
          StreamBuilder().loadError('test/a_test.dart', 'Failed to load "test/a_test.dart": Bad state: x').done(success: false),
          exitCode: 1));
      await expectLater(AuditRunner(runner: runner).runBaseline(config(), root.path),
          throwsA(isA<BaselineFailedError>().having((e) => e.message, 'message', contains('Bad state: x'))));
    });

    test('a baseline whose setUpAll fails is not a baseline', () async {
      final runner = FakeProcessRunner((call) => outcomeOf(
          StreamBuilder().loaded('test/a_test.dart').pass('test/a_test.dart', 'ok').throws('test/a_test.dart', 'g (setUpAll)', 'Bad state: nope').done(success: false),
          exitCode: 1));
      await expectLater(AuditRunner(runner: runner).runBaseline(config(), root.path),
          throwsA(isA<BaselineFailedError>().having((e) => e.message, 'message', contains('g (setUpAll)'))));
    });

    test('a baseline that ran no test is not a baseline', () async {
      final runner = FakeProcessRunner((call) => outcomeOf(StreamBuilder().done()));
      await expectLater(AuditRunner(runner: runner).runBaseline(config(), root.path), throwsA(isA<BaselineFailedError>()));
    });

    test('a baseline that times out fails', () async {
      final runner = FakeProcessRunner((call) => outcomeOf(passing(), timedOut: true, exitCode: -9));
      await expectLater(AuditRunner(runner: runner).runBaseline(config(), root.path), throwsA(isA<BaselineFailedError>()));
    });
  });

  group('mutants', () {
    test('one at a time, each seen by the tests, file restored after each', () async {
      final seen = <String>[];
      final runner = FakeProcessRunner((call) {
        seen.add(current());
        return current().contains('a <= b') ? outcomeOf(failing('lt boundary'), exitCode: 1) : outcomeOf(passing());
      });
      final run = await AuditRunner(runner: runner)
          .run(config: config(), root: root.path, mutants: [mutant('<', '<='), mutant('>', '>=')]);
      expect(runner.maxInFlight, 1);
      expect(seen, hasLength(3));
      expect(seen[0], source, reason: 'the baseline sees the original');
      expect(seen[1], source.replaceFirst('a < b', 'a <= b'));
      expect(seen[2], source.replaceFirst('a > b', 'a >= b'));
      expect(current(), source);
      expect(run.baseline.passed, isTrue);
      expect(run.results.map((r) => r.classification.status), [MutantStatus.killed, MutantStatus.survived]);
      expect(run.results.first.classification.killingTests, ['test/a_test.dart::lt boundary']);
    });

    test('results are in the order of the mutants, with their durations', () async {
      final runner = FakeProcessRunner((call) => outcomeOf(passing(), elapsed: const Duration(milliseconds: 250)));
      final ms = [mutant('>', '>='), mutant('<', '<=')];
      final run = await AuditRunner(runner: runner).run(config: config(), root: root.path, mutants: ms);
      expect(run.results.map((r) => r.mutant.id), ms.map((m) => m.id));
      expect(run.results.map((r) => r.duration), everyElement(const Duration(milliseconds: 250)));
    });

    test('the timeout is passed to every run, and a timed-out mutant is a timeout', () async {
      final runner = FakeProcessRunner((call) {
        if (current().contains('a <= b')) {
          return outcomeOf(StreamBuilder().unfinished('test/a_test.dart', 'loops'), exitCode: -9, timedOut: true);
        }
        return outcomeOf(passing());
      });
      final run = await AuditRunner(runner: runner).run(
          config: config(timeout: const Duration(seconds: 7)), root: root.path, mutants: [mutant('<', '<=')]);
      expect(runner.calls.map((c) => c.timeout), everyElement(const Duration(seconds: 7)));
      expect(run.results.single.classification.status, MutantStatus.timeout);
      expect(current(), source);
    });

    test('the command is the configured one with the reporter, the test subset and the root as cwd', () async {
      final runner = byFile();
      await AuditRunner(runner: runner).run(
          config: config(tests: ['test/a_test.dart'], testCmd: 'flutter test'),
          root: root.path,
          mutants: [mutant('<', '<=')]);
      for (final call in runner.calls) {
        expect(call.argv, ['flutter', 'test', '--reporter', 'json', 'test/a_test.dart']);
        expect(call.cwd, root.path);
      }
    });

    test('a compile-invalid mutant is told apart from a kill', () async {
      final runner = FakeProcessRunner((call) => current().contains('a <= b')
          ? outcomeOf(
              StreamBuilder().loadError('test/a_test.dart', 'Failed to load "test/a_test.dart":\nlib/a.dart:1:9: Error: nope').done(success: false),
              exitCode: 1)
          : outcomeOf(passing()));
      final run = await AuditRunner(runner: runner).run(config: config(), root: root.path, mutants: [mutant('<', '<=')]);
      expect(run.results.single.classification.status, MutantStatus.compileInvalid);
    });

    test('a runner that throws still leaves the file restored, and the error propagates', () async {
      var n = 0;
      final runner = FakeProcessRunner((call) {
        if (n++ == 0) return outcomeOf(passing());
        throw const FileSystemException('spawn failed');
      });
      await expectLater(
          AuditRunner(runner: runner).run(config: config(), root: root.path, mutants: [mutant('<', '<=')]),
          throwsA(isA<FileSystemException>()));
      expect(current(), source);
    });

    test('a mutant that does not fit the file stops the audit, file untouched', () async {
      final runner = byFile();
      final stale = mutant('<', '<=');
      file.writeAsStringSync('// shifted\n$source');
      final before = file.readAsBytesSync();
      await expectLater(
          AuditRunner(runner: runner).run(config: config(), root: root.path, mutants: [stale]),
          throwsA(isA<StaleMutantError>()));
      expect(file.readAsBytesSync(), before);
    });

    test('no mutants: only the baseline runs', () async {
      final runner = byFile();
      final run = await AuditRunner(runner: runner).run(config: config(), root: root.path, mutants: const []);
      expect(run.results, isEmpty);
      expect(runner.calls, hasLength(1));
    });
  });

  group('environment', () {
    test('every child process gets TZ=UTC by default and the configured env otherwise', () async {
      final runner = byFile();
      await AuditRunner(runner: runner).run(config: config(), root: root.path, mutants: [mutant('<', '<=')]);
      expect(runner.calls.map((c) => c.environment), everyElement({'TZ': 'UTC'}));
      final other = byFile();
      await AuditRunner(runner: other).run(
          config: AuditConfig(
              repo: '/r', sha: 's', files: const ['lib/a.dart'], testCmd: 'dart test', outDir: '/o',
              env: const {'TZ': 'Asia/Tokyo', 'A': 'b'}),
          root: root.path,
          mutants: [mutant('<', '<=')]);
      expect(other.calls.map((c) => c.environment), everyElement({'TZ': 'Asia/Tokyo', 'A': 'b'}));
    });
  });

  group('ambiguous failures', () {
    test('a flaky test failing under a mutant is re-run alone, mutant still applied', () async {
      final calls = <(List<String>, String)>[];
      final runner = FakeProcessRunner((call) {
        calls.add((call.argv, current()));
        final mutated = current() != source;
        final alone = call.argv.contains('--plain-name');
        if (mutated && !alone) {
          return outcomeOf(StreamBuilder().loaded('test/a_test.dart').fail('test/a_test.dart', 'flaky one').done(success: false), exitCode: 1);
        }
        return outcomeOf(StreamBuilder().loaded('test/a_test.dart').pass('test/a_test.dart', 'flaky one').done());
      });
      final run = await AuditRunner(runner: runner).run(
          config: config(flaky: ['test/a_test.dart::flaky one'], tests: ['test/a_test.dart']),
          root: root.path,
          mutants: [mutant('<', '<=')]);
      expect(calls, hasLength(3), reason: 'baseline, mutant run, one rerun');
      final (argv, content) = calls.last;
      expect(argv, containsAllInOrder(['test/a_test.dart', '--plain-name', 'flaky one']));
      expect(content, isNot(source), reason: 'the rerun happens with the mutant applied');
      final c = run.results.single.classification;
      expect(c.status, MutantStatus.survived);
      expect(c.reruns.single.confirmed, isFalse);
      expect(current(), source);
    });

    test('a failure that repeats alone is a kill', () async {
      final runner = FakeProcessRunner((call) {
        if (current() != source) {
          return outcomeOf(StreamBuilder().loaded('test/a_test.dart').fail('test/a_test.dart', 'flaky one').done(success: false), exitCode: 1);
        }
        return outcomeOf(StreamBuilder().loaded('test/a_test.dart').pass('test/a_test.dart', 'flaky one').done());
      });
      final run = await AuditRunner(runner: runner).run(
          config: config(flaky: ['test/a_test.dart::flaky one']), root: root.path, mutants: [mutant('<', '<=')]);
      expect(run.results.single.classification.status, MutantStatus.killed);
      expect(run.results.single.classification.reruns.single.confirmed, isTrue);
    });
  });

  group('test keys do not depend on where the export is', () {
    test('absolute suite paths from the runner become root-relative keys', () async {
      final abs = '${root.path}/test/a_test.dart';
      final runner = FakeProcessRunner((call) => current().contains('a <= b')
          ? outcomeOf(StreamBuilder().loaded(abs).fail(abs, 'lt boundary').done(success: false), exitCode: 1)
          : outcomeOf(StreamBuilder().loaded(abs).pass(abs, 'lt boundary').done()));
      final run = await AuditRunner(runner: runner).run(config: config(), root: root.path, mutants: [mutant('<', '<=')]);
      expect(run.results.single.classification.killingTests, ['test/a_test.dart::lt boundary']);
    });
  });

  group('guards', () {
    test('only guard tests failing is killed-by-guard-only', () async {
      final runner = FakeProcessRunner((call) => current() != source
          ? outcomeOf(
              StreamBuilder().loaded('x').pass('test/a_test.dart', 'ok').fail('test/guards/g_test.dart', 'no heavy calc').done(success: false),
              exitCode: 1)
          : outcomeOf(passing()));
      final run = await AuditRunner(runner: runner)
          .run(config: config(guards: ['test/guards/**']), root: root.path, mutants: [mutant('<', '<=')]);
      expect(run.results.single.classification.status, MutantStatus.killedByGuardOnly);
    });
  });

}
