import 'dart:convert';
import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/git_fixture.dart';

const sha = '0123456789abcdef0123456789abcdef01234567';

Mutant mutant(int line, String original, String mutated,
        {String file = 'lib/a.dart', MutationOperator op = MutationOperator.relational}) =>
    Mutant(
      id: '$file:${line * 10}:${op.id}:0000000$line',
      file: file,
      line: line,
      column: 5,
      byteOffset: line * 10,
      byteLength: original.length,
      operator: op,
      original: original,
      mutated: mutated,
    );

MutantResult result(Mutant m, MutantStatus s,
        {List<String> killing = const [],
        List<KillingTest>? killers,
        List<String> guard = const [],
        List<RerunRecord> reruns = const [],
        String detail = '',
        int ms = 100}) =>
    MutantResult(
      mutant: m,
      classification: Classification(
          status: s,
          killers: killers ?? [for (final k in killing) KillingTest(k, FailureKind.assertion)],
          guardTests: guard,
          reruns: reruns,
          detail: detail),
      duration: Duration(milliseconds: ms),
    );

AuditMeta meta() => AuditMeta(
      toolVersion: '0.1.0',
      repo: '/dev/edge',
      sha: sha,
      dependencies: DependencyConfig(
        lockSha256: 'ab' * 32,
        overridesFileSha256: null,
        pathOverrides: [],
        gitDependencies: const [GitDependency('analytics', 'https://github.com/OpenStrap/analytics', 'fedcba9876543210fedcba9876543210fedcba98')],
      ),
      testCmd: 'flutter test --reporter json',
      files: const ['lib/a.dart'],
      tests: const ['test/a_test.dart'],
      guardPatterns: const ['test/guards/**'],
      timeoutSeconds: 120,
      maxMutants: 50,
      sample: null,
      seed: null,
      baseline: const BaselineSummary(passed: true, testsRun: 12, duration: Duration(seconds: 3)),
      startedAt: DateTime.utc(2026, 10, 9, 8),
      finishedAt: DateTime.utc(2026, 10, 9, 8, 5),
      candidateMutants: 9,
    );

AuditResults sample() => AuditResults(meta(), [
      result(mutant(1, '<', '<='), MutantStatus.killed, killing: ['test/a_test.dart::lt boundary']),
      result(mutant(2, '>', '>='), MutantStatus.killed, killers: [
        const KillingTest('test/a_test.dart::gt boundary', FailureKind.exception),
        const KillingTest('test/b_test.dart::gt other', FailureKind.assertion, confirmedKind: FailureKind.exception),
      ]),
      result(mutant(3, '==', '!='), MutantStatus.survived),
      result(mutant(4, '&&', '||', op: MutationOperator.logical), MutantStatus.killedByGuardOnly,
          guard: ['test/guards/g_test.dart::no heavy calc']),
      result(mutant(5, '<', '<='), MutantStatus.compileInvalid, detail: 'lib/a.dart:5:9: Error: nope'),
      result(mutant(6, '<', '<='), MutantStatus.timeout),
      result(mutant(7, '<', '<='), MutantStatus.loadFailure, detail: 'Bad state: load time'),
      result(mutant(8, '<', '<='), MutantStatus.skipped),
      result(mutant(9, '>', '>='), MutantStatus.survived,
          reruns: [const RerunRecord('test/a_test.dart::flaky', result: RerunResult.passedAlone)]),
    ]);

