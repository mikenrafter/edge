import 'classifier.dart';
import 'export.dart';
import 'mutant.dart';

/// The verdict on one mutant, with the evidence.
class MutantResult {
  const MutantResult({
    required this.mutant,
    required this.classification,
    required this.duration,
  });
  final Mutant mutant;
  final Classification classification;
  final Duration duration;
}

/// The unmutated baseline run.
class BaselineSummary {
  const BaselineSummary({
    required this.passed,
    required this.testsRun,
    required this.duration,
  });
  final bool passed;
  final int testsRun;
  final Duration duration;
}

/// Everything about the run that is not a mutant.
class AuditMeta {
  const AuditMeta({
    required this.toolVersion,
    required this.repo,
    required this.sha,
    required this.dependencies,
    required this.testCmd,
    required this.files,
    required this.tests,
    required this.guardPatterns,
    required this.timeoutSeconds,
    required this.maxMutants,
    required this.sample,
    required this.seed,
    required this.baseline,
    required this.startedAt,
    required this.finishedAt,
    required this.candidateMutants,
  });
  final String toolVersion, repo, sha, testCmd;
  final DependencyConfig dependencies;
  final List<String> files, tests, guardPatterns;
  final int timeoutSeconds;
  final int? maxMutants, sample, seed;
  final BaselineSummary baseline;
  final DateTime startedAt, finishedAt;

  /// Mutants generated before sampling / capping.
  final int candidateMutants;
}

/// The whole result of one audit.
class AuditResults {
  const AuditResults(this.meta, this.results);
  final AuditMeta meta;
  final List<MutantResult> results;

  /// Mutants per status id (all statuses present, zero included).
  Map<String, int> get counts => throw UnimplementedError('AuditResults.counts');

  /// killed / (killed + survived): compile-invalid, timeout, load-failure,
  /// skipped and guard-only mutants are outside the denominator. Null when the
  /// denominator is zero.
  double? get score => throw UnimplementedError('AuditResults.score');

  /// The JSON document: `meta` (SHAs, dependency config, command, options,
  /// baseline, times), `counts`, `score`, and `mutants`: per mutant `id`,
  /// `file`, `line`, `column`, `operator`, `original`, `mutated`, `status`,
  /// `killingTests`, `guardTests`, `reruns` (`test`, `confirmed`),
  /// `durationMs`, `detail`.
  Map<String, Object?> toJson() => throw UnimplementedError('AuditResults.toJson');

  /// The Markdown summary: header with SHAs and command, a counts table by
  /// status, the score, then survivors, killed-by-guard-only, compile-invalid,
  /// timeout and load-failure mutants as tables (file:line, operator, change),
  /// and per file killed/survived counts. The score is a percentage with one
  /// decimal (`50.0%`), or the words `no score` when it is undefined.
  /// Section headings: `## Survivors`, `## Killed by guards only`,
  /// `## Compile-invalid`, `## Timeouts`, `## Load failures`, `## By file`.
  String renderMarkdown() => throw UnimplementedError('AuditResults.renderMarkdown');
}

/// Writes `results.json` and `summary.md` into [outDir] (created if needed).
/// Throws [ArgumentError] when [outDir] is, or is inside, [exportPath]: the
/// export is disposable. Returns the two paths.
Future<({String json, String markdown})> writeResults(
  AuditResults results, {
  required String outDir,
  required String exportPath,
}) =>
    throw UnimplementedError('writeResults');
