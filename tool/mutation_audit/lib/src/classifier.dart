import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'process_runner.dart';
import 'reporter_parser.dart';

/// What happened to one mutant.
enum MutantStatus {
  /// At least one non-guard test failed (assertion or exception) after the
  /// failure was confirmed.
  killed('killed'),

  /// Only source-guard tests failed: not runtime coverage.
  killedByGuardOnly('killed-by-guard-only'),

  /// Every test that ran passed, and at least one ran.
  survived('survived'),

  /// The mutant did not compile (a load error with a compiler diagnostic).
  compileInvalid('compile-invalid'),

  /// The run hit its timeout.
  timeout('timeout'),

  /// A suite failed to load for another reason, or the run produced no usable
  /// reporter stream.
  loadFailure('load-failure'),

  /// The run finished but no test actually ran (all skipped, or none).
  skipped('skipped');

  const MutantStatus(this.id);
  final String id;
}

/// Matches source-guard tests: globs against the suite path. A pattern without
/// a `/` matches the file name only; one with a `/` matches the path or any
/// suffix of it (so `test/guards/**` matches `/abs/repo/test/guards/a_test.dart`).
class GuardMatcher {
  GuardMatcher(this.patterns)
      : _globs = [for (final pattern in patterns) (pattern.contains('/'), Glob(pattern, context: p.posix))];
  final List<String> patterns;
  final List<(bool, Glob)> _globs;

  bool matches(TestOutcome test) {
    final segments = test.suite.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return false;
    for (final (withSlash, glob) in _globs) {
      if (!withSlash) {
        if (glob.matches(segments.last)) return true;
        continue;
      }
      // The path itself or any suffix of it (an absolute prefix is not part of
      // the pattern's business).
      for (var i = 0; i < segments.length; i++) {
        if (glob.matches(segments.sublist(i).join('/'))) return true;
      }
    }
    return false;
  }
}

/// Runs one failed test alone (same mutant, same working tree) and returns its
/// outcome, or null when it did not run at all.
typedef SingleTestRunner = Future<TestOutcome?> Function(TestOutcome failed);

/// What re-running an ambiguous failure alone showed.
class RerunRecord {
  const RerunRecord(this.testKey, {required this.confirmed});
  final String testKey;

  /// The test failed again alone (a real failure) or passed (flaky).
  final bool confirmed;
}

/// The verdict on one mutant run.
class Classification {
  const Classification({
    required this.status,
    this.killingTests = const [],
    this.guardTests = const [],
    this.reruns = const [],
    this.detail = '',
  });

  final MutantStatus status;

  /// Keys (`suite::name`) of the confirmed non-guard failures, in finish order.
  final List<String> killingTests;

  /// Keys of confirmed failures of guard tests.
  final List<String> guardTests;
  final List<RerunRecord> reruns;

  /// One line saying why (the first compiler diagnostic, the load error, ...).
  final String detail;
}

/// Classifies one mutant run from its process outcome. Precedence:
///
/// 1. [ProcessOutcome.timedOut] -> timeout.
/// 2. any load error whose message carries a compiler diagnostic
///    (`<file>:<line>:<col>: Error:` or `Compilation failed`) -> compileInvalid
///    (the mutant is not code; nothing else in the run counts).
/// 3. failed tests -> each one that is in [flakyTests] or has no error event
///    (not attributable) is first re-run alone through [rerun]; a failure that
///    passes alone is dropped (recorded, not confirmed). Confirmed failures
///    that match [guards] are guard failures, the rest kill: any kill ->
///    killed; only guard failures -> killedByGuardOnly.
/// 4. load errors left (exception at load, missing file) -> loadFailure.
/// 5. no `done` event, or a non-zero exit with nothing else to blame ->
///    loadFailure.
/// 6. at least one non-skipped test passed -> survived; otherwise skipped.
///
/// [root] is the directory the tests ran in: suite paths are made relative to
/// it, so test keys do not depend on where the export lives.
Future<Classification> classifyRun(
  ProcessOutcome outcome, {
  GuardMatcher? guards,
  Set<String> flakyTests = const {},
  SingleTestRunner? rerun,
  String? root,
}) async {
  if (outcome.timedOut) {
    return const Classification(status: MutantStatus.timeout, detail: 'the test run timed out');
  }
  final run = parseReporterStream(outcome.stdoutLines, root: root);

  final compile = [for (final e in run.loadErrors) if (_isCompileError(e.message)) e];
  if (compile.isNotEmpty) {
    return Classification(
        status: MutantStatus.compileInvalid, detail: _diagnostic(compile.first.message));
  }

  final failed = [for (final t in run.tests) if (t.failed) t];
  var passedAfterRerun = 0;
  final reruns = <RerunRecord>[];
  final killing = <String>[];
  final guardFailures = <String>[];
  for (final t in failed) {
    var confirmed = true;
    final ambiguous = flakyTests.contains(t.key) || t.errors.isEmpty;
    if (ambiguous && rerun != null) {
      final again = await rerun(t);
      confirmed = again == null || again.failed;
      reruns.add(RerunRecord(t.key, confirmed: confirmed));
      if (!confirmed) passedAfterRerun++;
    }
    if (!confirmed) continue;
    ((guards?.matches(t) ?? false) ? guardFailures : killing).add(t.key);
  }
  if (killing.isNotEmpty) {
    return Classification(
      status: MutantStatus.killed,
      killingTests: killing,
      guardTests: guardFailures,
      reruns: reruns,
      detail: _firstLine(failed.firstWhere((t) => t.key == killing.first).errors),
    );
  }
  if (guardFailures.isNotEmpty) {
    return Classification(
        status: MutantStatus.killedByGuardOnly, guardTests: guardFailures, reruns: reruns);
  }

  if (run.loadErrors.isNotEmpty) {
    return Classification(
        status: MutantStatus.loadFailure,
        reruns: reruns,
        detail: _firstMessageLine(run.loadErrors.first.message));
  }
  if (!run.sawDone || (failed.isEmpty && outcome.exitCode != 0)) {
    final why = outcome.stderr.trim().isNotEmpty
        ? outcome.stderr.trim().split('\n').first
        : (!run.sawDone ? 'no reporter output (exit code ${outcome.exitCode})' : 'exit code ${outcome.exitCode}');
    return Classification(status: MutantStatus.loadFailure, reruns: reruns, detail: why);
  }

  final passed = run.tests.where((t) => !t.failed && !t.skipped).length + passedAfterRerun;
  return Classification(
      status: passed > 0 ? MutantStatus.survived : MutantStatus.skipped, reruns: reruns);
}

final _compilerDiagnostic = RegExp(r':\d+:\d+: Error:');

bool _isCompileError(String message) =>
    _compilerDiagnostic.hasMatch(message) || message.contains('Compilation failed');

String _diagnostic(String message) {
  for (final line in message.split('\n')) {
    if (_compilerDiagnostic.hasMatch(line)) return line.trim();
  }
  return _firstMessageLine(message);
}

String _firstMessageLine(String message) => message.split('\n').first.trim();

String _firstLine(List<TestError> errors) =>
    errors.isEmpty ? '' : _firstMessageLine(errors.first.message);
