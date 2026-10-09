import 'applier.dart';
import 'classifier.dart';
import 'command.dart';
import 'config.dart';
import 'export.dart' show InterruptedError;
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
  AuditRunner({required this.runner, this.applierFor = MutationApplier.new});
  final ProcessRunner runner;

  /// Creates the applier for a root (a seam for tests).
  final MutationApplier Function(String root) applierFor;

  /// Runs the configured tests on the untouched tree under [root]. Passes only
  /// when the process exited 0, a `done` event with success arrived, nothing
  /// failed to load and at least one test ran. Throws [BaselineFailedError]
  /// (naming the first failing test or load error) otherwise.
  Future<BaselineSummary> runBaseline(AuditConfig config, String root, {CancelToken? cancel}) async {
    if (cancel != null && cancel.isCancelled) throw InterruptedError();
    final outcome = await runner.run(
      buildTestCommand(config.testCmd, tests: config.tests),
      workingDirectory: root,
      timeout: config.timeout,
      environment: config.env,
      cancel: cancel,
    );
    if (outcome.cancelled || (cancel?.isCancelled ?? false)) throw InterruptedError();
    if (outcome.timedOut) {
      throw BaselineFailedError('the baseline run timed out after ${config.timeout.inSeconds} s');
    }
    final run = parseReporterStream(outcome.stdoutLines, root: root);
    for (final e in run.loadErrors) {
      throw BaselineFailedError('a suite does not load: ${e.suite}: ${e.message.split('\n').first}');
    }
    for (final f in run.setupFailures) {
      throw BaselineFailedError(
          'the baseline fails in a hook: ${f.suite}: ${f.name}: ${f.message.split('\n').first}');
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
  ///
  /// [cancel] (Ctrl-C) is handed to every child run. Once it fires no further
  /// mutant is written; the run in flight is stopped by the process runner
  /// (which returns after the tree is gone), the mutated file is restored, and
  /// [InterruptedError] is thrown. A cancelled run is never classified.
  Future<({BaselineSummary baseline, List<MutantResult> results})> run({
    required AuditConfig config,
    required String root,
    required List<Mutant> mutants,
    CancelToken? cancel,
  }) async {
    final baseline = await runBaseline(config, root, cancel: cancel);
    final applier = applierFor(root);
    final guards = GuardMatcher(config.guardPatterns);
    final flaky = config.flakyTests.toSet();
    final results = <MutantResult>[];

    Future<ProcessOutcome> alone(TestOutcome failed) => runner.run(
          buildTestCommand(config.testCmd, tests: [failed.suite], fullName: failed.name),
          workingDirectory: root,
          timeout: config.timeout,
          environment: config.env,
          cancel: cancel,
        );

    for (final mutant in mutants) {
      if (cancel != null && cancel.isCancelled) throw InterruptedError();
      final applied = await applier.apply(mutant);
      try {
        final outcome = await runner.run(
          buildTestCommand(config.testCmd, tests: config.tests),
          workingDirectory: root,
          timeout: config.timeout,
          environment: config.env,
          cancel: cancel,
        );
        if (outcome.cancelled || (cancel?.isCancelled ?? false)) throw InterruptedError();
        final classification =
            await classifyRun(outcome, guards: guards, flakyTests: flaky, rerun: alone, root: root);
        if (cancel?.isCancelled ?? false) throw InterruptedError();
        results.add(MutantResult(
            mutant: mutant, classification: classification, duration: outcome.elapsed));
      } finally {
        await applier.restore(applied);
      }
      // A signal that landed while the file was being put back.
      if (cancel != null && cancel.isCancelled) throw InterruptedError();
    }
    if (cancel != null && cancel.isCancelled) throw InterruptedError();
    return (baseline: baseline, results: results);
  }
}
