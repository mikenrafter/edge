import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'guards.dart';
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
  skipped('skipped'),

  /// A test failed, but the rerun that had to confirm the failure did not show
  /// it failing again (it timed out, did not load, did not run the test, ...).
  /// Not a kill, not a survivor: outside the score.
  unconfirmed('unconfirmed');

  const MutantStatus(this.id);
  final String id;
}

/// Decides which failing tests are source guards, whose failures never count
/// as kills. A test is a guard when its suite
///
/// - matches a [patterns] glob (against the suite path; a pattern without a
///   `/` matches the file name only; one with a `/` matches the path or any
///   suffix of it, so `test/guards/**` matches `/abs/repo/test/guards/a_test.dart`), or
/// - is source-scanning per [detector] (imports a shared scanner, reads
///   files under `lib/`),
///
/// unless the reviewed [allowlist] says that test runs code.
class GuardMatcher {
  GuardMatcher(this.patterns, {this.detector, this.allowlist = const RuntimeAllowlist.empty()})
      : _globs = [for (final pattern in patterns) (pattern.contains('/'), Glob(pattern, context: p.posix))];
  final List<String> patterns;
  final SourceScanDetector? detector;
  final RuntimeAllowlist allowlist;
  final List<(bool, Glob)> _globs;

  /// Why [test] is a guard (empty: it is a runtime test).
  List<String> reasons(TestOutcome test) {
    final out = flagReasons(test.suite);
    if (out.isEmpty || allowlist.allows(test)) return const [];
    return out;
  }

  /// Why the suite [suitePath] is flagged, patterns and detection, whatever
  /// the allowlist says (what an allowlist entry would be overriding).
  List<String> flagReasons(String suitePath) {
    final out = <String>[];
    final segments = suitePath.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty) {
      for (var n = 0; n < _globs.length; n++) {
        final (withSlash, glob) = _globs[n];
        final hit = !withSlash
            ? glob.matches(segments.last)
            // The path itself or any suffix of it (an absolute prefix is not
            // part of the pattern's business).
            : [for (var i = 0; i < segments.length; i++) segments.sublist(i).join('/')].any(glob.matches);
        if (hit) out.add('matches guard pattern ${patterns[n]}');
      }
    }
    out.addAll(detector?.reasons(suitePath) ?? const []);
    return out;
  }

  bool matches(TestOutcome test) => reasons(test).isNotEmpty;
}

/// Runs one failed test alone (same mutant, same working tree) and returns the
/// whole process outcome: exit status, timeout, reporter stream and all.
typedef SingleTestRunner = Future<ProcessOutcome> Function(TestOutcome failed);

/// What re-running an ambiguous failure alone showed.
enum RerunResult {
  /// The test ran alone and failed again, with an error event.
  failedAgain('failed-again'),

  /// The test ran alone, to the end of a complete run, and passed: flaky.
  passedAlone('passed-alone'),

  /// The rerun did not settle it (timeout, no load, test not run, incomplete).
  unresolved('unresolved');

  const RerunResult(this.id);
  final String id;
}

/// One rerun and what it showed.
class RerunRecord {
  const RerunRecord(this.testKey, {required this.result, this.detail = '', this.kind});
  final String testKey;
  final RerunResult result;

  /// How the test failed in the rerun (only for [RerunResult.failedAgain]).
  final FailureKind? kind;

  /// Why the rerun is [RerunResult.unresolved] (empty otherwise).
  final String detail;

  /// Only a repeated, attributable failure of this test confirms a kill.
  bool get confirmed => result == RerunResult.failedAgain;
}

/// How a killing test failed: an assertion (`TestFailure`, the reporter's
/// `failure` result) or any other exception (`error`). Both kill; the report
/// says which, because a crash is weaker evidence than a failed expectation.
enum FailureKind {
  assertion('assertion'),
  exception('exception');

  const FailureKind(this.id);
  final String id;
}

/// A confirmed failing non-guard test and how it failed.
class KillingTest {
  const KillingTest(this.key, this.kind, {this.confirmedKind});
  final String key;

