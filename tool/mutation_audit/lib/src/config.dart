/// A command line that cannot be run (missing or malformed option).
class UsageError implements Exception {
  UsageError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Everything one audit run is told.
class AuditConfig {
  const AuditConfig({
    required this.repo,
    required this.sha,
    required this.files,
    required this.testCmd,
    required this.outDir,
    this.tests = const [],
    this.maxMutants,
    this.sample,
    this.seed,
    this.timeout = const Duration(seconds: 300),
    this.guardPatterns = const [],
    this.allowOverrides = const [],
    this.flakyTests = const [],
    this.setupCmd,
  });

  /// The developer repository and the pinned commit to audit.
  final String repo, sha;

  /// Globs (relative to the repository root) of the files to mutate.
  final List<String> files;
  final String testCmd;

  /// Test files to run instead of the whole suite (empty: the whole suite).
  final List<String> tests;
  final int? maxMutants, sample, seed;

  /// Per-mutant timeout (the baseline gets the same).
  final Duration timeout;
  final List<String> guardPatterns, allowOverrides;

  /// Test keys (`suite::name`) known to be flaky: failures are re-run alone.
  final List<String> flakyTests;

  /// Run once in the export before the baseline (a fresh export has no package
  /// config). Null: `flutter pub get` / `dart pub get`, as the repository
  /// needs. An empty string: no setup.
  final String? setupCmd;

  /// Where results.json and summary.md go (never inside the export).
  final String outDir;
}

/// Parses the command line:
///
/// `--repo <path> --sha <rev> --files <glob>... --test-cmd "<cmd>"
/// [--tests <file>...] [--max-mutants N] [--sample N --seed S]
/// [--timeout seconds] [--guard-pattern <glob>...] [--allow-override <path>...]
/// [--flaky-test <key>...] [--setup-cmd "<cmd>"] --out <dir>`
///
/// `--files`, `--tests`, `--guard-pattern`, `--allow-override` and
/// `--flaky-test` may repeat and take comma-separated lists. `--test-cmd`
/// defaults to `defaultTestCommand(repo)`. Throws [UsageError] for a missing
/// required option, a non-integer or negative number, `--sample` without
/// `--seed`, a timeout under 1, or an unknown option.
AuditConfig parseAuditArgs(List<String> args) =>
    throw UnimplementedError('parseAuditArgs');

/// The usage text.
String auditUsage() => throw UnimplementedError('auditUsage');
