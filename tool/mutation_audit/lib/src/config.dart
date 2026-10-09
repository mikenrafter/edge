import 'dart:io';

import 'package:args/args.dart';

import 'command.dart';

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
    this.noGuards = false,
    this.runtimeAllowlist,
    this.scanners = const [],
    this.allowOverrides = const [],
    this.flakyTests = const [],
    this.setupCmd,
    this.env = const {'TZ': 'UTC'},
    this.noSandbox = false,
    this.sandboxReadOnly = const [],
    this.setupLeaves = const [],
    this.heartbeat = const Duration(seconds: 60),
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

  /// `--no-guards`: the author states that no test of this suite scans source
  /// text, so none is classified as a guard.
  final bool noGuards;

  /// Path of the reviewed list of source-scanning-looking tests that run code.
  final String? runtimeAllowlist;

  /// Extra shared source scanner modules (globs, root-relative).
  final List<String> scanners;

  /// `detected`: suites that match a pattern, import a shared scanner or read
  /// files under `lib/` are source guards, whatever `--tests` selected;
  /// `no-guards-asserted`: `--no-guards`, accepted only because nothing was
  /// detected. Recorded in the report.
  String get guardPolicy => noGuards ? 'no-guards-asserted' : 'detected';

  /// Test keys (`suite::name`) known to be flaky: failures are re-run alone.
  final List<String> flakyTests;

  /// Run once in the export before the baseline (a fresh export has no package
  /// config). Null: `flutter pub get` / `dart pub get`, as the repository
  /// needs. An empty string: no setup.
  final String? setupCmd;

  /// Environment for every child process (setup, baseline, mutants), on top of
  /// the parent's. Default `TZ=UTC`: the tests of both repos assume it.
  final Map<String, String> env;

  /// `--no-sandbox`: run the tests directly. Nothing then separates one run
  /// from the next; the report says `isolation: none` and every kill is
  /// `unisolated`.
  final bool noSandbox;

  /// Root-relative paths (globs) that setup may leave in the export without
  /// being committed or ignored (`pubspec.lock` in a project that does not
  /// track it), on top of `.dart_tool`, `build`, `.flutter-plugins*` and
  /// `.packages`. They are exempt from the "export is clean after setup" check.
  final List<String> setupLeaves;

  /// Extra host paths the sandboxed toolchain may read (mounted read-only at
  /// the same path). The root of the sandbox is minimal: only these, the
  /// base system, the pub cache, `FLUTTER_ROOT`, `PATH` entries and the package
  /// config roots are there.
  final List<String> sandboxReadOnly;

  /// How often a child run in progress prints a "still running" line to stderr
  /// (`--heartbeat <seconds>`); zero turns the heartbeat off.
  final Duration heartbeat;

  /// Where results.json and summary.md go (never inside the export).
  final String outDir;
}

/// Parses the command line:
///
/// `--repo <path> --sha <rev> --files <glob>... --test-cmd "<cmd>"
/// [--tests <file>...] [--max-mutants N] [--sample N --seed S]
/// [--timeout seconds] [--guard-pattern <glob>... | --no-guards]
/// [--allow-override <path>...]
/// [--flaky-test <key>...] [--setup-cmd "<cmd>"] [--env KEY=VALUE...]
/// [--no-sandbox] [--sandbox-ro <path>...] [--heartbeat seconds]
/// --out <dir>`
///
/// `--files`, `--tests`, `--guard-pattern`, `--allow-override`, `--flaky-test`
/// and `--env` may repeat; the first four also take comma-separated lists
/// (commas inside `{...}` of a glob do not split). `--env` adds to (and may
/// replace) the default `TZ=UTC`. `--test-cmd`
/// defaults to `defaultTestCommand(repo)`. Throws [UsageError] for a missing
/// required option, a non-integer or negative number, `--sample` without
/// `--seed`, a timeout under 1, or an unknown option.
AuditConfig parseAuditArgs(List<String> args) {
  final ArgResults r;
  try {
    r = _parser().parse(_spreadVariadic(args));
  } on FormatException catch (e) {
    throw UsageError(e.message);
  }
  if (r.rest.isNotEmpty) throw UsageError('unexpected argument: ${r.rest.first}');

  String need(String name) {
    final v = r[name] as String?;
    if (v == null || v.isEmpty) throw UsageError('missing required option --$name');
    return v;
  }

  int? number(String name, {int min = 0}) {
    final v = r[name] as String?;
    if (v == null) return null;
    final n = int.tryParse(v);
    if (n == null || n < min) throw UsageError('--$name must be an integer >= $min, got "$v"');
    return n;
  }

  List<String> list(String name) => [
        for (final v in r[name] as List<String>) ..._splitTopLevel(v),
      ];

  final repo = need('repo');
  final sha = need('sha');
  final outDir = need('out');
  final files = list('files');
  if (files.isEmpty) throw UsageError('missing required option --files');
  if (!Directory(repo).existsSync()) throw UsageError('--repo $repo is not a directory');
  final sample = number('sample');
  final seed = number('seed', min: -(1 << 62));
  if (sample != null && seed == null) throw UsageError('--sample needs --seed');
  final env = {'TZ': 'UTC'};
  for (final pair in r['env'] as List<String>) {
    final at = pair.indexOf('=');
    if (at <= 0) throw UsageError('--env wants KEY=VALUE, got "$pair"');
    env[pair.substring(0, at)] = pair.substring(at + 1);
  }
  final guardPatterns = list('guard-pattern');
  final noGuards = r['no-guards'] as bool;
  if (noGuards && guardPatterns.isNotEmpty) {
    throw UsageError('--no-guards contradicts --guard-pattern: pick one');
  }
  final tests = list('tests');
  final allowlist = r['runtime-allowlist'] as String?;
  if (noGuards && allowlist != null) {
    throw UsageError('--no-guards contradicts --runtime-allowlist: pick one');
  }
  if (allowlist != null && !File(allowlist).existsSync()) {
    throw UsageError('--runtime-allowlist $allowlist is not a file');
  }
  return AuditConfig(
    repo: repo,
    sha: sha,
    files: files,
    testCmd: (r['test-cmd'] as String?) ?? defaultTestCommand(repo),
    outDir: outDir,
    tests: tests,
    maxMutants: number('max-mutants'),
    sample: sample,
    seed: seed,
    timeout: Duration(seconds: number('timeout', min: 1) ?? 300),
    guardPatterns: guardPatterns,
    noGuards: noGuards,
    runtimeAllowlist: allowlist,
    scanners: list('scanner'),
    allowOverrides: list('allow-override'),
    flakyTests: r['flaky-test'] as List<String>,
    setupCmd: r['setup-cmd'] as String?,
    env: env,
    noSandbox: r['no-sandbox'] as bool,
    sandboxReadOnly: list('sandbox-ro'),
    setupLeaves: list('setup-leaves'),
    heartbeat: Duration(seconds: number('heartbeat') ?? 60),
  );
}

