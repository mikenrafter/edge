import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/git_fixture.dart';

const suite = 'test/a_test.dart';

Future<Classification> classify(
  StreamBuilder s, {
  int exitCode = 0,
  bool timedOut = false,
  String stderr = '',
  GuardMatcher? guards,
  Set<String> flaky = const {},
  SingleTestRunner? rerun,
}) =>
    classifyRun(outcomeOf(s, exitCode: exitCode, timedOut: timedOut, stderr: stderr),
        guards: guards, flakyTests: flaky, rerun: rerun);

/// What running [t] alone looks like when it passes.
ProcessOutcome passesAlone(TestOutcome t) =>
    outcomeOf(StreamBuilder().loaded(t.suite).pass(t.suite, t.name).done());

/// ... when it fails by assertion again.
ProcessOutcome failsAgain(TestOutcome t) =>
    outcomeOf(StreamBuilder().loaded(t.suite).fail(t.suite, t.name).done(success: false), exitCode: 1);

void main() {
  group('survived, killed, skipped', () {
    test('every test passed: survived', () async {
      final c = await classify(passing());
      expect(c.status, MutantStatus.survived);
      expect(c.killingTests, isEmpty);
    });

    test('an assertion failure kills, and the test is named', () async {
      final c = await classify(failing('g fails'), exitCode: 1);
      expect(c.status, MutantStatus.killed);
      expect(c.killingTests, ['$suite::g fails']);
      expect(c.guardTests, isEmpty);
    });

    test('an exception in a test kills too', () async {
      final s = StreamBuilder().loaded(suite).pass(suite, 'a').throws(suite, 'b', 'RangeError: bad').done(success: false);
      final c = await classify(s, exitCode: 1);
      expect(c.status, MutantStatus.killed);
      expect(c.killingTests, ['$suite::b']);
    });

    test('the kind of each killer is recorded: assertion for a TestFailure, exception otherwise', () async {
      final s = StreamBuilder()
          .loaded(suite)
          .fail(suite, 'asserts')
          .throws(suite, 'crashes', 'RangeError: bad')
          .done(success: false);
      final c = await classify(s, exitCode: 1);
      expect([for (final k in c.killers) (k.key, k.kind)], [
        ('$suite::asserts', FailureKind.assertion),
        ('$suite::crashes', FailureKind.exception),
      ]);
      expect(c.killingTests, ['$suite::asserts', '$suite::crashes']);
    });

    test('every failing test is listed, in the order they finished', () async {
      final s = StreamBuilder()
          .loaded(suite)
          .fail(suite, 'z')
          .pass(suite, 'ok')
          .fail('test/b_test.dart', 'a')
          .done(success: false);
      final c = await classify(s, exitCode: 1);
      expect(c.killingTests, ['$suite::z', 'test/b_test.dart::a']);
    });

    test('a run in which every test was skipped is skipped, not survived', () async {
      final s = StreamBuilder().loaded(suite).test(suite, 'a', skipped: true).test(suite, 'b', skipped: true).done();
      expect((await classify(s)).status, MutantStatus.skipped);
    });

    test('a clean run with no tests at all is skipped', () async {
      expect((await classify(StreamBuilder().done())).status, MutantStatus.skipped);
    });

    test('skipped tests next to passing ones do not stop a survival', () async {
      final s = StreamBuilder().loaded(suite).test(suite, 'a', skipped: true).pass(suite, 'b').done();
      expect((await classify(s)).status, MutantStatus.survived);
    });
  });

  group('timeouts, compile errors, load failures', () {
    test('a timeout is a timeout, whatever the partial stream says', () async {
      final s = StreamBuilder().loaded(suite).fail(suite, 'x').unfinished(suite, 'hang');
      final c = await classify(s, exitCode: -9, timedOut: true);
      expect(c.status, MutantStatus.timeout);
      expect(c.killingTests, isEmpty);
    });

    test('a compile error is compile-invalid, with the diagnostic as detail', () async {
      final lines = File('test/fixtures/real_compile_error.jsonl').readAsLinesSync();
      final c = await classifyRun(ProcessOutcome(exitCode: 1, stdoutLines: lines));
      expect(c.status, MutantStatus.compileInvalid);
      expect(c.detail, contains("A value of type 'String' can't be assigned"));
      expect(c.killingTests, isEmpty);
    });

    test('Compilation failed counts as a compile error', () async {
      final s = StreamBuilder().loadError(suite, 'Failed to load "$suite": Compilation failed').done(success: false);
      expect((await classify(s, exitCode: 1)).status, MutantStatus.compileInvalid);
    });

    test('a compile error anywhere outweighs failures elsewhere', () async {
      final s = StreamBuilder()
          .loaded(suite)
          .fail(suite, 'x')
          .loadError('test/b_test.dart', 'Failed to load "test/b_test.dart":\ntest/b_test.dart:2:9: Error: nope')
          .done(success: false);
      final c = await classify(s, exitCode: 1);
      expect(c.status, MutantStatus.compileInvalid);
      expect(c.killingTests, isEmpty);
    });

    test('an exception at load time is a load failure', () async {
      final lines = File('test/fixtures/real_load_exception.jsonl').readAsLinesSync();
      final c = await classifyRun(ProcessOutcome(exitCode: 1, stdoutLines: lines));
      expect(c.status, MutantStatus.loadFailure);
      expect(c.detail, contains('Bad state: load time'));
    });

    test('a missing test file is a load failure', () async {
      final lines = File('test/fixtures/real_missing_file.jsonl').readAsLinesSync();
      expect((await classifyRun(ProcessOutcome(exitCode: 1, stdoutLines: lines))).status, MutantStatus.loadFailure);
    });

    test('a failing test in another suite still kills when one suite failed to load', () async {
      final s = StreamBuilder()
          .loaded(suite)
          .fail(suite, 'x')
          .loadError('test/c_test.dart', 'Failed to load "test/c_test.dart": Bad state: load time')
          .done(success: false);
      final c = await classify(s, exitCode: 1);
      expect(c.status, MutantStatus.killed);
      expect(c.killingTests, ['$suite::x']);
    });

    test('no output at all is a load failure; stderr is the detail', () async {
      final c = await classifyRun(const ProcessOutcome(exitCode: 127, stderr: 'flutter: command not found'));
      expect(c.status, MutantStatus.loadFailure);
      expect(c.detail, contains('command not found'));
    });

    test('tests ran but there is no done event: load failure', () async {
      final s = StreamBuilder().loaded(suite).pass(suite, 'a');
      expect((await classify(s)).status, MutantStatus.loadFailure);
    });

    test('exit code non-zero with nothing failing in the stream: load failure', () async {
      expect((await classify(passing(), exitCode: 1)).status, MutantStatus.loadFailure);
    });
  });

  group('guard tests are not runtime coverage', () {
    final guards = GuardMatcher(['test/guards/**', '*_guard_test.dart']);
    const guardSuite = 'test/guards/heavy_guard_test.dart';

    test('only a guard test failing: killed-by-guard-only', () async {
      final s = StreamBuilder().loaded(suite).pass(suite, 'ok').fail(guardSuite, 'no heavy calc').done(success: false);
      final c = await classify(s, exitCode: 1, guards: guards);
      expect(c.status, MutantStatus.killedByGuardOnly);
      expect(c.killingTests, isEmpty);
      expect(c.guardTests, ['$guardSuite::no heavy calc']);
    });

    test('a guard and a runtime test failing: killed by the runtime test alone', () async {
      final s = StreamBuilder().loaded(suite).fail(guardSuite, 'g').fail(suite, 'real').done(success: false);
      final c = await classify(s, exitCode: 1, guards: guards);
      expect(c.status, MutantStatus.killed);
      expect(c.killingTests, ['$suite::real']);
      expect(c.guardTests, ['$guardSuite::g']);
    });

    test('without a matcher nothing is a guard', () async {
      final s = StreamBuilder().loaded(suite).fail(guardSuite, 'g').done(success: false);
      expect((await classify(s, exitCode: 1)).status, MutantStatus.killed);
    });

    test('guard tests that pass change nothing', () async {
      final s = StreamBuilder().loaded(suite).pass(guardSuite, 'g').pass(suite, 'ok').done();
      expect((await classify(s, guards: guards)).status, MutantStatus.survived);
    });

    group('GuardMatcher', () {
      TestOutcome at(String suitePath) =>
          TestOutcome(suite: suitePath, name: 'n', result: TestResult.failure, skipped: false);

      test('a directory glob matches under it, also behind an absolute prefix', () {
        final m = GuardMatcher(['test/guards/**']);
        expect(m.matches(at('test/guards/a_test.dart')), isTrue);
        expect(m.matches(at('test/guards/deep/b_test.dart')), isTrue);
        expect(m.matches(at('/tmp/export/test/guards/a_test.dart')), isTrue);
        expect(m.matches(at('test/other/a_test.dart')), isFalse);
        expect(m.matches(at('test/guards_not/a_test.dart')), isFalse);
      });

      test('a pattern without a slash matches the file name anywhere', () {
        final m = GuardMatcher(['*_guard_test.dart']);
        expect(m.matches(at('test/x/y_guard_test.dart')), isTrue);
        expect(m.matches(at('y_guard_test.dart')), isTrue);
        expect(m.matches(at('test/x/y_test.dart')), isFalse);
      });

      test('no patterns match nothing', () {
        expect(GuardMatcher(const []).matches(at('test/guards/a_test.dart')), isFalse);
      });
    });
  });

  group('ambiguous failures are re-run alone once', () {
    Future<Classification> flaky(
      SingleTestRunner rerun, {
      Set<String> also = const {},
      StreamBuilder? first,
      GuardMatcher? guards,
    }) =>
        classify(
            first ?? StreamBuilder().loaded(suite).pass(suite, 'ok').fail(suite, 'flaky').done(success: false),
            exitCode: 1,
            flaky: {'$suite::flaky', ...also},
            guards: guards,
            rerun: rerun);

    test('a known-flaky test that passes alone is dropped, and the rerun is recorded', () async {
      final reruns = <String>[];
      final c = await flaky((t) async {
        reruns.add(t.key);
        return passesAlone(t);
      });
      expect(reruns, ['$suite::flaky']);
      expect(c.status, MutantStatus.survived);
      expect(c.killingTests, isEmpty);
      expect(c.reruns.single.testKey, '$suite::flaky');
      expect(c.reruns.single.result, RerunResult.passedAlone);
      expect(c.reruns.single.confirmed, isFalse);
    });

    test('a known-flaky test that fails alone again, with an error, is a real failure', () async {
      final c = await classify(StreamBuilder().loaded(suite).fail(suite, 'flaky').done(success: false),
          exitCode: 1, flaky: {'$suite::flaky'}, rerun: (t) async => failsAgain(t));
      expect(c.status, MutantStatus.killed);
      expect(c.killingTests, ['$suite::flaky']);
      expect(c.reruns.single.result, RerunResult.failedAgain);
      expect(c.reruns.single.confirmed, isTrue);
    });

    test('a failure with no error event cannot be attributed: it is re-run', () async {
      final reruns = <String>[];
      final s = StreamBuilder()
          .loaded(suite)
          .test(suite, 'mystery', result: TestResult.failure)
          .done(success: false);
      final c = await classify(s, exitCode: 1, rerun: (t) async {
        reruns.add(t.key);
        return passesAlone(t);
      });
      expect(reruns, ['$suite::mystery']);
      expect(c.status, MutantStatus.survived);
    });

    test('the kind of the confirming rerun is carried next to the original kind', () async {
      // Crashed in the mutant run, failed an assertion when run alone.
      final s = StreamBuilder().loaded(suite).throws(suite, 'flaky', 'Bad state: x').done(success: false);
      final c = await classify(s,
          exitCode: 1, flaky: {'$suite::flaky'}, rerun: (t) async => failsAgain(t));
      expect(c.status, MutantStatus.killed);
      expect(c.killers.single.kind, FailureKind.exception, reason: 'the original kind is kept');
      expect(c.killers.single.confirmedKind, FailureKind.assertion);
      expect(c.reruns.single.kind, FailureKind.assertion);
      // And the other way round.
      final s2 = StreamBuilder().loaded(suite).fail(suite, 'flaky').done(success: false);
      final c2 = await classify(s2, exitCode: 1, flaky: {'$suite::flaky'}, rerun: (t) async => outcomeOf(
          StreamBuilder().loaded(suite).throws(suite, 'flaky').done(success: false), exitCode: 1));
      expect(c2.killers.single.kind, FailureKind.assertion);
      expect(c2.killers.single.confirmedKind, FailureKind.exception);
    });

    test('a kill that needed no rerun has no confirmed kind', () async {
      final c = await classify(failing('g fails'), exitCode: 1);
      expect(c.killers.single.confirmedKind, isNull);
    });

    test('a mystery failure that fails again WITH an error is confirmed; without one it is not', () async {
      final s = StreamBuilder().loaded(suite).test(suite, 'mystery', result: TestResult.failure).done(success: false);
      final confirmed = await classify(s, exitCode: 1, rerun: (t) async => failsAgain(t));
      expect(confirmed.status, MutantStatus.killed);
      final still = await classify(s,
          exitCode: 1,
          rerun: (t) async => outcomeOf(
              StreamBuilder().loaded(suite).test(suite, 'mystery', result: TestResult.failure).done(success: false),
              exitCode: 1));
      expect(still.status, MutantStatus.unconfirmed);
      expect(still.killingTests, isEmpty);
    });

    test('attributable failures that are not flaky are not re-run', () async {
      var calls = 0;
      final c = await classify(failing('g fails'), exitCode: 1, rerun: (t) async {
        calls++;
        return failsAgain(t);
      });
      expect(calls, 0);
      expect(c.status, MutantStatus.killed);
      expect(c.reruns, isEmpty);
    });

    test('each ambiguous test is re-run once, however many fail', () async {
      final counts = <String, int>{};
      final s = StreamBuilder()
          .loaded(suite)
          .fail(suite, 'a')
          .fail(suite, 'b')
          .fail(suite, 'c')
          .done(success: false);
      await classify(s, exitCode: 1, flaky: {'$suite::a', '$suite::b'}, rerun: (t) async {
        counts[t.key] = (counts[t.key] ?? 0) + 1;
        return failsAgain(t);
      });
      expect(counts, {'$suite::a': 1, '$suite::b': 1});
    });

    group('a rerun that did not show the test fail again never confirms a kill', () {
      Future<void> unconfirmed(String why, ProcessOutcome rerun, {String? detailHas}) async {
        final c = await flaky((t) async => rerun);
        expect(c.status, MutantStatus.unconfirmed, reason: why);
        expect(c.killingTests, isEmpty, reason: why);
        expect(c.guardTests, isEmpty, reason: why);
        expect(c.reruns.single.result, RerunResult.unresolved, reason: why);
        expect(c.reruns.single.confirmed, isFalse, reason: why);
        expect(c.reruns.single.detail, isNotEmpty, reason: why);
        if (detailHas != null) expect(c.reruns.single.detail, contains(detailHas), reason: why);
        expect(c.detail, contains('$suite::flaky'), reason: why);
      }

      test('the rerun printed nothing (the test never ran)', () => unconfirmed('empty', const ProcessOutcome(exitCode: 0)));

      test('the rerun ran other tests but not this one', () => unconfirmed(
          'absent', outcomeOf(StreamBuilder().loaded(suite).pass(suite, 'other').done()), detailHas: 'did not run'));

      test('the rerun timed out, even though the stream shows the test failing', () => unconfirmed(
          'timeout',
          outcomeOf(StreamBuilder().loaded(suite).fail(suite, 'flaky').unfinished(suite, 'x'), exitCode: -9, timedOut: true),
          detailHas: 'timed out'));

      test('the rerun was cancelled', () => unconfirmed(
          'cancelled', outcomeOf(StreamBuilder().loaded(suite).fail(suite, 'flaky'), exitCode: -15, cancelled: true)));

      test('the rerun did not compile', () => unconfirmed(
          'compile',
          outcomeOf(
              StreamBuilder().loadError(suite, 'Failed to load "$suite":\nlib/a.dart:1:9: Error: nope').done(success: false),
              exitCode: 1),
          detailHas: 'compile'));

      test('the suite did not load in the rerun', () => unconfirmed(
          'load', outcomeOf(StreamBuilder().loadError(suite, 'Bad state: load time').done(success: false), exitCode: 1),
          detailHas: 'load'));

      test('a setUpAll failed in the rerun', () => unconfirmed(
          'hook',
          outcomeOf(StreamBuilder().loaded(suite).throws(suite, '(setUpAll)').done(success: false), exitCode: 1),
          detailHas: 'setUpAll'));

      test('the rerun passed but its reporter stream is incomplete (no done event)', () => unconfirmed(
          'no done', outcomeOf(StreamBuilder().loaded(suite).pass(suite, 'flaky')), detailHas: 'incomplete'));

      test('the rerun passed but the process did not finish reading its output', () => unconfirmed(
          'output', outcomeOf(passingWith('flaky'), outputComplete: false), detailHas: 'incomplete'));

      test('the test was skipped in the rerun', () => unconfirmed(
          'skipped', outcomeOf(StreamBuilder().loaded(suite).test(suite, 'flaky', skipped: true).done())));

      test('the test failed again but with no error event', () => unconfirmed(
          'mystery again',
          outcomeOf(StreamBuilder().loaded(suite).test(suite, 'flaky', result: TestResult.failure).done(success: false),
              exitCode: 1)));
    });

    test('an unresolved rerun beside a confirmed kill: the confirmed kill stands', () async {
      final s = StreamBuilder().loaded(suite).fail(suite, 'flaky').fail(suite, 'solid').done(success: false);
      final c = await classify(s, exitCode: 1, flaky: {'$suite::flaky'}, rerun: (t) async => const ProcessOutcome(exitCode: 0));
      expect(c.status, MutantStatus.killed);
      expect(c.killingTests, ['$suite::solid']);
      expect(c.reruns.single.result, RerunResult.unresolved);
    });

    test('an unresolved rerun beside a confirmed guard failure is unconfirmed, not guard-only', () async {
      final s = StreamBuilder().loaded(suite).fail(suite, 'flaky').fail('test/guards/g_test.dart', 'g').done(success: false);
      final c = await classify(s,
          exitCode: 1,
          guards: GuardMatcher(['test/guards/**']),
          flaky: {'$suite::flaky'},
          rerun: (t) async => const ProcessOutcome(exitCode: 0));
      expect(c.status, MutantStatus.unconfirmed);
      expect(c.guardTests, ['test/guards/g_test.dart::g']);
    });

    test('an unresolved rerun is not a survivor either, whatever else passed', () async {
      final c = await flaky((t) async => const ProcessOutcome(exitCode: 0));
      expect(c.status, MutantStatus.unconfirmed);
    });

    test('without a rerun function an ambiguous failure is unconfirmed, not a kill', () async {
      final s = StreamBuilder().loaded(suite).fail(suite, 'flaky').done(success: false);
      final c = await classify(s, exitCode: 1, flaky: {'$suite::flaky'});
      expect(c.status, MutantStatus.unconfirmed);
      expect(c.killingTests, isEmpty);
      expect(c.reruns.single.result, RerunResult.unresolved);
      expect(c.reruns.single.detail, contains('no rerun'));
    });

    test('a guard failure that turns out flaky is dropped like any other', () async {
      final s = StreamBuilder().loaded(suite).fail('test/guards/x_guard_test.dart', 'g').done(success: false);
      final c = await classify(s,
          exitCode: 1,
          guards: GuardMatcher(['test/guards/**']),
          flaky: {'test/guards/x_guard_test.dart::g'},
          rerun: (t) async => passesAlone(t));
      expect(c.status, MutantStatus.survived);
    });
  });

  group('source-scanning suites never produce kills', () {
    late Directory repo;
    setUp(() {
      repo = scratch('mutaudit_cls_');
      for (final e in {
        'lib/a.dart': 'int a = 1;\n',
        'test/scan_test.dart': "import 'dart:io';\nvoid main() { File('lib/a.dart').readAsStringSync(); }\n",
        'test/runtime_test.dart': "import 'package:test/test.dart';\nvoid main() {}\n",
      }.entries) {
        File('${repo.path}/${e.key}')
          ..createSync(recursive: true)
          ..writeAsStringSync(e.value);
      }
    });
    tearDown(() => repo.deleteSync(recursive: true));

    GuardMatcher guards({String allowlist = ''}) => GuardMatcher(const [],
        detector: SourceScanDetector(root: repo.path), allowlist: RuntimeAllowlist.parse(allowlist));

    test('a failure in a suite that reads lib/ is guard-only, with the reason recorded', () async {
      final s = StreamBuilder().loaded('test/scan_test.dart').fail('test/scan_test.dart', 'wiring').done(success: false);
      final c = await classify(s, exitCode: 1, guards: guards());
      expect(c.status, MutantStatus.killedByGuardOnly);
      expect(c.killingTests, isEmpty);
      expect(c.guardTests, ['test/scan_test.dart::wiring']);
      expect(c.discounted.single.reasons.join(' '), contains('may read source: test/scan_test.dart:'));
    });

    test('the same failure counts once the reviewed allowlist says the test runs code', () async {
      final s = StreamBuilder().loaded('test/scan_test.dart').fail('test/scan_test.dart', 'wiring').done(success: false);
      final c = await classify(s, exitCode: 1, guards: guards(allowlist: 'test/scan_test.dart::wiring'));
      expect(c.status, MutantStatus.killed);
      expect(c.killingTests, ['test/scan_test.dart::wiring']);
      expect(c.discounted, isEmpty);
    });

    test('a per-test entry frees only that test: its sibling stays discounted', () async {
      final s = StreamBuilder()
          .loaded('test/scan_test.dart')
          .fail('test/scan_test.dart', 'wiring')
          .fail('test/scan_test.dart', 'behaviour')
          .done(success: false);
      final c = await classify(s, exitCode: 1, guards: guards(allowlist: 'test/scan_test.dart::behaviour'));
      expect(c.status, MutantStatus.killed);
      expect(c.killingTests, ['test/scan_test.dart::behaviour']);
      expect(c.guardTests, ['test/scan_test.dart::wiring']);
    });

    test('runtime and scanning failures together: the runtime one kills, the scanning one is listed as discounted', () async {
      final s = StreamBuilder()
          .loaded('x')
          .fail('test/scan_test.dart', 'wiring')
          .fail('test/runtime_test.dart', 'real')
          .done(success: false);
      final c = await classify(s, exitCode: 1, guards: guards());
      expect(c.status, MutantStatus.killed);
      expect(c.killingTests, ['test/runtime_test.dart::real']);
      expect(c.guardTests, ['test/scan_test.dart::wiring']);
    });

    test('a suite that is not in the export is discounted too: it cannot be checked', () async {
      final s = StreamBuilder().loaded('x').fail('test/ghost_test.dart', 'who knows').done(success: false);
      final c = await classify(s, exitCode: 1, guards: guards());
      expect(c.status, MutantStatus.killedByGuardOnly);
      expect(c.discounted.single.reasons.single, contains('cannot be checked'));
    });

    test('absolute suite paths from the reporter are checked after being made relative', () async {
      final abs = '${repo.path}/test/scan_test.dart';
      final s = StreamBuilder().loaded(abs).fail(abs, 'wiring').done(success: false);
      final c = await classifyRun(outcomeOf(s, exitCode: 1), guards: guards(), root: repo.path);
      expect(c.status, MutantStatus.killedByGuardOnly);
    });
  });

  group('setUpAll / tearDownAll failures are never kills', () {
    test('a failing setUpAll is a load failure even though other tests passed', () async {
      final s = StreamBuilder()
          .loaded(suite)
          .pass(suite, 'ok')
          .throws(suite, 'g (setUpAll)', 'Bad state: boom setup')
          .done(success: false);
      final c = await classify(s, exitCode: 1);
      expect(c.status, MutantStatus.loadFailure);
      expect(c.killingTests, isEmpty);
      expect(c.detail, contains('g (setUpAll)'));
      expect(c.detail, contains('boom setup'));
    });

    test('a failing tearDownAll is a load failure, not a kill and not a survivor', () async {
      final s = StreamBuilder()
          .loaded(suite)
          .pass(suite, 'ok')
          .throws(suite, 'h (tearDownAll)', 'Bad state: boom td')
          .done(success: false);
      final c = await classify(s, exitCode: 1);
      expect(c.status, MutantStatus.loadFailure);
    });

    test('a real failing test next to it still kills, and the hook is not listed as a killer', () async {
      final s = StreamBuilder()
          .loaded(suite)
          .throws(suite, '(setUpAll)', 'Bad state: x')
          .fail(suite, 'real')
          .done(success: false);
      final c = await classify(s, exitCode: 1);
      expect(c.status, MutantStatus.killed);
      expect(c.killingTests, ['$suite::real']);
    });

    test('hooks are never re-run alone or sent to the flaky logic', () async {
      var reruns = 0;
      final s = StreamBuilder().loaded(suite).throws(suite, '(setUpAll)').done(success: false);
      final c = await classify(s, exitCode: 1, rerun: (t) async {
        reruns++;
        return passesAlone(t);
      });
      expect(reruns, 0);
      expect(c.status, MutantStatus.loadFailure);
    });

    test('a hook failing in a source-guard suite is no guard kill either', () async {
      final s = StreamBuilder().loaded('test/guards/g_test.dart').throws('test/guards/g_test.dart', '(setUpAll)').done(success: false);
      final c = await classify(s, exitCode: 1, guards: GuardMatcher(['test/guards/**']));
      expect(c.status, MutantStatus.loadFailure);
      expect(c.guardTests, isEmpty);
    });
  });

  test('MutantStatus ids are the report vocabulary', () {
    expect(MutantStatus.values.map((s) => s.id), [
      'killed',
      'killed-by-guard-only',
      'survived',
      'compile-invalid',
      'timeout',
      'load-failure',
      'skipped',
      'unconfirmed',
    ]);
  });
}
