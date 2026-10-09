import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'classifier.dart';
import 'export.dart';
import 'guards.dart';
import 'mutant.dart';
import 'process_runner.dart';

/// The verdict on one mutant, with the evidence.
class MutantResult {
  const MutantResult({
    required this.mutant,
    required this.classification,
    required this.duration,
    this.isolated = false,
  });

  /// The runs of this mutant were sandboxed. A kill with this false is
  /// `unisolated`: whatever an earlier run left could have caused it.
  final bool isolated;
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

/// How the test runs were isolated.
class IsolationInfo {
  const IsolationInfo({required this.mode, this.network = false, this.readOnlyUnderHome = const [], this.bwrap});

  /// `--no-sandbox`: nothing separates one run from the next, so every kill is
  /// `unisolated` (something an earlier run left could have caused it).
  const IsolationInfo.none()
      : mode = 'none',
        network = true,
        readOnlyUnderHome = const [],
        bwrap = null;

  /// `bubblewrap` or `none`.
  final String mode;

  /// The runs could reach the network.
  final bool network;

  /// Host paths under `$HOME` the toolchain was given read-only.
  final List<String> readOnlyUnderHome;

  /// `bwrap --version`, when known.
  final String? bwrap;

  bool get sandboxed => mode != 'none';

  Map<String, Object?> toJson() => {
        'mode': mode,
        'network': network,
        'readOnlyUnderHome': readOnlyUnderHome,
        'bwrap': bwrap,
      };
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
    this.env = const {},
    this.guardPolicy = 'unspecified',
    this.guards,
    this.dependenciesBeforeSetup,
    this.isolation = const IsolationInfo.none(),
  });

  /// How the runs were isolated from each other.
  final IsolationInfo isolation;
  final String toolVersion, repo, sha, testCmd;

  /// What the export resolved its dependencies from AFTER the setup command
  /// (the lock Pub wrote, the package config it resolved), and what the pinned
  /// commit carried BEFORE it. Both were checked against the override policy.
  final DependencyConfig dependencies;
  final DependencyConfig? dependenciesBeforeSetup;
  final List<String> files, tests, guardPatterns;
  final int timeoutSeconds;
  final int? maxMutants, sample, seed;
  final BaselineSummary baseline;
  final DateTime startedAt, finishedAt;

  /// Mutants generated before sampling / capping.
  final int candidateMutants;

  /// The environment given to child processes (on top of the parent's).
  final Map<String, String> env;

  /// `patterns`, `none-declared` or `subset` (see [AuditConfig.guardPolicy]).
  final String guardPolicy;

  /// What was detected and what was allowlisted (null: not recorded).
  final GuardReport? guards;
}

/// The whole result of one audit.
class AuditResults {
  const AuditResults(this.meta, this.results);
  final AuditMeta meta;
  final List<MutantResult> results;

  /// Mutants per status id (all statuses present, zero included).
  Map<String, int> get counts {
    final out = {for (final s in MutantStatus.values) s.id: 0};
    for (final r in results) {
      out.update(r.classification.status.id, (n) => n + 1);
    }
    return out;
  }

  /// killed / (killed + survived): compile-invalid, timeout, load-failure,
  /// skipped and guard-only mutants are outside the denominator. Null when the
  /// denominator is zero.
  double? get score {
    final c = counts;
    final killed = c[MutantStatus.killed.id]!, survived = c[MutantStatus.survived.id]!;
    return killed + survived == 0 ? null : killed / (killed + survived);
  }

