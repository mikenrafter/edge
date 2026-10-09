import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:test/test.dart';

import 'support/events.dart';

/// Finding 3 (review round 3): the test framework's own timeout is reported as
/// an error event (`TimeoutException after ...: Test timed out after ...`) and
/// a failed result. It says the test hung, not that it noticed the mutant: it
/// is never a kill and never a confirmation.
const suite = 'test/a_test.dart';
const timedOut = 'TimeoutException after 0:00:30.000000: Test timed out after 30 seconds. '
    'See https://pub.dev/packages/test#timeouts';

StreamBuilder hung(StreamBuilder s, String name, {String message = timedOut}) =>
    s.test(suite, name, result: TestResult.error, errors: [(message, false)]);

Future<Classification> classify(StreamBuilder s,
        {int exitCode = 1, GuardMatcher? guards, Set<String> flaky = const {}, SingleTestRunner? rerun}) =>
    classifyRun(outcomeOf(s, exitCode: exitCode), guards: guards, flakyTests: flaky, rerun: rerun);

void main() {
  group('the evidence is recognised', () {
    test('the real message, both durations, and flutter_test (same package)', () {
      for (final m in [
        timedOut,
        'TimeoutException after 0:00:00.050000: Test timed out after 0 seconds.',
        'TimeoutException after 0:10:00.000000: Test timed out after 10 minutes.',
      ]) {
        expect(const TestError('', '', isFailure: false).isFrameworkTimeout, isFalse);
        expect(TestError(m, '', isFailure: false).isFrameworkTimeout, isTrue, reason: m);
      }
    });

    test('a timeout of the test body\'s own code is not the framework\'s', () {
      for (final m in [
        'TimeoutException after 0:00:00.020000: Future not completed',
        'Bad state: Test timed out after the user typed',
        'Expected: contains \'Test timed out after\'\n  Actual: \'x\'',
        'pumpAndSettle timed out',
      ]) {
        expect(TestError(m, '', isFailure: false).isFrameworkTimeout, isFalse, reason: m);
      }
    });
  });

  group('a run with framework timeouts', () {
    test('only framework timeouts: the mutant is a timeout, not a kill', () async {
      final s = hung(StreamBuilder().loaded(suite).pass(suite, 'ok'), 'hangs').done(success: false);
      final c = await classify(s);
      expect(c.status, MutantStatus.timeout);
      expect(c.killingTests, isEmpty);
      expect(c.frameworkTimeouts, ['$suite::hangs']);
      expect(c.detail, contains('hangs'));
    });

    test('a real failure next to a timeout still kills, and only the real one is a killer', () async {
      final s = hung(StreamBuilder().loaded(suite), 'hangs').fail(suite, 'asserts').done(success: false);
      final c = await classify(s);
      expect(c.status, MutantStatus.killed);
      expect(c.killingTests, ['$suite::asserts']);
      expect(c.frameworkTimeouts, ['$suite::hangs']);
    });

    test('the user\'s own TimeoutException is an exception kill as before', () async {
      final s = StreamBuilder()
          .loaded(suite)
          .throws(suite, 'user', 'TimeoutException after 0:00:00.020000: Future not completed')
          .done(success: false);
      final c = await classify(s);
      expect(c.status, MutantStatus.killed);
      expect(c.killers.single.kind, FailureKind.exception);
    });

    test('a test with a timeout and another error is still not a kill', () async {
      final s = StreamBuilder().loaded(suite).test(suite, 'both',
          result: TestResult.error, errors: [(timedOut, false), ('Bad state: late', false)]).done(success: false);
      final c = await classify(s);
      expect(c.killingTests, isEmpty);
      expect(c.status, MutantStatus.timeout);
    });

    test('timeouts and a guard failure: guard-only, no kill', () async {
      final s = hung(StreamBuilder().loaded(suite), 'hangs').fail('test/guards/g_test.dart', 'greps').done(success: false);
      final c = await classify(s, guards: GuardMatcher(['test/guards/**']));
      expect(c.status, MutantStatus.killedByGuardOnly);
      expect(c.killingTests, isEmpty);
      expect(c.frameworkTimeouts, ['$suite::hangs']);
    });

    test('timeouts and an unconfirmed failure: unconfirmed', () async {
      final s = hung(StreamBuilder().loaded(suite), 'hangs').test(suite, 'quiet', result: TestResult.failure).done(success: false);
      final c = await classify(s);
      expect(c.status, MutantStatus.unconfirmed);
      expect(c.killingTests, isEmpty);
    });

    test('a failure that passes alone next to a timeout leaves a timeout', () async {
      final s = hung(StreamBuilder().loaded(suite), 'hangs').test(suite, 'quiet', result: TestResult.failure).done(success: false);
      final c = await classify(s,
          rerun: (t) async => outcomeOf(StreamBuilder().loaded(t.suite).pass(t.suite, t.name).done()));
      expect(c.status, MutantStatus.timeout);
    });

    test('a timed-out test is not re-run (nothing to confirm, nothing to credit)', () async {
      final reran = <String>[];
      final s = hung(StreamBuilder().loaded(suite), 'hangs').done(success: false);
      await classify(s, flaky: {'$suite::hangs'}, rerun: (t) async {
        reran.add(t.key);
        return outcomeOf(StreamBuilder().loaded(t.suite).fail(t.suite, t.name).done(success: false), exitCode: 1);
      });
      expect(reran, isEmpty);
    });
  });

  group('a rerun that hits the framework timeout confirms nothing', () {
    ProcessOutcome rerunTimesOut(TestOutcome t) =>
        outcomeOf(hung(StreamBuilder().loaded(t.suite), t.name).done(success: false), exitCode: 1);

    test('an ambiguous failure whose rerun times out in the framework: unresolved', () async {
      final s = StreamBuilder().loaded(suite).test(suite, 'quiet', result: TestResult.failure).done(success: false);
      final c = await classify(s, rerun: (t) async => rerunTimesOut(t));
      expect(c.status, MutantStatus.unconfirmed);
      expect(c.killingTests, isEmpty);
      expect(c.reruns.single.result, RerunResult.unresolved);
      expect(c.reruns.single.detail, contains('timeout'));
    });

    test('a known flaky test whose rerun times out in the framework: unresolved', () async {
      final s = StreamBuilder().loaded(suite).fail(suite, 'flaky').done(success: false);
      final c = await classify(s, flaky: {'$suite::flaky'}, rerun: (t) async => rerunTimesOut(t));
      expect(c.status, MutantStatus.unconfirmed);
      expect(c.killingTests, isEmpty);
    });

    test('interpretRerun directly', () {
      final failed = TestOutcome(suite: suite, name: 'x', result: TestResult.failure, skipped: false);
      final r = interpretRerun(rerunTimesOut(failed), failed);
      expect(r.result, RerunResult.unresolved);
      expect(r.confirmed, isFalse);
    });
  });

  group('real reporter output', () {
    // `dart test --reporter json` (runnerVersion 1.33.0) over a file with two
    // tests that exceed `timeout: Timeout(...)`, one that throws its own
    // TimeoutException from Future.timeout, one failed expect and one pass.
    List<String> fixture() => File('test/fixtures/real_timeout.jsonl').readAsLinesSync();

    test('the parser sees four failures; two carry the framework timeout', () {
      final run = parseReporterStream(fixture());
      final failed = run.tests.where((t) => t.failed).toList();
      expect(failed.map((t) => t.name), [
        'hangs past its timeout',
        'times out by the group default',
        'user code throws its own TimeoutException',
        'assertion fails',
      ]);
      expect([for (final t in failed) t.errors.any((e) => e.isFrameworkTimeout)], [true, true, false, false]);
    });

    test('classified: the timeouts are evidence, the other two failures kill', () async {
      final c = await classifyRun(
          ProcessOutcome(exitCode: 1, stdoutLines: fixture(), stderr: '', elapsed: const Duration(seconds: 1)));
      expect(c.status, MutantStatus.killed);
      expect(c.killingTests, [
        'test/a_test.dart::user code throws its own TimeoutException',
        'test/a_test.dart::assertion fails',
      ]);
      expect(c.frameworkTimeouts, [
        'test/a_test.dart::hangs past its timeout',
        'test/a_test.dart::times out by the group default',
      ]);
    });

    test('only the two framework timeouts left: timeout', () async {
      final lines = [
        for (final l in fixture())
          if (!l.contains('"testID":5') && !l.contains('"testID":6')) l,
      ];
      final c = await classifyRun(
          ProcessOutcome(exitCode: 1, stdoutLines: lines, stderr: '', elapsed: const Duration(seconds: 1)));
      expect(c.status, MutantStatus.timeout);
      expect(c.killingTests, isEmpty);
    });
  });
}