  /// How it failed in the mutant run.
  final FailureKind kind;

  /// How it failed when re-run alone to confirm it; null when it was not re-run.
  final FailureKind? confirmedKind;
}

/// The verdict on one mutant run.
class Classification {
  const Classification({
    required this.status,
    this.killers = const [],
    this.discounted = const [],
    this.reruns = const [],
    this.frameworkTimeouts = const [],
    this.detail = '',
  });

  final MutantStatus status;

  /// The confirmed non-guard failures, in finish order, with their kind.
  final List<KillingTest> killers;

  /// Keys (`suite::name`) of [killers].
  List<String> get killingTests => [for (final k in killers) k.key];

  /// Confirmed failures that were NOT counted as kills because the test is a
  /// source guard, with the reasons.
  final List<DiscountedFailure> discounted;

  /// Keys of [discounted].
  List<String> get guardTests => [for (final d in discounted) d.key];
  final List<RerunRecord> reruns;

  /// Keys of tests that failed by the test framework's own timeout: evidence
  /// of a hang, never a kill and never a confirmation.
  final List<String> frameworkTimeouts;

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
///    (not attributable) is first re-run alone through [rerun] ([interpretRerun]):
///    a failure that passes alone is dropped (recorded); one that does not
///    demonstrably fail again (the rerun timed out, did not compile or load,
///    did not run the test, was incomplete, or there is no [rerun]) is
///    unresolved. Confirmed failures that match [guards] are guard failures,
///    the rest kill: any kill -> killed; otherwise any unresolved failure ->
///    unconfirmed; otherwise only guard failures -> killedByGuardOnly.
///    A test that failed by the test framework's own timeout
///    ([TestError.isFrameworkTimeout]) is neither a kill nor re-run: it goes
///    to [Classification.frameworkTimeouts]; a rerun that ends that way is
///    unresolved. If nothing else is left, the mutant is a timeout.
/// 4. load errors left (exception at load, missing file), or a failed
///    `setUpAll` / `tearDownAll` hook (the environment broke; hooks are never
///    tests, so never kills) -> loadFailure.
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
  final killing = <KillingTest>[];
  final guardFailures = <DiscountedFailure>[];
  final unresolved = <RerunRecord>[];
  final timeouts = <String>[];
  for (final t in failed) {
    if (t.hitFrameworkTimeout) {
      // The test hung past its Timeout: that says nothing about the mutant
      // being noticed, so it neither kills nor is worth re-running to confirm.
      timeouts.add(t.key);
      continue;
    }
    RerunRecord? record;
    final ambiguous = flakyTests.contains(t.key) || t.errors.isEmpty;
    if (ambiguous) {
      // A failure is a kill only when it is attributable (it carried an error
      // event) or when running that test alone shows it failing again. Not
      // being able to run it alone is not confirmation.
      record = rerun == null
          ? RerunRecord(t.key, result: RerunResult.unresolved, detail: 'no rerun available')
          : interpretRerun(await rerun(t), t, root: root);
      reruns.add(record);
      if (record.result == RerunResult.passedAlone) passedAfterRerun++;
      if (record.result == RerunResult.unresolved) unresolved.add(record);
      if (!record.confirmed) continue;
    }
    final why = guards?.reasons(t) ?? const <String>[];
    if (why.isNotEmpty) {
      guardFailures.add(DiscountedFailure(t.key, why));
    } else {
      killing.add(KillingTest(t.key, _kindOf(t), confirmedKind: record?.kind));
    }
  }
  if (killing.isNotEmpty) {
    return Classification(
      status: MutantStatus.killed,
      killers: killing,
      discounted: guardFailures,
      reruns: reruns,
      frameworkTimeouts: timeouts,
      detail: _firstLine(failed.firstWhere((t) => t.key == killing.first.key).errors),
    );
  }
  if (unresolved.isNotEmpty) {
    // A failure we could not confirm may be a kill or noise: not a kill, and
    // not a survivor or a guard-only result either.
    return Classification(
      status: MutantStatus.unconfirmed,
      discounted: guardFailures,
      reruns: reruns,
      frameworkTimeouts: timeouts,
      detail: '${unresolved.first.testKey}: ${unresolved.first.detail}',
    );
  }
  if (guardFailures.isNotEmpty) {
    return Classification(
        status: MutantStatus.killedByGuardOnly,
        discounted: guardFailures,
        reruns: reruns,
        frameworkTimeouts: timeouts);
  }
  if (timeouts.isNotEmpty) {
    // Every remaining failure is the test framework's own timeout.
    return Classification(
        status: MutantStatus.timeout,
        reruns: reruns,
        frameworkTimeouts: timeouts,
        detail: '${timeouts.first}: the test framework timed out the test'
            '${timeouts.length > 1 ? ' (and ${timeouts.length - 1} more)' : ''}');
  }