ArgParser _parser() => ArgParser()
  ..addOption('repo', help: 'The developer repository (never modified).')
  ..addOption('sha', help: 'The commit to audit (anything git resolves).')
  ..addMultiOption('files',
      splitCommas: false, help: 'Globs of the files to mutate, relative to the repo root.')
  ..addOption('test-cmd',
      help: 'The test command (default: flutter test / dart test with --reporter json).')
  ..addMultiOption('tests', splitCommas: false, help: 'Test files to run instead of the whole suite.')
  ..addOption('max-mutants', help: 'Run at most this many mutants (the first ones).')
  ..addOption('sample', help: 'Draw this many mutants at random (needs --seed).')
  ..addOption('seed', help: 'Seed for --sample.')
  ..addOption('timeout', help: 'Per-run timeout in seconds (default 300).')
  ..addMultiOption('guard-pattern',
      splitCommas: false, help: 'Globs of source-guard tests; their failures are not kills.')
  ..addFlag('no-guards',
      negatable: false,
      help: 'Assert that no suite scans source text (checked against the export; refused if one does).')
  ..addOption('runtime-allowlist',
      help: 'File of reviewed tests that run code although their suite scans source: '
          'one "suite" or "suite::full test name" per line.')
  ..addMultiOption('scanner',
      splitCommas: false, help: 'Extra shared source scanner modules (globs, repo-relative).')
  ..addMultiOption('allow-override',
      splitCommas: false, help: 'A path override that may stay (the audited sibling).')
  ..addMultiOption('flaky-test', splitCommas: false, help: 'A test key suite::name to re-run when it fails.')
  ..addOption('setup-cmd', help: 'Run once in the export before the baseline ("" for none).')
  ..addMultiOption('env', splitCommas: false, help: 'KEY=VALUE for child processes (default TZ=UTC).')
  ..addFlag('no-sandbox',
      negatable: false,
      help: 'Run the tests directly, without bubblewrap. Nothing then separates one run from the next: '
          'the report says isolation none and every kill is unisolated.')
  ..addMultiOption('setup-leaves',
      splitCommas: false,
      help: 'A path (glob, repo-relative) that setup may leave untracked or changed in the export, besides '
          '.dart_tool, build, .flutter-plugins*, .packages (e.g. pubspec.lock when the project does not commit it).')
  ..addMultiOption('sandbox-ro',
      splitCommas: false,
      help: 'A host path the sandboxed toolchain must read (mounted read-only at the same path; the sandbox root is '
          'minimal). The base system, the pub cache, FLUTTER_ROOT, PATH entries and the package config roots are '
          'found by themselves.')
  ..addOption('heartbeat',
      help: 'Seconds between "still running" lines on stderr while a child run is in progress (default 60, 0 = off).')
  ..addOption('out', help: 'Directory for results.json and summary.md (outside the export).');

/// `--files a b c` means `--files a --files b --files c`: the list options take
/// every following word up to the next option.
const _variadic = {
  '--files', '--tests', '--guard-pattern', '--scanner', '--allow-override', '--flaky-test', '--env', '--sandbox-ro', '--setup-leaves',
};

List<String> _spreadVariadic(List<String> args) {
  final out = <String>[];
  String? open;
  for (final a in args) {
    if (a.startsWith('--')) {
      open = _variadic.contains(a) ? a : null;
      out.add(a);
    } else if (open != null && out.isNotEmpty && !out.last.startsWith('--')) {
      out..add(open)..add(a);
    } else {
      out.add(a);
    }
  }
  return out;
}

/// Splits on commas that are not inside `{...}`.
List<String> _splitTopLevel(String value) {
  final out = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    if (c == '{') depth++;
    if (c == '}' && depth > 0) depth--;
    if (c == ',' && depth == 0) {
      out.add(value.substring(start, i));
      start = i + 1;
    }
  }
  out.add(value.substring(start));
  return [for (final v in out) if (v.trim().isNotEmpty) v.trim()];
}

/// The usage text.
String auditUsage() => 'Usage: dart run mutation_audit --repo <path> --sha <rev> '
    '--files <glob>... --out <dir> [options]\n\n${_parser().usage}';
