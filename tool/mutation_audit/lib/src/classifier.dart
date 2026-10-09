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
  GuardMatcher(this.patterns);
  final List<String> patterns;

  bool matches(TestOutcome test) => throw UnimplementedError('GuardMatcher.matches');
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
Future<Classification> classifyRun(
  ProcessOutcome outcome, {
  GuardMatcher? guards,
  Set<String> flakyTests = const {},
  SingleTestRunner? rerun,
}) =>
    throw UnimplementedError('classifyRun');
