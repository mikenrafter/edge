import 'applier.dart';
import 'classifier.dart';
import 'command.dart';
import 'config.dart';
import 'mutant.dart';
import 'process_runner.dart';
import 'report.dart';
import 'reporter_parser.dart';

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
  Future<BaselineSummary> runBaseline(AuditConfig config, String root) async {
    final outcome = await runner.run(
      buildTestCommand(config.testCmd, tests: config.tests),
      workingDirectory: root,
      timeout: config.timeout,
      environment: config.env,
    );
    if (outcome.timedOut) {
      throw BaselineFailedError('the baseline run timed out after ${config.timeout.inSeconds} s');
    }
    final run = parseReporterStream(outcome.stdoutLines, root: root);
    for (final e in run.loadErrors) {
      throw BaselineFailedError('a suite does not load: ${e.suite}: ${e.message.split('\n').first}');
    }
    for (final t in run.tests) {
      if (t.failed) {
        final why = t.errors.isEmpty ? '' : ': ${t.errors.first.message.split('\n').first}';
        throw BaselineFailedError('the baseline fails: ${t.key}$why');
      }
    }
    final ran = run.tests.where((t) => !t.skipped).length;
    if (outcome.exitCode != 0 || !run.sawDone || !run.doneSuccess) {
      throw BaselineFailedError('the baseline run is not clean (exit code ${outcome.exitCode}'
          '${outcome.stderr.trim().isEmpty ? '' : ', ${outcome.stderr.trim().split('\n').first}'})');
    }
    if (ran == 0) throw BaselineFailedError('the baseline ran no test');
    return BaselineSummary(passed: true, testsRun: ran, duration: outcome.elapsed);
  }

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
  }) async {
    final baseline = await runBaseline(config, root);
    final applier = MutationApplier(root);
    final guards = GuardMatcher(config.guardPatterns);
    final flaky = config.flakyTests.toSet();
    final results = <MutantResult>[];

    Future<TestOutcome?> alone(TestOutcome failed) async {
      final outcome = await runner.run(
        buildTestCommand(config.testCmd, tests: [failed.suite], plainName: failed.name),
        workingDirectory: root,
        timeout: config.timeout,
        environment: config.env,
      );
      for (final t in parseReporterStream(outcome.stdoutLines, root: root).tests) {
        if (t.key == failed.key) return t;
      }
      return null;
    }

    for (final mutant in mutants) {
      final applied = await applier.apply(mutant);
      try {
        final outcome = await runner.run(
          buildTestCommand(config.testCmd, tests: config.tests),
          workingDirectory: root,
          timeout: config.timeout,
          environment: config.env,
        );
        final classification =
            await classifyRun(outcome, guards: guards, flakyTests: flaky, rerun: alone, root: root);
        results.add(MutantResult(
            mutant: mutant, classification: classification, duration: outcome.elapsed));
      } finally {
        await applier.restore(applied);
      }
    }
    return (baseline: baseline, results: results);
  }
}