  if (run.loadErrors.isNotEmpty) {
    return Classification(
        status: MutantStatus.loadFailure,
        reruns: reruns,
        detail: _firstMessageLine(run.loadErrors.first.message));
  }
  if (run.setupFailures.isNotEmpty) {
    final f = run.setupFailures.first;
    return Classification(
        status: MutantStatus.loadFailure,
        reruns: reruns,
        detail: '${f.suite}: ${f.name} failed: ${_firstMessageLine(f.message)}');
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

/// What running [failed] alone ([again], the whole process outcome) shows.
///
/// - [RerunResult.failedAgain] only when the test ran (not skipped) and failed
///   with at least one error event, and the run did not time out or get
///   cancelled and nothing failed to compile or load;
/// - [RerunResult.passedAlone] only when it ran, passed, and the run was
///   complete (output read to the end, a successful `done` event);
/// - everything else is [RerunResult.unresolved], with the reason.
RerunRecord interpretRerun(ProcessOutcome again, TestOutcome failed, {String? root}) {
  RerunRecord unresolved(String why) =>
      RerunRecord(failed.key, result: RerunResult.unresolved, detail: why);
  if (again.cancelled) return unresolved('the rerun was cancelled');
  if (again.timedOut) return unresolved('the rerun timed out');
  final run = parseReporterStream(again.stdoutLines, root: root);
  for (final e in run.loadErrors) {
    return unresolved(_isCompileError(e.message)
        ? 'the rerun did not compile: ${_diagnostic(e.message)}'
        : 'the suite did not load in the rerun: ${_firstMessageLine(e.message)}');
  }
  if (run.setupFailures.isNotEmpty) {
    final f = run.setupFailures.first;
    return unresolved('${f.name} failed in the rerun: ${_firstMessageLine(f.message)}');
  }
  final same = [for (final t in run.tests) if (t.key == failed.key && !t.skipped) t];
  if (same.isEmpty) return unresolved('the test did not run in the rerun');
  final failedAgain = [
    for (final t in same)
      if (t.failed && t.errors.isNotEmpty && !t.hitFrameworkTimeout) t
  ];
  if (same.any((t) => t.failed)) {
    if (failedAgain.isNotEmpty) {
      return RerunRecord(failed.key, result: RerunResult.failedAgain, kind: _kindOf(failedAgain.first));
    }
    // A hang under the test framework's timeout is not the failure it had.
    return same.any((t) => t.hitFrameworkTimeout)
        ? unresolved('the test hit the test framework timeout in the rerun (a hang does not confirm a failure)')
        : unresolved('the test failed again without an error event');
  }
  if (!again.outputComplete || !run.sawDone || !run.doneSuccess) {
    return unresolved('the rerun passed but its output is incomplete '
        '(${!again.outputComplete ? 'output not read to the end' : 'no successful done event'})');
  }
  return RerunRecord(failed.key, result: RerunResult.passedAlone);
}

FailureKind _kindOf(TestOutcome t) =>
    t.result == TestResult.failure ? FailureKind.assertion : FailureKind.exception;

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
