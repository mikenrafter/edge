import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

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
    this.env = const {},
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

  /// The environment given to child processes (on top of the parent's).
  final Map<String, String> env;
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
  /// `killingTests` (keys), `killers` (`test`, `kind`: assertion | exception), `guardTests`, `reruns` (`test`, `confirmed`: failed again alone, `result`: failed-again | passed-alone | unresolved, `detail`),
  /// `durationMs`, `detail`.
  Map<String, Object?> toJson() => {
        'meta': {
          'toolVersion': meta.toolVersion,
          'repo': meta.repo,
          'sha': meta.sha,
          'dependencies': meta.dependencies.toJson(),
          'testCmd': meta.testCmd,
          'env': meta.env,
          'files': meta.files,
          'tests': meta.tests,
          'guardPatterns': meta.guardPatterns,
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
                for (final k in r.classification.killers) {'test': k.key, 'kind': k.kind.id}
              ],
              'guardTests': r.classification.guardTests,
              'reruns': [
                for (final x in r.classification.reruns)
                  {'test': x.testKey, 'confirmed': x.confirmed, 'result': x.result.id, 'detail': x.detail}
              ],
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
      ..writeln('- Baseline: ${meta.baseline.passed ? 'passed' : 'FAILED'}, '
          '${meta.baseline.testsRun} tests, ${_seconds(meta.baseline.duration)}')
      ..writeln('- Mutants: ${meta.candidateMutants} candidates, ${results.length} run '
          '(max ${meta.maxMutants ?? 'unbounded'}, sample ${meta.sample ?? 'none'}, seed ${meta.seed ?? 'none'})')
      ..writeln('- Timeout: ${meta.timeoutSeconds} s per run; environment ${_env(meta.env)}')
      ..writeln('- Started ${meta.startedAt.toUtc().toIso8601String()}, '
          'finished ${meta.finishedAt.toUtc().toIso8601String()}')
      ..writeln('- Dependencies: pubspec.lock `${meta.dependencies.lockSha256 ?? 'absent'}`, '
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
        final extra = killers
            ? [for (final k in c.killers) '${k.key} (${k.kind.id})'].join('<br>')
            : tests
            ? c.guardTests.join('<br>')
            : [
                if (c.detail.isNotEmpty) c.detail,
                for (final x in c.reruns)
                  'rerun ${x.testKey}: ${switch (x.result) {
                    RerunResult.failedAgain => 'failed again',
                    RerunResult.passedAlone => 'passed alone',
                    RerunResult.unresolved => 'not confirmed (${x.detail})',
                  }}',
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

String _seconds(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';

String _env(Map<String, String> env) =>
    env.isEmpty ? 'inherited' : env.entries.map((e) => '`${e.key}=${e.value}`').join(' ');

/// A table cell: pipes and newlines would break the row.
String _cell(String text) => text.replaceAll('|', r'\|').replaceAll('\n', ' ');

/// Writes `results.json` and `summary.md` into [outDir] (created if needed).
/// Throws [ArgumentError] when [outDir] is, or is inside, [exportPath]: the
/// export is disposable. Returns the two paths.
Future<({String json, String markdown})> writeResults(
  AuditResults results, {
  required String outDir,
  required String exportPath,
}) async {
  final out = p.normalize(p.absolute(outDir));
  final export = p.normalize(p.absolute(exportPath));
  if (p.equals(out, export) || p.isWithin(export, out)) {
    throw ArgumentError.value(outDir, 'outDir', 'must be outside the disposable export $exportPath');
  }
  await Directory(out).create(recursive: true);
  final jsonPath = p.join(out, 'results.json');
  final markdownPath = p.join(out, 'summary.md');
  await File(jsonPath).writeAsString('${const JsonEncoder.withIndent('  ').convert(results.toJson())}\n');
  await File(markdownPath).writeAsString(results.renderMarkdown());
  return (json: jsonPath, markdown: markdownPath);
}
