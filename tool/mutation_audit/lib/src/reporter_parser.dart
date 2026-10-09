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
}

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
}

/// A suite that could not be loaded (compile error, exception at load, missing
/// file): the reporter's `loading <path>` pseudo-test ended in an error.
class LoadError {
  const LoadError(this.suite, this.message);
  final String suite, message;
}

/// A whole reporter stream.
class ReporterRun {
  const ReporterRun({
    required this.tests,
    required this.loadErrors,
    required this.sawDone,
    required this.doneSuccess,
    required this.nonJsonLines,
  });

  /// Finished tests that are neither hidden nor `loading ...`, in finish order.
  final List<TestOutcome> tests;
  final List<LoadError> loadErrors;

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
