import 'applier.dart';
import 'config.dart';
import 'mutant.dart';
import 'process_runner.dart';
import 'report.dart';

/// The unmutated tree does not pass its own tests: nothing can be concluded.
class BaselineFailedError implements Exception {
  BaselineFailedError(this.message);
  final String message;
  @override
  String toString() => 'BaselineFailedError: $message';
}

/// Runs the baseline and then every mutant, one at a time.
class AuditRunner {
  AuditRunner({required this.runner});
  final ProcessRunner runner;

  /// Runs the configured tests on the untouched tree under [root]. Passes only
  /// when the process exited 0, a `done` event with success arrived, nothing
  /// failed to load and at least one test ran. Throws [BaselineFailedError]
  /// (naming the first failing test or load error) otherwise.
  Future<BaselineSummary> runBaseline(AuditConfig config, String root) =>
      throw UnimplementedError('AuditRunner.runBaseline');

  /// [runBaseline] first (its [BaselineFailedError] propagates before any
  /// mutant is written), then serially, per mutant: apply it under [root], run
  /// the tests with `config.timeout`, classify (re-running ambiguous failures
  /// alone once), then restore the file byte for byte and verify -- also when
  /// the run or the classification throws. A failed restore aborts the whole
  /// audit with [RestoreFailedError]. Results are in the order of [mutants].
  Future<({BaselineSummary baseline, List<MutantResult> results})> run({
    required AuditConfig config,
    required String root,
    required List<Mutant> mutants,
  }) =>
      throw UnimplementedError('AuditRunner.run');
}