void main() {
  group('counts and score', () {
    test('every status is present, zero included', () {
      expect(sample().counts, {
        'killed': 2,
        'killed-by-guard-only': 1,
        'survived': 2,
        'compile-invalid': 1,
        'timeout': 1,
        'load-failure': 1,
        'skipped': 1,
        'unconfirmed': 0,
      });
      expect(AuditResults(meta(), const []).counts.values, everyElement(0));
      expect(AuditResults(meta(), const []).counts.keys, MutantStatus.values.map((s) => s.id));
    });

    test('score is killed over killed plus survived, nothing else counted', () {
      expect(sample().score, closeTo(2 / 4, 1e-12));
    });

    test('no denominator, no score', () {
      expect(AuditResults(meta(), const []).score, isNull);
      expect(AuditResults(meta(), [result(mutant(1, '<', '<='), MutantStatus.timeout)]).score, isNull);
    });
  });

  group('JSON', () {
    late Map<String, Object?> json;
    setUp(() => json = (jsonDecode(jsonEncode(sample().toJson())) as Map).cast<String, Object?>());

    test('meta records the shas, dependency config, command and options', () {
      final m = (json['meta'] as Map).cast<String, Object?>();
      expect(m['sha'], sha);
      expect(m['repo'], '/dev/edge');
      expect(m['testCmd'], 'flutter test --reporter json');
      expect(m['files'], ['lib/a.dart']);
      expect(m['tests'], ['test/a_test.dart']);
      expect(m['guardPatterns'], ['test/guards/**']);
      expect(m['timeoutSeconds'], 120);
      expect(m['maxMutants'], 50);
      expect(m['sample'], isNull);
      expect(m['seed'], isNull);
      expect(m['candidateMutants'], 9);
      expect(m['startedAt'], '2026-10-09T08:00:00.000Z');
      expect(m['finishedAt'], '2026-10-09T08:05:00.000Z');
      final deps = (m['dependencies'] as Map).cast<String, Object?>();
      expect(deps['pubspecLockSha256'], 'ab' * 32);
      expect(deps['pubspecOverridesSha256'], isNull);
      expect(deps['pathOverrides'], isEmpty);
      expect((deps['gitDependencies'] as List).single, {
        'package': 'analytics',
        'url': 'https://github.com/OpenStrap/analytics',
        'resolvedRef': 'fedcba9876543210fedcba9876543210fedcba98',
      });
      expect((m['baseline'] as Map).cast<String, Object?>(), {'passed': true, 'testsRun': 12, 'durationMs': 3000});
    });

    test('counts and score are in the document', () {
      expect((json['counts'] as Map)['killed'], 2);
      expect(json['score'], closeTo(0.5, 1e-12));
    });

    test('every mutant has location, operator, texts, status, killers, reruns and duration', () {
      final ms = (json['mutants'] as List).cast<Map<String, Object?>>();
      expect(ms, hasLength(9));
      expect(ms.first, {
        'id': 'lib/a.dart:10:relational:00000001',
        'file': 'lib/a.dart',
        'line': 1,
        'column': 5,
        'byteOffset': 10,
        'byteLength': 1,
        'operator': 'relational',
        'original': '<',
        'mutated': '<=',
        'status': 'killed',
        'killingTests': ['test/a_test.dart::lt boundary'],
        'killers': [
          {'test': 'test/a_test.dart::lt boundary', 'kind': 'assertion', 'confirmedKind': null}
        ],
        'guardTests': <Object?>[],
        'reruns': <Object?>[],
        'durationMs': 100,
        'detail': '',
      });
      expect(ms[3]['status'], 'killed-by-guard-only');
      expect(ms[3]['guardTests'], ['test/guards/g_test.dart::no heavy calc']);
      expect(ms[4]['detail'], contains('Error: nope'));
      expect(ms.last['reruns'], [
        {'test': 'test/a_test.dart::flaky', 'confirmed': false, 'result': 'passed-alone', 'kind': null, 'detail': ''}
      ]);
    });

    test('each killer carries its kind: an assertion or an exception', () {
      final ms = (json['mutants'] as List).cast<Map<String, Object?>>();
      expect(ms[1]['killers'], [
        {'test': 'test/a_test.dart::gt boundary', 'kind': 'exception', 'confirmedKind': null},
        {'test': 'test/b_test.dart::gt other', 'kind': 'assertion', 'confirmedKind': 'exception'},
      ]);
      expect(ms[1]['killingTests'], ['test/a_test.dart::gt boundary', 'test/b_test.dart::gt other']);
      expect(ms[2]['killers'], isEmpty);
    });

    test('mutants keep the order they were given', () {
      final ids = [for (final m in (json['mutants'] as List).cast<Map<String, Object?>>()) m['line']];
      expect(ids, [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    });
  });

  group('Markdown', () {
    late String md;
    setUp(() => md = sample().renderMarkdown());

    test('names the commit, the command and the dependency pins', () {
      expect(md, contains(sha));
      expect(md, contains('flutter test --reporter json'));
      expect(md, contains('fedcba9876543210fedcba9876543210fedcba98'));
      expect(md, contains('ab' * 32));
    });

    test('names the audited sibling with its HEAD and whether it was dirty', () {
      final withSibling = AuditResults(
        AuditMeta(
          toolVersion: '0.1.0', repo: '/dev/edge', sha: sha,
          dependencies: DependencyConfig(lockSha256: null, overridesFileSha256: null, gitDependencies: const [], pathOverrides: [
            PathOverride('analytics', '/w/analytics', 'pubspec_overrides.yaml',
                resolvedPath: '/w/analytics', gitHead: 'c' * 40, dirty: true),
            PathOverride('protocol', '/w/protocol', 'pubspec_overrides.yaml', resolvedPath: '/w/protocol'),
          ]),
          testCmd: 'dart test', files: const ['lib/a.dart'], tests: const [], guardPatterns: const [],
          timeoutSeconds: 1, maxMutants: null, sample: null, seed: null,
          baseline: const BaselineSummary(passed: true, testsRun: 1, duration: Duration.zero),
          startedAt: DateTime.utc(2026), finishedAt: DateTime.utc(2026), candidateMutants: 0,
        ),
        const [],
      );
      final text = withSibling.renderMarkdown();
      expect(text, contains('c' * 40));
      expect(text, contains('DIRTY'));
      expect(text, contains('git state unknown'));
      final overrides = (withSibling.toJson()['meta'] as Map)['dependencies'] as Map;
      expect((overrides['pathOverrides'] as List).first, containsPair('gitHead', 'c' * 40));
      expect((overrides['pathOverrides'] as List).first, containsPair('dirty', true));
    });

    test('has a count for each status and the score as a percentage', () {
      expect(md, matches(RegExp(r'killed\W+2\b')));
      expect(md, matches(RegExp(r'killed-by-guard-only\W+1\b')));
      expect(md, matches(RegExp(r'survived\W+2\b')));
      expect(md, matches(RegExp(r'compile-invalid\W+1\b')));
      expect(md, matches(RegExp(r'timeout\W+1\b')));
      expect(md, matches(RegExp(r'load-failure\W+1\b')));
      expect(md, matches(RegExp(r'skipped\W+1\b')));
      expect(md, contains('50.0%'));
    });

    test('lists survivors with file, line and the change', () {
      expect(md, contains('## Survivors'));
      final survivors = md.substring(md.indexOf('## Survivors'));
      expect(survivors, contains('lib/a.dart:3'));
      expect(survivors, contains('`==`'));
      expect(survivors, contains('`!=`'));
      expect(survivors, contains('lib/a.dart:9'));
    });

    test('kills are listed with the kind of each killing test', () {
      expect(md, contains('## Killed\n'));
      final killed = md.substring(md.indexOf('## Killed\n'), md.indexOf('## Survivors'));
      expect(killed, contains('lib/a.dart:1'));
      expect(killed, contains('test/a_test.dart::lt boundary (assertion)'));
      expect(killed, contains('test/a_test.dart::gt boundary (exception)'));
      expect(killed, contains('test/b_test.dart::gt other (assertion; rerun: exception)'));
    });

    test('guard-only mutants are listed apart from kills and survivors', () {
      expect(md, contains('## Killed by guards only'));
      expect(md, contains('test/guards/g_test.dart::no heavy calc'));
    });

    test('compile-invalid, timeout and load-failure mutants have their own sections', () {
      expect(md, contains('## Compile-invalid'));
      expect(md, contains('Error: nope'));
      expect(md, contains('## Timeouts'));
      expect(md, contains('## Load failures'));
      expect(md, contains('Bad state: load time'));
    });

    test('unconfirmed mutants have a section that says why, and stay out of the score', () {
      final results = AuditResults(meta(), [
        result(mutant(1, '<', '<='), MutantStatus.killed, killing: ['test/a_test.dart::k']),
        result(mutant(2, '>', '>='), MutantStatus.unconfirmed, detail: 'test/a_test.dart::flaky: the rerun timed out', reruns: [
          const RerunRecord('test/a_test.dart::flaky', result: RerunResult.unresolved, detail: 'the rerun timed out'),
        ]),
      ]);
      expect(results.counts['unconfirmed'], 1);
      expect(results.score, 1.0, reason: 'unconfirmed is outside killed / (killed + survived)');
      final text = results.renderMarkdown();
      expect(text, contains('## Unconfirmed'));
      final section = text.substring(text.indexOf('## Unconfirmed'));
      expect(section, contains('lib/a.dart:2'));
      expect(section, contains('the rerun timed out'));
      expect(section, contains('not confirmed'));
      final json = results.toJson()['mutants'] as List;
      expect((json[1] as Map)['status'], 'unconfirmed');
      expect(((json[1] as Map)['reruns'] as List).single,
          {'test': 'test/a_test.dart::flaky', 'confirmed': false, 'result': 'unresolved', 'kind': null, 'detail': 'the rerun timed out'});
    });

    test('a per-file table of kills and survivors', () {
      expect(md, contains('## By file'));
      expect(md, contains('lib/a.dart'));
    });

    test('an empty result still renders', () {
      final empty = AuditResults(meta(), const []).renderMarkdown();
      expect(empty, contains(sha));
      expect(empty, contains('no score'));
    });
  });

  group('writeResults', () {
    late GitFixture fx;
    setUp(() async => fx = await GitFixture.create({'a': 'b'}));
    tearDown(() => fx.dispose());

    test('writes results.json and summary.md into the out dir, creating it', () async {
      final out = p.join(fx.parent, 'deep', 'out');
      final paths = await writeResults(sample(), outDir: out, exportPath: p.join(fx.parent, 'export'));
      expect(paths.json, p.join(out, 'results.json'));
      expect(paths.markdown, p.join(out, 'summary.md'));
      expect(jsonDecode(File(paths.json).readAsStringSync()), jsonDecode(jsonEncode(sample().toJson())));
      expect(File(paths.markdown).readAsStringSync(), sample().renderMarkdown());
    });

    test('overwrites a previous run', () async {
      final out = p.join(fx.parent, 'out');
      await writeResults(sample(), outDir: out, exportPath: p.join(fx.parent, 'export'));
      final paths = await writeResults(AuditResults(meta(), const []), outDir: out, exportPath: p.join(fx.parent, 'export'));
      expect((jsonDecode(File(paths.json).readAsStringSync()) as Map)['mutants'], isEmpty);
    });

    test('refuses an out dir that is the export or inside it', () async {
      final export = p.join(fx.parent, 'export');
      Directory(export).createSync();
      for (final out in [export, p.join(export, 'results'), p.join(export, 'a', '..', 'b')]) {
        await expectLater(writeResults(sample(), outDir: out, exportPath: export), throwsArgumentError, reason: out);
      }
      expect(Directory(export).listSync(), isEmpty);
    });
  });
}
