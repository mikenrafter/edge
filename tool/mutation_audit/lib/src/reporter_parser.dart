import 'dart:convert';

import 'package:path/path.dart' as p;

/// Result of one test as the JSON reporter states it.
enum TestResult { success, failure, error }

/// One `error` event of a test. [isFailure] is true for an assertion
/// (TestFailure), false for any other exception.
class TestError {
  const TestError(this.message, this.stackTrace, {required this.isFailure});
  final String message, stackTrace;
  final bool isFailure;

  /// The test framework's own timeout: package:test's invoker (flutter_test
  /// runs on it too) fails a test that outlives its `Timeout` with
  /// `TimeoutException after <duration>: Test timed out after <n> <unit>.`
  /// (test_api 0.7.x `Invoker.heartbeat`; checked against a real
  /// `dart test --reporter json` run, fixture `real_timeout.jsonl`). It says
  /// the test hung. A `TimeoutException` the test's own code throws (`Future not
  /// completed`) has another message and is an ordinary exception.
  bool get isFrameworkTimeout => _frameworkTimeout.hasMatch(message);
}

final _frameworkTimeout = RegExp(
    r'^TimeoutException after -?\d+:\d{2}:\d{2}(?:\.\d+)?: Test timed out after \d+(?:\.\d+)? \w+',
    multiLine: true);

/// One finished, visible test.
class TestOutcome {
  const TestOutcome({
    required this.suite,
    required this.name,
    required this.result,
    required this.skipped,
    this.errors = const [],
    this.printed = const [],
    this.durationMs = 0,
  });

  /// The suite path as the reporter printed it (usually `test/x_test.dart`).
  final String suite;

  /// The full test name (group names included).
  final String name;
  final TestResult result;
  final bool skipped;
  final List<TestError> errors;

  /// Messages the test printed (skip notices included).
  final List<String> printed;
  final int durationMs;

  /// Stable identity: `<suite>::<name>`.
  String get key => '$suite::$name';

  bool get failed => result != TestResult.success;

  /// The test failed by the test framework's timeout (any of its errors).
  bool get hitFrameworkTimeout => errors.any((e) => e.isFrameworkTimeout);
}

/// A suite that could not be loaded (compile error, exception at load, missing
/// file): the reporter's `loading <path>` pseudo-test ended in an error.
class LoadError {
  const LoadError(this.suite, this.message);
  final String suite, message;
}

/// A `setUpAll` / `tearDownAll` pseudo-test that failed. The reporter lists
/// each as a test named `(setUpAll)` or `<group> (setUpAll)`; its failure says
/// the environment broke, not that a test noticed the mutant, so it is never a
/// kill. (When `setUpAll` fails the tests of that group are not run at all.)
class SetupFailure {
  const SetupFailure(this.suite, this.name, this.message);
  final String suite, name, message;
}

final _hookName = RegExp(r'(^|\s)\((setUpAll|tearDownAll)\)$');

/// A whole reporter stream.
class ReporterRun {
  const ReporterRun({
    required this.tests,
    required this.loadErrors,
    this.setupFailures = const [],
    required this.sawDone,
    required this.doneSuccess,
    required this.nonJsonLines,
  });

  /// Finished tests that are neither hidden nor `loading ...`, in finish order.
  final List<TestOutcome> tests;
  final List<LoadError> loadErrors;

  /// Failed `setUpAll` / `tearDownAll` hooks. Hooks (passing or failing) are
  /// not in [tests]: a hook that passed is no evidence that a test passed.
  final List<SetupFailure> setupFailures;

  /// A `done` event arrived, and its `success` flag.
  final bool sawDone, doneSuccess;

  /// Lines that were not JSON objects (the Flutter tool mixes plain text in).
  final List<String> nonJsonLines;
}

/// Parses `dart test --reporter json` / `flutter test --reporter json` output
/// line by line (events: start, suite, testStart, group, testDone, error,
/// print, allSuites, done). Never throws on odd input: lines that are not JSON
/// objects go to [ReporterRun.nonJsonLines]; events about unknown test ids are
/// ignored; a test that started but never finished is not in [ReporterRun.tests].
///
/// With [root] (the directory the tests ran in), suite paths inside it are
/// reported relative to it: Flutter prints absolute paths, and a test key must
/// not depend on where the disposable export happened to be.
ReporterRun parseReporterStream(Iterable<String> lines, {String? root}) {
  final suites = <int, String>{};
  final started = <int, _Started>{};
  final tests = <TestOutcome>[];
  final loadErrors = <LoadError>[];
  final setupFailures = <SetupFailure>[];
  final nonJson = <String>[];
  var sawDone = false, doneSuccess = false;

  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      nonJson.add(line);
      continue;
    }
    if (decoded is! Map<String, dynamic>) {
      nonJson.add(line);
      continue;
    }
    final time = (decoded['time'] as num?)?.toInt() ?? 0;
    switch (decoded['type']) {
      case 'suite':
        final suite = decoded['suite'];
        if (suite is Map<String, dynamic> && suite['id'] is int) {
          final path = '${suite['path'] ?? ''}';
          suites[suite['id'] as int] =
              root != null && p.isWithin(root, path) ? p.relative(path, from: root) : path;
        }
      case 'testStart':
        final test = decoded['test'];
        if (test is Map<String, dynamic> && test['id'] is int) {
          started[test['id'] as int] =
              _Started('${test['name']}', test['suiteID'] as int?, time);
        }
      case 'print':
        started[decoded['testID']]?.printed.add('${decoded['message']}');
      case 'error':
        started[decoded['testID']]?.errors.add(TestError(
            '${decoded['error']}', '${decoded['stackTrace'] ?? ''}',
            isFailure: decoded['isFailure'] == true));
      case 'testDone':
        final t = started.remove(decoded['testID']);
        if (t == null) continue;
        final result = switch (decoded['result']) {
          'success' => TestResult.success,
          'failure' => TestResult.failure,
          _ => TestResult.error,
        };
        final suite = suites[t.suiteId] ?? '';
        if (t.name.startsWith('loading ')) {
          if (result != TestResult.success) {
            loadErrors.add(LoadError(suite, t.errors.map((e) => e.message).join('\n')));
          }
        } else if (_hookName.hasMatch(t.name)) {
          if (result != TestResult.success) {
            setupFailures.add(SetupFailure(suite, t.name, t.errors.map((e) => e.message).join('\n')));
          }
        } else if (decoded['hidden'] == true && result == TestResult.success) {
          // plumbing, not a test
        } else {
          tests.add(TestOutcome(
            suite: suite,
            name: t.name,
            result: result,
            skipped: decoded['skipped'] == true,
            errors: t.errors,
            printed: t.printed,
            durationMs: time - t.startTime,
          ));
        }
      case 'done':
        sawDone = true;
        doneSuccess = decoded['success'] == true;
    }
  }
  return ReporterRun(
    tests: tests,
    loadErrors: loadErrors,
    setupFailures: setupFailures,
    sawDone: sawDone,
    doneSuccess: doneSuccess,
    nonJsonLines: nonJson,
  );
}

class _Started {
  _Started(this.name, this.suiteId, this.startTime);
  final String name;
  final int? suiteId;
  final int startTime;
  final List<TestError> errors = [];
  final List<String> printed = [];
}