  /// The JSON document: `meta` (SHAs, dependency config, command, options,
  /// baseline, times), `counts`, `score`, and `mutants`: per mutant `id`,
  /// `file`, `line`, `column`, `operator`, `original`, `mutated`, `status`,
  /// `killingTests` (keys), `killers` (`test`, `kind`: assertion | exception in the mutant run, `confirmedKind`: the same for the confirming rerun, null if none), `guardTests`, `reruns` (`test`, `confirmed`: failed again alone, `result`: failed-again | passed-alone | unresolved, `detail`), `frameworkTimeouts` (keys of tests the test framework timed out: not kills),
  /// `durationMs`, `detail`.
  Map<String, Object?> toJson() => {
        'meta': {
          'toolVersion': meta.toolVersion,
          'repo': meta.repo,
          'sha': meta.sha,
          'dependencies': meta.dependencies.toJson(),
          'dependenciesBeforeSetup': meta.dependenciesBeforeSetup?.toJson(),
          'testCmd': meta.testCmd,
          'env': meta.env,
          'files': meta.files,
          'tests': meta.tests,
          'guardPatterns': meta.guardPatterns,
          'isolation': meta.isolation.toJson(),
          'guardPolicy': meta.guardPolicy,
          'guards': meta.guards?.toJson(),
          'timeoutSeconds': meta.timeoutSeconds,
          'maxMutants': meta.maxMutants,
          'sample': meta.sample,
          'seed': meta.seed,
          'candidateMutants': meta.candidateMutants,
          'baseline': {
            'passed': meta.baseline.passed,
            'testsRun': meta.baseline.testsRun,
            'durationMs': meta.baseline.duration.inMilliseconds,
          },
          'startedAt': meta.startedAt.toUtc().toIso8601String(),
          'finishedAt': meta.finishedAt.toUtc().toIso8601String(),
        },
        'counts': counts,
        'score': score,
        'mutants': [
          for (final r in results)
            {
              ...r.mutant.toJson(),
              'status': r.classification.status.id,
              'killingTests': r.classification.killingTests,
              'killers': [
                for (final k in r.classification.killers) {'test': k.key, 'kind': k.kind.id, 'confirmedKind': k.confirmedKind?.id}
              ],
              'guardTests': r.classification.guardTests,
              'discounted': [
                for (final d in r.classification.discounted) {'test': d.key, 'reasons': d.reasons}
              ],
              'reruns': [
                for (final x in r.classification.reruns)
                  {
                    'test': x.testKey,
                    'confirmed': x.confirmed,
                    'result': x.result.id,
                    'kind': x.kind?.id,
                    'detail': x.detail
                  }
              ],
              'frameworkTimeouts': r.classification.frameworkTimeouts,
              'unisolated': !r.isolated,
              'durationMs': r.duration.inMilliseconds,
              'detail': r.classification.detail,
            },
        ],
      };

