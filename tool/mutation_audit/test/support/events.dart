import 'dart:convert';

import 'package:mutation_audit/mutation_audit.dart';

/// Builds a `--reporter json` stream the way the real reporter writes it
/// (shapes copied from `dart test --reporter json`, runnerVersion 1.33.0).
class StreamBuilder {
  StreamBuilder() {
    _emit({'protocolVersion': '0.1.1', 'runnerVersion': '1.33.0', 'pid': 1, 'type': 'start'});
  }

  final List<String> lines = [];
  final Map<String, int> _suiteIds = {};
  int _nextId = 1;
  int _clock = 0;

  void _emit(Map<String, Object?> event) {
    lines.add(jsonEncode({...event, 'time': _clock}));
  }

  int _suite(String path) => _suiteIds.putIfAbsent(path, () {
        final id = _suiteIds.length;
        _emit({
          'suite': {'id': id, 'platform': 'vm', 'path': path},
          'type': 'suite',
        });
        return id;
      });

  /// A test that ran: testStart, its prints and errors, testDone.
  /// [errors] are (message, isFailure) pairs.
  StreamBuilder test(
    String suite,
    String name, {
    TestResult result = TestResult.success,
    bool skipped = false,
    bool hidden = false,
    List<(String, bool)> errors = const [],
    List<String> prints = const [],
    int takes = 10,
  }) {
    final suiteId = _suite(suite);
    final id = _nextId++;
    _emit({
      'test': {
        'id': id,
        'name': name,
        'suiteID': suiteId,
        'groupIDs': <int>[],
        'metadata': {'skip': skipped, 'skipReason': skipped ? 'why' : null},
        'line': 1,
        'column': 1,
        'url': 'file:///x/$suite',
      },
      'type': 'testStart',
    });
    for (final p in prints) {
      _emit({'testID': id, 'messageType': 'print', 'message': p, 'type': 'print'});
    }
    for (final (message, isFailure) in errors) {
      _emit({
        'testID': id,
        'error': message,
        'stackTrace': 'package:matcher expect\n$suite 1:1  main.<fn>\n',
        'isFailure': isFailure,
        'type': 'error',
      });
    }
    _clock += takes;
    _emit({
      'testID': id,
      'result': switch (result) {
        TestResult.success => 'success',
        TestResult.failure => 'failure',
        TestResult.error => 'error',
      },
      'skipped': skipped,
      'hidden': hidden,
      'type': 'testDone',
    });
    return this;
  }

  StreamBuilder pass(String suite, String name) => test(suite, name);

  StreamBuilder fail(String suite, String name, [String message = 'Expected: <2>\n  Actual: <1>\n']) =>
      test(suite, name, result: TestResult.failure, errors: [(message, true)]);

  StreamBuilder throws(String suite, String name, [String message = 'Bad state: boom']) =>
      test(suite, name, result: TestResult.error, errors: [(message, false)]);

  /// The `loading <suite>` pseudo-test ending in an error (compile error,
  /// exception at load, missing file).
  StreamBuilder loadError(String suite, String message) {
    final suiteId = _suite(suite);
    final id = _nextId++;
    _emit({
      'test': {
        'id': id,
        'name': 'loading $suite',
        'suiteID': suiteId,
        'groupIDs': <int>[],
        'metadata': {'skip': false, 'skipReason': null},
        'line': null,
        'column': null,
        'url': null,
      },
      'type': 'testStart',
    });
    _emit({
      'testID': id,
      'error': message,
      'stackTrace': 'package:test_core/src/runner/vm/platform.dart 605:7 VMPlatform._compileToKernel\n',
      'isFailure': false,
      'type': 'error',
    });
    _clock += 5;
    _emit({'testID': id, 'result': 'error', 'skipped': false, 'hidden': false, 'type': 'testDone'});
    return this;
  }

  /// A loading pseudo-test that succeeded (hidden), as the real reporter
  /// writes one per suite.
  StreamBuilder loaded(String suite) {
    final suiteId = _suite(suite);
    final id = _nextId++;
    _emit({
      'test': {
        'id': id,
        'name': 'loading $suite',
        'suiteID': suiteId,
        'groupIDs': <int>[],
        'metadata': {'skip': false, 'skipReason': null},
        'line': null,
        'column': null,
        'url': null,
      },
      'type': 'testStart',
    });
    _emit({'testID': id, 'result': 'success', 'skipped': false, 'hidden': true, 'type': 'testDone'});
    return this;
  }

  StreamBuilder raw(String line) {
    lines.add(line);
    return this;
  }

  /// A test that started and never finished (the process died or timed out).
  StreamBuilder unfinished(String suite, String name) {
    final suiteId = _suite(suite);
    final id = _nextId++;
    _emit({
      'test': {
        'id': id,
        'name': name,
        'suiteID': suiteId,
        'groupIDs': <int>[],
        'metadata': {'skip': false, 'skipReason': null},
        'line': 1,
        'column': 1,
        'url': null,
      },
      'type': 'testStart',
    });
    return this;
  }

  StreamBuilder done({bool success = true}) {
    _emit({'success': success, 'type': 'done'});
    return this;
  }

  List<String> build() => List.unmodifiable(lines);
}

ProcessOutcome outcomeOf(
  StreamBuilder stream, {
  int exitCode = 0,
  bool timedOut = false,
  String stderr = '',
  Duration elapsed = const Duration(seconds: 1),
}) =>
    ProcessOutcome(
      exitCode: exitCode,
      stdoutLines: stream.build(),
      stderr: stderr,
      timedOut: timedOut,
      elapsed: elapsed,
    );

/// A run in which everything passes.
StreamBuilder passing([String suite = 'test/a_test.dart']) =>
    StreamBuilder().loaded(suite).pass(suite, 'g passes').done();

/// A run in which [name] fails by assertion.
StreamBuilder failing(String name, [String suite = 'test/a_test.dart']) =>
    StreamBuilder().loaded(suite).pass(suite, 'g passes').fail(suite, name).done(success: false);
