import 'dart:io';

import 'applier.dart';
import 'classifier.dart';
import 'command.dart';
import 'config.dart';
import 'export.dart' show InterruptedError;
import 'export_state.dart';
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
  AuditRunner({
    required this.runner,
    this.applierFor = MutationApplier.new,
    this.stateGuard,
    String? tempParent,
  }) : tempParent = tempParent ?? Directory.systemTemp.path;
  final ProcessRunner runner;

  /// Keeps the export's test-visible state the same before every run (null: not checked).
  final ExportStateGuard? stateGuard;

  /// Where the per-run temporary directories are made (outside the export).
  final String tempParent;

  /// One test-tool run with its own `TMPDIR` (also `TMP`, `TEMP`: what
  /// `Directory.systemTemp` follows), created before and deleted after, so
  /// nothing a run leaves in a temporary directory reaches another run. With a
  /// [stateGuard] and a [tally], the export is put back afterwards ([keep]:
  /// the tracked file carrying the mutation, which stays as it is).
  Future<ProcessOutcome> _exec(
    List<String> argv, {
    required AuditConfig config,
    required String root,
    CancelToken? cancel,
    Set<String> keep = const {},
    _Tally? tally,
  }) async {
    final tmp = Directory(tempParent).createTempSync('mutaudit_run_');
    final ProcessOutcome outcome;
    try {
      outcome = await runner.run(
        argv,
        workingDirectory: root,
        timeout: config.timeout,
        environment: {...config.env, 'TMPDIR': tmp.path, 'TMP': tmp.path, 'TEMP': tmp.path},
        cancel: cancel,
      );
    } finally {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // unique to this run: leftovers here cannot reach another run
      }
    }
    final guard = stateGuard;
    if (guard != null && tally != null && !outcome.cancelled && !(cancel?.isCancelled ?? false)) {
      tally.restored += await guard.restore(keep: keep);
    }
    return outcome;
  }

  /// Creates the applier for a root (a seam for tests).
  final MutationApplier Function(String root) applierFor;

  /// Runs the configured tests on the untouched tree under [root]. Passes only
  /// when the process exited 0, a `done` event with success arrived, nothing
  /// failed to load and at least one test ran. Throws [BaselineFailedError]
  /// (naming the first failing test or load error) otherwise.
  Future<BaselineSummary> runBaseline(AuditConfig config, String root, {CancelToken? cancel}) async {
    if (cancel != null && cancel.isCancelled) throw InterruptedError();
    final outcome = await _exec(buildTestCommand(config.testCmd, tests: config.tests),
        config: config, root: root, cancel: cancel);
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
    GuardMatcher? guards,
  }) async {
    final baseline = await runBaseline(config, root, cancel: cancel);
    // The reference state: from here every run must start from it.
    await stateGuard?.snapshot();
    final applier = applierFor(root);
    final matcher = guards ?? GuardMatcher(config.guardPatterns);
    final flaky = config.flakyTests.toSet();
    final results = <MutantResult>[];

    for (final mutant in mutants) {
      if (cancel != null && cancel.isCancelled) throw InterruptedError();
      final tally = _Tally();
      Future<ProcessOutcome> alone(TestOutcome failed) => _exec(
            buildTestCommand(config.testCmd, tests: [failed.suite], fullName: failed.name),
            config: config,
            root: root,
            cancel: cancel,
            keep: {mutant.file},
            tally: tally,
          );

      final applied = await applier.apply(mutant);
      late final Classification classification;
      late final Duration elapsed;
      try {
        final outcome = await _exec(buildTestCommand(config.testCmd, tests: config.tests),
            config: config, root: root, cancel: cancel, keep: {mutant.file}, tally: tally);
        if (outcome.cancelled || (cancel?.isCancelled ?? false)) throw InterruptedError();
        classification =
            await classifyRun(outcome, guards: matcher, flakyTests: flaky, rerun: alone, root: root);
        if (cancel?.isCancelled ?? false) throw InterruptedError();
        elapsed = outcome.elapsed;
      } finally {
        await applier.restore(applied);
      }
      // A signal that landed while the file was being put back.
      if (cancel != null && cancel.isCancelled) throw InterruptedError();
      // The mutated file is back: the whole tree must now be the snapshot.
      final guard = stateGuard;
      if (guard != null) tally.restored += await guard.restore();
      results.add(MutantResult(
          mutant: mutant, classification: classification, duration: elapsed, stateRestored: tally.restored));
    }
    if (cancel != null && cancel.isCancelled) throw InterruptedError();
    return (baseline: baseline, results: results);
  }
}

class _Tally {
  int restored = 0;
}