  /// The Markdown summary: header with SHAs and command, a counts table by
  /// status, the score, then killed (with the kind of each killing test), survivors, killed-by-guard-only, compile-invalid,
  /// timeout, load-failure and unconfirmed (a failure whose rerun did not
  /// confirm it) mutants as tables (file:line, operator, change),
  /// and per file killed/survived counts. The score is a percentage with one
  /// decimal (`50.0%`), or the words `no score` when it is undefined.
  /// Section headings: `## Killed`, `## Survivors`, `## Killed by guards only`,
  /// `## Compile-invalid`, `## Timeouts`, `## Load failures`, `## Unconfirmed`, `## By file`.
  String renderMarkdown() {
    final b = StringBuffer();
    final s = score;
    b
      ..writeln('# Mutation audit')
      ..writeln()
      ..writeln('- Commit: `${meta.sha}` of `${meta.repo}`')
      ..writeln('- Command: `${meta.testCmd}`'
          '${meta.tests.isEmpty ? '' : ' on ${meta.tests.map((t) => '`$t`').join(', ')}'}')
      ..writeln('- Files: ${meta.files.map((f) => '`$f`').join(', ')}')
      ..writeln('- Source guards: ${meta.guardPolicy}'
          '${meta.guardPatterns.isEmpty ? '' : ' (${meta.guardPatterns.map((g) => '`$g`').join(', ')})'}')
      ..writeln(_guardLine(meta.guards))
      ..writeln('- Baseline: ${meta.baseline.passed ? 'passed' : 'FAILED'}, '
          '${meta.baseline.testsRun} tests, ${_seconds(meta.baseline.duration)}')
      ..writeln('- Mutants: ${meta.candidateMutants} candidates, ${results.length} run '
          '(max ${meta.maxMutants ?? 'unbounded'}, sample ${meta.sample ?? 'none'}, seed ${meta.seed ?? 'none'})')
      ..writeln('- Timeout: ${meta.timeoutSeconds} s per run; environment ${_env(meta.env)}')
      ..writeln(_isolationLine(meta.isolation))
      ..writeln('- Started ${meta.startedAt.toUtc().toIso8601String()}, '
          'finished ${meta.finishedAt.toUtc().toIso8601String()}')
      ..writeln('- Dependencies (after setup): pubspec.lock `${meta.dependencies.lockSha256 ?? 'absent'}`, '
          'package_config.json `${meta.dependencies.packageConfigSha256 ?? 'absent'}`, '
          'pubspec_overrides.yaml `${meta.dependencies.overridesFileSha256 ?? 'absent'}`');
    for (final g in meta.dependencies.gitDependencies) {
      b.writeln('  - git `${g.package}` `${g.url}` at `${g.resolvedRef}`');
    }
    for (final o in meta.dependencies.pathOverrides) {
      b.writeln('  - path override (${o.source}) `${o.package}` -> `${o.path}`'
          '${o.resolvedPath == null ? '' : ', resolved `${o.resolvedPath}`'}'
          ', ${o.gitHead == null ? 'git state unknown' : 'HEAD `${o.gitHead}`, ${o.dirty == true ? 'DIRTY' : 'clean'}'}');
    }
    b
      ..writeln('- Score: ${s == null ? 'no score' : '${(s * 100).toStringAsFixed(1)}%'} '
          '(killed / (killed + survived))')
      ..writeln()
      ..writeln('## Counts')
      ..writeln()
      ..writeln('| status | mutants |')
      ..writeln('|---|---|');
    counts.forEach((status, n) => b.writeln('| $status | $n |'));

    void section(String title, MutantStatus status, {bool tests = false, bool killers = false}) {
      b
        ..writeln()
        ..writeln('## $title')
        ..writeln();
      final rows = results.where((r) => r.classification.status == status).toList();
      if (rows.isEmpty) {
        b.writeln('None.');
        return;
      }
      b
        ..writeln('| location | operator | change | ${tests || killers ? 'tests' : 'detail'} |')
        ..writeln('|---|---|---|---|');
      for (final r in rows) {
        final m = r.mutant;
        final c = r.classification;
        String why(DiscountedFailure d) => '${d.key} (${d.reasons.join('; ')})';
        final extra = killers
            ? [
                if (!r.isolated) 'unisolated',
                for (final k in c.killers)
                  '${k.key} (${k.kind.id}${k.confirmedKind == null ? '' : '; rerun: ${k.confirmedKind!.id}'})',
                for (final d in c.discounted) 'discounted: ${why(d)}',
                for (final t in c.frameworkTimeouts) 'timed out by the test framework (not a kill): $t',
              ].join('<br>')
            : tests
            ? [
                for (final d in c.discounted) why(d),
                for (final t in c.frameworkTimeouts) 'timed out by the test framework (not a kill): $t',
              ].join('<br>')
            : [
                if (c.detail.isNotEmpty) c.detail,
                for (final x in c.reruns)
                  'rerun ${x.testKey}: ${switch (x.result) {
                    RerunResult.failedAgain => 'failed again',
                    RerunResult.passedAlone => 'passed alone',
                    RerunResult.unresolved => 'not confirmed (${x.detail})',
                  }}',
                for (final t in c.frameworkTimeouts) 'timed out by the test framework (not a kill): $t',
              ].join('<br>');
        b.writeln('| ${m.file}:${m.line} | ${m.operator.id} | `${_cell(m.original)}` -> `${_cell(m.mutated)}` '
            '| ${_cell(extra)} |');
      }
    }

    section('Killed', MutantStatus.killed, killers: true);
    section('Survivors', MutantStatus.survived);
    section('Killed by guards only', MutantStatus.killedByGuardOnly, tests: true);
    section('Compile-invalid', MutantStatus.compileInvalid);
    section('Timeouts', MutantStatus.timeout);
    section('Load failures', MutantStatus.loadFailure);
    section('Unconfirmed', MutantStatus.unconfirmed);

    b
      ..writeln()
      ..writeln('## By file')
      ..writeln()
      ..writeln('| file | killed | survived | other |')
      ..writeln('|---|---|---|---|');
    final files = {for (final r in results) r.mutant.file}.toList()..sort();
    for (final f in files) {
      final mine = results.where((r) => r.mutant.file == f);
      int n(bool Function(MutantStatus) test) => mine.where((r) => test(r.classification.status)).length;
      final killed = n((s) => s == MutantStatus.killed);
      final survived = n((s) => s == MutantStatus.survived);
      b.writeln('| $f | $killed | $survived | ${mine.length - killed - survived} |');
    }
    return b.toString();
  }
}

String _isolationLine(IsolationInfo i) => i.sandboxed
    ? '- Isolation: ${i.mode}${i.bwrap == null ? '' : ' (${i.bwrap})'}: every run in its own sandbox (read-only host, '
        'overlay export discarded after the run, fresh /tmp and HOME, own pid namespace'
        '${i.network ? '' : ', no network'}); read-only under HOME: '
        '${i.readOnlyUnderHome.isEmpty ? 'nothing' : i.readOnlyUnderHome.map((c) => '`$c`').join(', ')}'
    : '- Isolation: NONE (--no-sandbox): nothing separates one run from the next, so every kill is unisolated '
        '(an earlier run could have left the state that made a test fail)';

