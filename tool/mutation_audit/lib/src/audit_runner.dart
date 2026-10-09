import 'dart:io';

import 'applier.dart';
import 'classifier.dart';
import 'command.dart';
import 'config.dart';
import 'export.dart' show InterruptedError;
import 'export_integrity.dart';
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
///
/// Isolation is the runner's business, not this class's: with a sandbox
/// ([isolated]) every run is launched in bubblewrap by [runner], so nothing a
/// run does reaches the next one. What this class adds is the proof: with an
/// [integrity] check, the host export is compared with what it was before the
/// run, after EVERY run (baseline, mutant, rerun), and the audit stops
/// ([ExportStateError]) when it differs. Without a sandbox only the pinned
/// commit is enforced after every run (the runs may leave files).
class AuditRunner {
  AuditRunner({
    required this.runner,
    this.applierFor = MutationApplier.new,
    this.integrity,
    this.isolated = false,
    String? tempParent,
  }) : tempParent = tempParent ?? Directory.systemTemp.path;
  final ProcessRunner runner;

  /// Checks after every run that the export on the host is what it was before
  /// (null: not checked, as without a sandbox).
  final ExportIntegrity? integrity;

  /// The runs are sandboxed: the sandbox owns the temporary directory. Recorded
  /// on every result.
  final bool isolated;

  /// Where the per-run temporary directories are made without a sandbox
  /// (outside the export).
  final String tempParent;

  /// One test-tool run. Without a sandbox it gets its own `TMPDIR` (also
  /// `TMP`, `TEMP`: what `Directory.systemTemp` follows), created before and
  /// deleted after; with one, `/tmp` is a fresh tmpfs already. With an
  /// [integrity] check the host export must be [before] (the view taken just
  /// before the run) when it is over: [during] names the run in the error.
  Future<ProcessOutcome> _exec(
    List<String> argv, {
    required AuditConfig config,
    required String root,
    required String during,
    CancelToken? cancel,
    ExportView? before,
  }) async {
    final tmp = isolated ? null : Directory(tempParent).createTempSync('mutaudit_run_');
    final ProcessOutcome outcome;
    try {
      outcome = await runner.run(
        argv,
        workingDirectory: root,
        timeout: config.timeout,
        environment: {
          ...config.env,
          if (tmp != null) ...{'TMPDIR': tmp.path, 'TMP': tmp.path, 'TEMP': tmp.path},
        },
        cancel: cancel,
      );
    } finally {
      try {
        if (tmp != null && tmp.existsSync()) tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // unique to this run: leftovers here cannot reach another run
      }
    }
    if (outcome.cleanupFailed) {
      throw CleanupFailedError('${argv.join(' ')} left processes that SIGKILL did not remove '
          '(${outcome.survivors.join(', ')}); a later run could not be told apart from them');
    }
    final check = integrity;
    if (check != null && !outcome.cancelled && !(cancel?.isCancelled ?? false)) {
      if (!isolated) {
        // Unsandboxed runs may leave files; they may not move the audited commit.
        await check.requirePinned('after $during');
      } else if (before != null) {
        await check.verifyUnchanged(before, during: during);
      }
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
        config: config,
        root: root,
        cancel: cancel,
        during: 'the baseline run',
        before: isolated ? await integrity?.view() : null);
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
    final applier = applierFor(root);
    final matcher = guards ?? GuardMatcher(config.guardPatterns);
    final flaky = config.flakyTests.toSet();
    final results = <MutantResult>[];

    for (final mutant in mutants) {
      if (cancel != null && cancel.isCancelled) throw InterruptedError();
      final applied = await applier.apply(mutant);
      late final Classification classification;
      late final Duration elapsed;
      try {
        // The reference for this mutant's runs: the export with the mutant applied.
        final before = isolated ? await integrity?.view(mutatedFile: mutant.file) : null;
        Future<ProcessOutcome> alone(TestOutcome failed) => _exec(
              buildTestCommand(config.testCmd, tests: [failed.suite], fullName: failed.name),
              config: config,
              root: root,
              cancel: cancel,
              during: 'the rerun of ${failed.key} for mutant ${mutant.id}',
              before: before,
            );
        final outcome = await _exec(buildTestCommand(config.testCmd, tests: config.tests),
            config: config, root: root, cancel: cancel, during: 'the run of mutant ${mutant.id}', before: before);
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
      results.add(MutantResult(
          mutant: mutant, classification: classification, duration: elapsed, isolated: isolated));
    }
    if (cancel != null && cancel.isCancelled) throw InterruptedError();
    return (baseline: baseline, results: results);
  }
}
