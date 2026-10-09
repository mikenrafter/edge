import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:test/test.dart';

import 'support/events.dart';

List<String> fixture(String name) => File('test/fixtures/$name').readAsLinesSync();

TestOutcome byName(ReporterRun run, String name) => run.tests.singleWhere((t) => t.name == name);

void main() {
  group('a real dart test run (mixed results)', () {
    late ReporterRun run;
    setUp(() => run = parseReporterStream(fixture('real_mixed.jsonl')));

    test('lists the visible tests, not the loading pseudo-test', () {
      expect(run.tests.map((t) => t.name), ['g passes', 'g fails', 'g throws', 'g skipped', 'g prints']);
      expect(run.tests.map((t) => t.suite).toSet(), {'test/a_test.dart'});
      expect(run.loadErrors, isEmpty);
    });

    test('results, assertion versus exception, messages', () {
      expect(byName(run, 'g passes').result, TestResult.success);
      final failing = byName(run, 'g fails');
      expect(failing.result, TestResult.failure);
      expect(failing.failed, isTrue);
      expect(failing.errors.single.isFailure, isTrue);
      expect(failing.errors.single.message, contains('Expected: <2>'));
      expect(failing.errors.single.stackTrace, contains('test/a_test.dart'));
      final thrown = byName(run, 'g throws');
      expect(thrown.result, TestResult.error);
      expect(thrown.errors.single.isFailure, isFalse);
      expect(thrown.errors.single.message, 'Bad state: boom');
    });

    test('skips and prints', () {
      final skipped = byName(run, 'g skipped');
      expect(skipped.skipped, isTrue);
      expect(skipped.result, TestResult.success);
      expect(skipped.printed, contains('Skip: why'));
      expect(byName(run, 'g prints').printed, ['hello']);
    });

    test('duration is the time between testStart and testDone', () {
      expect(byName(run, 'g passes').durationMs, 23);
      expect(byName(run, 'g fails').durationMs, 25);
    });

    test('keys are suite and full name', () {
      expect(byName(run, 'g fails').key, 'test/a_test.dart::g fails');
    });

    test('done is seen, and it says the run failed', () {
      expect(run.sawDone, isTrue);
      expect(run.doneSuccess, isFalse);
      expect(run.nonJsonLines, isEmpty);
    });
  });

  group('suites that do not load (real runs)', () {
    test('a compile error', () {
      final run = parseReporterStream(fixture('real_compile_error.jsonl'));
      expect(run.tests, isEmpty);
      final e = run.loadErrors.single;
      expect(e.suite, 'test/b_test.dart');
      expect(e.message, contains("Error: A value of type 'String' can't be assigned"));
      expect(run.sawDone, isTrue);
      expect(run.doneSuccess, isFalse);
    });

    test('an exception while loading', () {
      final run = parseReporterStream(fixture('real_load_exception.jsonl'));
      expect(run.tests, isEmpty);
      expect(run.loadErrors.single.suite, 'test/c_test.dart');
      expect(run.loadErrors.single.message, contains('Bad state: load time'));
    });

    test('a missing file', () {
      final run = parseReporterStream(fixture('real_missing_file.jsonl'));
      expect(run.loadErrors.single.message, contains('Does not exist'));
    });
  });

  group('setUpAll / tearDownAll failures (real run)', () {
    test('they are setup failures, not tests; the group whose setUpAll failed ran nothing', () {
      final run = parseReporterStream(fixture('real_setup_all.jsonl'));
      expect(run.tests.map((t) => t.key), ['test/a_test.dart::h t3', 'test/a_test.dart::top']);
      expect(run.setupFailures.map((f) => (f.suite, f.name)),
          [('test/a_test.dart', 'g (setUpAll)'), ('test/a_test.dart', 'h (tearDownAll)')]);
      expect(run.setupFailures.first.message, contains('Bad state: boom setup'));
      expect(run.loadErrors, isEmpty);
    });

    test('a passing hook is not a test either (it must not count as a test that passed)', () {
      final s = StreamBuilder().test('test/a_test.dart', 'g (setUpAll)').done();
      final run = parseReporterStream(s.build());
      expect(run.tests, isEmpty);
      expect(run.setupFailures, isEmpty);
    });

    test('top-level hooks have the bare name; failures by assertion count the same', () {
      final s = StreamBuilder()
          .fail('test/a_test.dart', '(setUpAll)')
          .throws('test/a_test.dart', '(tearDownAll)')
          .done(success: false);
      final run = parseReporterStream(s.build());
      expect(run.tests, isEmpty);
      expect(run.setupFailures, hasLength(2));
    });

    test('an ordinary test that merely mentions the word is a test', () {
      final s = StreamBuilder().fail('test/a_test.dart', 'setUpAll is documented').done(success: false);
      expect(parseReporterStream(s.build()).tests, hasLength(1));
    });
  });

  group('shapes the real runs do not show', () {
    test('a passing run', () {
      final run = parseReporterStream(passing().build());
      expect(run.tests.map((t) => t.key), ['test/a_test.dart::g passes']);
      expect(run.sawDone && run.doneSuccess, isTrue);
    });

    test('several suites, the same test name in two of them', () {
      final s = StreamBuilder()
          .pass('test/a_test.dart', 'same')
          .fail('test/b_test.dart', 'same')
          .pass('test/b_test.dart', 'other')
          .done(success: false);
      final run = parseReporterStream(s.build());
      expect(run.tests.map((t) => t.key),
          ['test/a_test.dart::same', 'test/b_test.dart::same', 'test/b_test.dart::other']);
      expect(run.tests[1].failed, isTrue);
      expect(run.tests[0].failed, isFalse);
    });

    test('a test with two errors keeps both, in order', () {
      final s = StreamBuilder()
          .test('test/a_test.dart', 't',
              result: TestResult.failure, errors: [('first', true), ('second', false)])
          .done(success: false);
      final t = parseReporterStream(s.build()).tests.single;
      expect(t.errors.map((e) => e.message), ['first', 'second']);
      expect(t.errors.map((e) => e.isFailure), [true, false]);
    });

    test('a loading error next to tests that ran', () {
      final s = StreamBuilder()
          .loaded('test/a_test.dart')
          .pass('test/a_test.dart', 'ok')
          .loadError('test/b_test.dart', 'Failed to load "test/b_test.dart": boom')
          .done(success: false);
      final run = parseReporterStream(s.build());
      expect(run.tests.map((t) => t.name), ['ok']);
      expect(run.loadErrors.map((e) => e.suite), ['test/b_test.dart']);
    });

    test('a test that started and never finished is not listed', () {
      final s = StreamBuilder().pass('test/a_test.dart', 'ok').unfinished('test/a_test.dart', 'hang');
      final run = parseReporterStream(s.build());
      expect(run.tests.map((t) => t.name), ['ok']);
      expect(run.sawDone, isFalse);
      expect(run.doneSuccess, isFalse);
    });

    test('plain-text lines, arrays and broken JSON are set aside; blank lines vanish', () {
      final s = StreamBuilder()
          .raw('Running "flutter pub get" in app...')
          .raw('')
          .raw('[1, 2, 3]')
          .raw('{"type": "print", "message"')
          .pass('test/a_test.dart', 'ok')
          .raw('   ')
          .done();
      final run = parseReporterStream(s.build());
      expect(run.nonJsonLines, ['Running "flutter pub get" in app...', '[1, 2, 3]', '{"type": "print", "message"']);
      expect(run.tests.map((t) => t.name), ['ok']);
    });

    test('events about test ids that never started are ignored', () {
      final s = StreamBuilder()
          .raw('{"testID":99,"result":"failure","skipped":false,"hidden":false,"type":"testDone","time":5}')
          .raw('{"testID":98,"error":"x","stackTrace":"","isFailure":true,"type":"error","time":6}')
          .pass('test/a_test.dart', 'ok')
          .done();
      final run = parseReporterStream(s.build());
      expect(run.tests.map((t) => t.name), ['ok']);
      expect(run.loadErrors, isEmpty);
    });

    test('suite paths inside the root are made relative to it', () {
      final s = StreamBuilder()
          .pass('/tmp/export-1/test/a_test.dart', 'ok')
          .fail('/elsewhere/b_test.dart', 'bad')
          .loadError('/tmp/export-1/test/c_test.dart', 'Failed to load')
          .done(success: false);
      final run = parseReporterStream(s.build(), root: '/tmp/export-1');
      expect(run.tests.map((t) => t.key), ['test/a_test.dart::ok', '/elsewhere/b_test.dart::bad']);
      expect(run.loadErrors.single.suite, 'test/c_test.dart');
      expect(parseReporterStream(s.build()).tests.first.suite, '/tmp/export-1/test/a_test.dart');
    });

    test('an empty stream parses to an empty run', () {
      final run = parseReporterStream(const []);
      expect(run.tests, isEmpty);
      expect(run.loadErrors, isEmpty);
      expect(run.sawDone, isFalse);
    });
  });
}