String _guardLine(GuardReport? g) {
  if (g == null) return '- Source-scanning suites: not recorded';
  final allow = g.allowlistPath == null
      ? 'no runtime allowlist'
      : 'runtime allowlist `${g.allowlistPath}` (${g.allowlistEntries} entries, sha256 `${g.allowlistSha256}`)'
          '${g.allowlistUnknownSuites.isEmpty ? '' : ', entries naming suites not in the export: ${g.allowlistUnknownSuites.map((s) => '`$s`').join(', ')}'}';
  return '- Source-scanning suites: ${g.sourceScanning.length} of ${g.effectiveSuites.length} suites '
      '(failures there are never kills; the list and the reasons are in results.json); $allow'
      '${g.allowlistOverrides.isEmpty ? '' : '\n  - Allowlist overrides (reviewed, counted as runtime):\n${[
          for (final o in g.allowlistOverrides) '    - `${o.entry}`: ${o.reason} (flagged: ${o.flags.first}${o.flags.length > 1 ? ' and ${o.flags.length - 1} more' : ''})'
        ].join('\n')}'}'
      '${g.allowlistUnflagged.isEmpty ? '' : '\n  - Allowlist entries that free nothing (not flagged): ${g.allowlistUnflagged.map((s) => '`$s`').join(', ')}'}';
}

String _seconds(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';

String _env(Map<String, String> env) =>
    env.isEmpty ? 'inherited' : env.entries.map((e) => '`${e.key}=${e.value}`').join(' ');

/// A table cell: pipes and newlines would break the row.
String _cell(String text) => text.replaceAll('|', r'\|').replaceAll('\n', ' ');

/// Results written as `*.tmp` files inside the output directory, waiting to be
/// published. [publish] renames them into place (they are beside their targets,
/// so the rename stays on one file system); [discard] removes whatever is left.
/// Nothing earlier in the directory is touched until [publish].
class StagedResults {
  StagedResults._(this.json, this.markdown, this._tmpJson, this._tmpMarkdown);

  /// Where the two files will be after [publish].
  final String json, markdown;
  final File _tmpJson, _tmpMarkdown;

  /// Renames the temporaries over the targets (nothing awaits between the two
  /// renames). Call [discard] afterwards in a `finally`.
  void publish() {
    _tmpJson.renameSync(json);
    _tmpMarkdown.renameSync(markdown);
  }

  /// Removes the temporaries that are still there (all of them, unless
  /// [publish] ran).
  void discard() {
    for (final tmp in [_tmpJson, _tmpMarkdown]) {
      if (tmp.existsSync()) tmp.deleteSync();
    }
  }
}

/// Writes `results.json.tmp` and `summary.md.tmp` into [outDir] (created if
/// needed) without publishing them. Throws [ArgumentError] when [outDir] is, or
/// is inside, [exportPath]: the export is disposable. Throws
/// [InterruptedError] when [cancel] has fired; on any failure the temporaries
/// written so far are removed. An earlier pair in [outDir] is not touched.
Future<StagedResults> stageResults(
  AuditResults results, {
  required String outDir,
  required String exportPath,
  CancelToken? cancel,
}) async {
  final out = p.normalize(p.absolute(outDir));
  final export = p.normalize(p.absolute(exportPath));
  if (p.equals(out, export) || p.isWithin(export, out)) {
    throw ArgumentError.value(outDir, 'outDir', 'must be outside the disposable export $exportPath');
  }
  if (cancel != null && cancel.isCancelled) throw InterruptedError();
  await Directory(out).create(recursive: true);
  final jsonPath = p.join(out, 'results.json');
  final markdownPath = p.join(out, 'summary.md');
  final staged = StagedResults._(jsonPath, markdownPath, File('$jsonPath.tmp'), File('$markdownPath.tmp'));
  try {
    await staged._tmpJson.writeAsString('${const JsonEncoder.withIndent('  ').convert(results.toJson())}\n');
    await staged._tmpMarkdown.writeAsString(results.renderMarkdown());
  } catch (_) {
    staged.discard();
    rethrow;
  }
  return staged;
}

/// Stages and publishes at once: both files are written as `*.tmp` next to
/// their targets and renamed into place only if [cancel] has not fired by then;
/// otherwise the temporaries are removed and [InterruptedError] is thrown.
/// [afterTempFiles] is a test seam. (The command line does not use this: it
/// stages with [stageResults] and publishes after the export is removed.)
Future<({String json, String markdown})> writeResults(
  AuditResults results, {
  required String outDir,
  required String exportPath,
  CancelToken? cancel,
  Future<void> Function()? afterTempFiles,
}) async {
  final staged = await stageResults(results, outDir: outDir, exportPath: exportPath, cancel: cancel);
  try {
    await afterTempFiles?.call();
    if (cancel != null && cancel.isCancelled) throw InterruptedError();
    staged.publish();
  } finally {
    staged.discard();
  }
  return (json: staged.json, markdown: staged.markdown);
}
