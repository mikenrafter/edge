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
ReporterRun parseReporterStream(Iterable<String> lines) =>
    throw UnimplementedError('parseReporterStream');
