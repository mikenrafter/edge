import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/git_fixture.dart';

void main() {
  late Directory repo;
  setUp(() {
    repo = scratch('mutaudit_cfg_');
    File(p.join(repo.path, 'pubspec.yaml')).writeAsStringSync('name: lib\nenvironment:\n  sdk: ^3.0.0\n');
  });
  tearDown(() => repo.deleteSync(recursive: true));

  List<String> required([List<String> extra = const []]) => [
        '--repo', repo.path,
        '--sha', 'abc1234',
        '--files', 'lib/**.dart',
        '--out', '/tmp/out',
        ...extra,
      ];

  group('parseAuditArgs', () {
    test('the required options alone, with defaults', () {
      final c = parseAuditArgs(required());
      expect(c.repo, repo.path);
      expect(c.sha, 'abc1234');
      expect(c.files, ['lib/**.dart']);
      expect(c.outDir, '/tmp/out');
      expect(c.testCmd, 'dart test --reporter json', reason: 'the repo is pure dart');
      expect(c.timeout, const Duration(seconds: 300));
      expect(c.tests, isEmpty);
      expect(c.maxMutants, isNull);
      expect(c.sample, isNull);
      expect(c.seed, isNull);
      expect(c.guardPatterns, isEmpty);
      expect(c.allowOverrides, isEmpty);
      expect(c.flakyTests, isEmpty);
      expect(c.setupCmd, isNull);
      expect(c.env, {'TZ': 'UTC'});
    });

    group('source guards are detected, not declared', () {
      List<String> bare([List<String> extra = const []]) =>
          ['--repo', repo.path, '--sha', 's', '--files', 'lib/a.dart', '--out', '/o', ...extra];

      test('nothing to declare: a plain command line is valid, with or without --tests', () {
        expect(parseAuditArgs(bare()).guardPolicy, 'detected');
        expect(parseAuditArgs(bare(['--tests', 'test'])).guardPolicy, 'detected');
        expect(parseAuditArgs(bare(['--tests', 'test/a_test.dart'])).guardPolicy, 'detected');
      });

      test('--guard-pattern adds patterns on top of the detector', () {
        final c = parseAuditArgs(bare(['--guard-pattern', 'test/guards/**']));
        expect(c.guardPatterns, ['test/guards/**']);
        expect(c.noGuards, isFalse);
        expect(c.guardPolicy, 'detected');
      });

      test('--no-guards is an assertion that the detector will check', () {
        final c = parseAuditArgs(bare(['--no-guards']));
        expect(c.noGuards, isTrue);
        expect(c.guardPolicy, 'no-guards-asserted');
      });

      test('--no-guards contradicts --guard-pattern and --runtime-allowlist', () {
        final list = File(p.join(repo.path, 'runtime.txt'))..writeAsStringSync('test/a_test.dart\n');
        expect(() => parseAuditArgs(bare(['--no-guards', '--guard-pattern', 'x'])), throwsA(isA<UsageError>()));
        expect(() => parseAuditArgs(bare(['--no-guards', '--runtime-allowlist', list.path])),
            throwsA(isA<UsageError>()));
      });

      test('--runtime-allowlist names a file that must exist', () {
        final list = File(p.join(repo.path, 'runtime.txt'))..writeAsStringSync('test/a_test.dart\n');
        expect(parseAuditArgs(bare(['--runtime-allowlist', list.path])).runtimeAllowlist, list.path);
        expect(parseAuditArgs(bare()).runtimeAllowlist, isNull);
        expect(() => parseAuditArgs(bare(['--runtime-allowlist', p.join(repo.path, 'nope.txt')])),
            throwsA(isA<UsageError>().having((e) => e.message, 'message', contains('nope.txt'))));
      });

      test('--scanner repeats and takes every following word', () {
        final c = parseAuditArgs(bare(['--scanner', 'test/support/a.dart', 'test/support/b.dart', '--timeout', '9']));
        expect(c.scanners, ['test/support/a.dart', 'test/support/b.dart']);
        expect(c.timeout, const Duration(seconds: 9));
        expect(parseAuditArgs(bare()).scanners, isEmpty);
      });

      test('a --no-guards flag does not swallow the next word', () {
        final c = parseAuditArgs(bare(['--no-guards', '--timeout', '9']));
        expect(c.timeout, const Duration(seconds: 9));
      });
    });

    test('a flutter repo defaults to flutter test', () {
      File(p.join(repo.path, 'pubspec.yaml')).writeAsStringSync('name: app\ndependencies:\n  flutter:\n    sdk: flutter\n');
      expect(parseAuditArgs(required()).testCmd, 'flutter test --reporter json');
    });

    test('every option', () {
      final c = parseAuditArgs(required([
        '--test-cmd', 'dart test -j 1',
        '--tests', 'test/a_test.dart', '--tests', 'test/b_test.dart,test/c_test.dart',
        '--max-mutants', '40',
        '--sample', '10', '--seed', '7',
        '--timeout', '45',
        '--guard-pattern', 'test/guards/**', '--guard-pattern', '*_guard_test.dart',
        '--allow-override', '../analytics',
        '--flaky-test', 'test/a_test.dart::t',
        '--setup-cmd', 'dart pub get --offline',
        '--env', 'FOO=bar=baz', '--env', 'TZ=Europe/Berlin',
      ]));
      expect(c.testCmd, 'dart test -j 1');
      expect(c.tests, ['test/a_test.dart', 'test/b_test.dart', 'test/c_test.dart']);
      expect(c.maxMutants, 40);
      expect((c.sample, c.seed), (10, 7));
      expect(c.timeout, const Duration(seconds: 45));
      expect(c.guardPatterns, ['test/guards/**', '*_guard_test.dart']);
      expect(c.allowOverrides, ['../analytics']);
      expect(c.flakyTests, ['test/a_test.dart::t']);
      expect(c.setupCmd, 'dart pub get --offline');
      expect(c.env, {'TZ': 'Europe/Berlin', 'FOO': 'bar=baz'});
    });

    test('--files repeats and takes commas', () {
      final c = parseAuditArgs([
        '--repo', repo.path, '--sha', 's', '--out', '/o', '--no-guards',
        '--files', 'lib/a.dart,lib/b.dart', '--files', 'lib/c.dart',
      ]);
      expect(c.files, ['lib/a.dart', 'lib/b.dart', 'lib/c.dart']);
    });

    test('list options take every following word up to the next option', () {
      final c = parseAuditArgs([
        '--repo', repo.path, '--sha', 's', '--out', '/o', '--no-guards',
        '--files', 'lib/a.dart', 'lib/b.dart',
        '--tests', 'test/a_test.dart', 'test/b_test.dart', 'test/c_test.dart',
        '--timeout', '9',
      ]);
      expect(c.files, ['lib/a.dart', 'lib/b.dart']);
      expect(c.tests, ['test/a_test.dart', 'test/b_test.dart', 'test/c_test.dart']);
      expect(c.timeout, const Duration(seconds: 9));
    });

    test('a stray word after a single-value option is still refused', () {
      expect(() => parseAuditArgs(required(['--timeout', '9', 'stray'])), throwsA(isA<UsageError>()));
    });

    test('commas inside braces of a glob do not split', () {
      final c = parseAuditArgs(required(['--files', 'lib/{a,b}.dart,lib/c.dart']));
      expect(c.files, ['lib/**.dart', 'lib/{a,b}.dart', 'lib/c.dart']);
    });

    test('an empty --setup-cmd means no setup', () {
      expect(parseAuditArgs(required(['--setup-cmd', ''])).setupCmd, '');
    });

    for (final missing in ['--repo', '--sha', '--files', '--out']) {
      test('$missing is required', () {
        final args = required();
        final at = args.indexOf(missing);
        args.removeRange(at, at + 2);
        expect(() => parseAuditArgs(args),
            throwsA(isA<UsageError>().having((e) => e.message, 'message', contains(missing))));
      });
    }

    test('--sample needs --seed', () {
      expect(() => parseAuditArgs(required(['--sample', '5'])),
          throwsA(isA<UsageError>().having((e) => e.message, 'message', contains('--seed'))));
    });

    test('numbers must be non-negative integers, the timeout at least 1', () {
      for (final bad in [
        ['--max-mutants', 'many'],
        ['--max-mutants', '-1'],
        ['--sample', '2.5', '--seed', '1'],
        ['--seed', 'x'],
        ['--timeout', '0'],
        ['--timeout', 'soon'],
        ['--env', 'NOEQUALS'],
      ]) {
        expect(() => parseAuditArgs(required(bad)), throwsA(isA<UsageError>()), reason: bad.join(' '));
      }
    });

    test('unknown options and stray arguments are refused', () {
      expect(() => parseAuditArgs(required(['--nope', '1'])), throwsA(isA<UsageError>()));
      expect(() => parseAuditArgs(required(['stray'])), throwsA(isA<UsageError>()));
    });

    test('a repo that does not exist is refused', () {
      expect(() => parseAuditArgs(['--repo', '/definitely/not/here', '--sha', 's', '--files', 'a', '--out', '/o']),
          throwsA(isA<UsageError>()));
    });
  });

  test('the default guard patterns in the README match the guard tests of the repo and not ordinary tests', () {
    final readme = File('README.md').readAsStringSync();
    final block = RegExp(r'<!-- guard-patterns:edge -->\s*```\n([\s\S]*?)```').firstMatch(readme);
    expect(block, isNotNull, reason: 'README.md carries the default guard pattern list');
    final patterns = block!.group(1)!.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final matcher = GuardMatcher(patterns);
    TestOutcome at(String suite) =>
        TestOutcome(suite: suite, name: 'n', result: TestResult.failure, skipped: false);
    for (final guard in [
      'test/guards/heavy_calc_guard_test.dart',
      'test/guards/worker_audit_test.dart',
      'test/guards/support/fixture_world.dart',
      'test/coach_sql_guard_test.dart',
      'test/absence_and_offload_guards_test.dart',
      'test/water/assume_wiring_test.dart',
      'test/link_priority_structural_test.dart',
      'test/ble_safety_inventory_test.dart',
      'test/no_debug_only_apis_test.dart',
      'test/source_invariant_guards_test.dart',
      '/tmp/export/test/sample_archive/sample_guard_test.dart',
    ]) {
      expect(matcher.matches(at(guard)), isTrue, reason: guard);
    }
    for (final runtime in [
      'test/alarm_test.dart',
      'test/ui2/charts_test.dart',
      'test/readiness_flash_test.dart',
      'test/properties/annotation_layout_laws_test.dart',
      'test/db_test.dart',
    ]) {
      expect(matcher.matches(at(runtime)), isFalse, reason: runtime);
    }
  });

  test('the usage text names every option', () {
    final u = auditUsage();
    for (final o in [
      '--repo', '--sha', '--files', '--test-cmd', '--tests', '--max-mutants', '--sample', '--seed',
      '--timeout', '--guard-pattern', '--no-guards', '--runtime-allowlist', '--scanner', '--allow-override', '--flaky-test', '--setup-cmd', '--env', '--out',
    ]) {
      expect(u, contains(o));
    }
  });
}
