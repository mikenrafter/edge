import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/fakes.dart';
import 'support/git_fixture.dart';

/// A tiny pure-dart package: one comparison, one test file.
const lib = 'bool lt(int a, int b) => a < b;\nbool gt(int a, int b) => a > b;\n';

void main() {
  late GitFixture fx;
  late Directory out;
  late String sha;
  final err = StringBuffer();
  final stdout_ = StringBuffer();

  setUp(() async {
    fx = await GitFixture.create({
      'pubspec.yaml': 'name: demo\nenvironment:\n  sdk: ^3.0.0\n',
      'lib/a.dart': lib,
      'test/a_test.dart': '// the real tests are faked in this test\n',
    });
    sha = await fx.head();
    out = scratch('mutaudit_out_');
    err.clear();
    stdout_.clear();
  });
  tearDown(() {
    fx.dispose();
    out.deleteSync(recursive: true);
  });

  List<String> args([List<String> extra = const [], String? at]) => [
        '--repo', fx.root,
        '--sha', at ?? sha,
        '--files', 'lib/a.dart',
        '--test-cmd', 'dart test',
        '--out', out.path,
        if (!extra.contains('--guard-pattern') && !extra.contains('--tests')) '--no-guards',
        ...extra,
      ];

  Future<int> run(FakeProcessRunner runner, [List<String> extra = const []]) => runCli(
        args(extra),
        runner: runner,
        out: stdout_,
        err: err,
        now: () => DateTime.utc(2026, 10, 9, 8),
      );

  /// Kills the "<=" mutant, lets everything else pass.
  FakeProcessRunner tests() => FakeProcessRunner((call) {
        if (call.argv.length >= 2 && call.argv[1] == 'pub') return const ProcessOutcome(exitCode: 0);
        final src = File(p.join(call.cwd, 'lib/a.dart')).readAsStringSync();
        return src.contains('a <= b') ? outcomeOf(failing('lt boundary'), exitCode: 1) : outcomeOf(passing());
      });

  test('a usage error prints the usage and exits 64', () async {
    final code = await runCli(['--repo'], runner: tests(), out: stdout_, err: err);
    expect(code, 64);
    expect(err.toString(), contains('--sha'));
    expect(err.toString(), contains('Usage'));
  });

  test('a whole-suite audit that does not classify its source guards is a usage error', () async {
    final runner = tests();
    final code = await runCli(
        ['--repo', fx.root, '--sha', sha, '--files', 'lib/a.dart', '--out', out.path],
        runner: runner, out: stdout_, err: err);
    expect(code, 64);
    expect(err.toString(), contains('--no-guards'));
    expect(runner.calls, isEmpty);
    expect(await fx.worktrees(), isNot(contains('mutation_audit_')));
  });

  test('the report says how the source guards were classified', () async {
    await run(tests());
    final json = jsonDecode(File(p.join(out.path, 'results.json')).readAsStringSync()) as Map<String, dynamic>;
    expect((json['meta'] as Map)['guardPolicy'], 'none-declared');
  });

  test('a whole audit: results written outside the export, export gone, checkout untouched', () async {
    File(p.join(fx.root, 'lib/a.dart')).writeAsStringSync('// local edit\n$lib');
    final statusBefore = await fx.status();
    final runner = tests();
    final code = await run(runner);
    expect(code, 0, reason: err.toString());

    final json = jsonDecode(File(p.join(out.path, 'results.json')).readAsStringSync()) as Map<String, dynamic>;
    final meta = json['meta'] as Map<String, dynamic>;
    expect(meta['sha'], sha);
    expect(meta['repo'], fx.root);
    final mutants = (json['mutants'] as List).cast<Map<String, dynamic>>();
    final byChange = {for (final m in mutants) '${m['original']}->${m['mutated']}': m['status']};
    expect(byChange['<-><='], 'killed', reason: 'the fake kills exactly this one');
    expect(byChange.values.where((s) => s == 'survived'), isNotEmpty);
    expect(File(p.join(out.path, 'summary.md')).readAsStringSync(), contains(sha));

    // The runs happened in an export, never in the developer checkout.
    expect(runner.calls.map((c) => c.cwd).toSet(), isNot(contains(fx.root)));
    expect(runner.calls.map((c) => c.cwd).toSet(), hasLength(1));
    expect(Directory(runner.calls.first.cwd).existsSync(), isFalse);
    expect(await fx.worktrees(), isNot(contains(runner.calls.first.cwd)));
    expect(await fx.status(), statusBefore);
    expect(File(p.join(fx.root, 'lib/a.dart')).readAsStringSync(), '// local edit\n$lib');
  });

  test('the setup command runs once in the export before the baseline', () async {
    final runner = tests();
    await run(runner);
    expect(runner.calls.first.argv, ['dart', 'pub', 'get']);
    expect(runner.calls.where((c) => c.argv.length > 1 && c.argv[1] == 'pub'), hasLength(1));
    expect(runner.calls[1].argv, containsAllInOrder(['dart', 'test', '--reporter', 'json']));
  });

  test('--setup-cmd "" runs no setup', () async {
    final runner = tests();
    await run(runner, ['--setup-cmd', '']);
    expect(runner.calls.first.argv.take(2), ['dart', 'test']);
  });

  test('--max-mutants bounds the number of mutant runs', () async {
    final runner = tests();
    await run(runner, ['--max-mutants', '1', '--setup-cmd', '']);
    expect(runner.calls, hasLength(2), reason: 'baseline plus one mutant');
    final json = jsonDecode(File(p.join(out.path, 'results.json')).readAsStringSync()) as Map<String, dynamic>;
    expect(json['mutants'], hasLength(1));
    expect((json['meta'] as Map)['candidateMutants'], greaterThan(1));
  });

  test('a failing baseline exits 65, writes no results and removes the export', () async {
    final runner = FakeProcessRunner((call) => call.argv[1] == 'pub'
        ? const ProcessOutcome(exitCode: 0)
        : outcomeOf(failing('broken'), exitCode: 1));
    final code = await run(runner);
    expect(code, 65);
    expect(err.toString(), contains('broken'));
    expect(File(p.join(out.path, 'results.json')).existsSync(), isFalse);
    expect(await fx.worktrees(), isNot(contains(runner.calls.first.cwd)));
  });

  test('an active path override exits 65 before anything runs', () async {
    await fx.commit({
      'pubspec.yaml': 'name: demo\nenvironment:\n  sdk: ^3.0.0\ndependency_overrides:\n  analytics:\n    path: ../analytics\n',
    }, 'override');
    final pinned = await fx.head();
    final runner = tests();
    final code = await runCli(
      args(const [], pinned),
      runner: runner,
      out: stdout_,
      err: err,
    );
    expect(code, 65);
    expect(err.toString(), contains('analytics'));
    expect(runner.calls, isEmpty);
  });

  test('--allow-override lets the audited sibling through and records it', () async {
    final sibling = p.join(fx.parent, 'analytics');
    await fx.commit({
      'pubspec.yaml': 'name: demo\nenvironment:\n  sdk: ^3.0.0\ndependency_overrides:\n  analytics:\n    path: $sibling\n',
    }, 'override');
    final pinned = await fx.head();
    final runner = tests();
    final code = await runCli(
      args(['--allow-override', '../analytics', '--setup-cmd', ''], pinned),
      runner: runner,
      out: stdout_,
      err: err,
    );
    expect(code, 0, reason: err.toString());
    final json = jsonDecode(File(p.join(out.path, 'results.json')).readAsStringSync()) as Map<String, dynamic>;
    final deps = (json['meta'] as Map)['dependencies'] as Map;
    final override = (deps['pathOverrides'] as List).single as Map;
    expect(override['package'], 'analytics');
    expect(override['resolvedPath'], sibling);
  });

  test('a relative override is resolved against the export, so ../analytics is refused even if --allow-override names it', () async {
    await fx.commit({
      'pubspec.yaml': 'name: demo\nenvironment:\n  sdk: ^3.0.0\ndependency_overrides:\n  analytics:\n    path: ../analytics\n',
    }, 'override');
    final pinned = await fx.head();
    final runner = tests();
    final code = await runCli(
      args(['--allow-override', '../analytics', '--setup-cmd', ''], pinned),
      runner: runner,
      out: stdout_,
      err: err,
    );
    expect(code, 65);
    expect(err.toString(), contains('not an allowed sibling'));
    expect(runner.calls, isEmpty);
  });

  group('Ctrl-C', () {
    test('during a mutant run: the process is reaped, then the export goes; exit 130, no results', () async {
      final interrupts = StreamController<ProcessSignal>();
      final log = <String>[];
      String? cwd;
      final runner = FakeProcessRunner((call) async {
        if (call.argv.first == 'dart' && call.argv[1] == 'pub') return const ProcessOutcome(exitCode: 0);
        final src = File(p.join(call.cwd, 'lib/a.dart')).readAsStringSync();
        if (src == lib) return outcomeOf(passing());
        cwd = call.cwd;
        interrupts.add(ProcessSignal.sigint);
        await call.cancel!.whenCancelled;
        // Reaping the tree takes a few turns; the export must still be there.
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        log.add('reaped; export exists: ${Directory(call.cwd).existsSync()}');
        return outcomeOf(StreamBuilder().loaded('test/a_test.dart'), exitCode: -15, cancelled: true);
      });
      final code = await runCli(args(), runner: runner, out: stdout_, err: err, interrupts: interrupts.stream);
      expect(code, 130, reason: err.toString());
      expect(err.toString(), contains('interrupted'));
      expect(log, ['reaped; export exists: true']);
      expect(Directory(cwd!).existsSync(), isFalse);
      expect(await fx.worktrees(), isNot(contains(cwd)));
      expect(File(p.join(out.path, 'results.json')).existsSync(), isFalse, reason: 'a partial audit is not written as a result');
      expect(runner.calls.where((c) => c.argv[1] != 'pub'), hasLength(2), reason: 'baseline and the cancelled mutant; no more');
      await interrupts.close();
    });

    test('during setup: exit 130 and the baseline never starts', () async {
      final interrupts = StreamController<ProcessSignal>();
      final runner = FakeProcessRunner((call) async {
        interrupts.add(ProcessSignal.sigterm);
        await call.cancel!.whenCancelled;
        return const ProcessOutcome(exitCode: -15, cancelled: true);
      });
      final code = await runCli(args(), runner: runner, out: stdout_, err: err, interrupts: interrupts.stream);
      expect(code, 130);
      expect(runner.calls, hasLength(1));
      expect(runner.calls.first.argv, ['dart', 'pub', 'get']);
      expect(await fx.worktrees(), isNot(contains(runner.calls.first.cwd)));
      await interrupts.close();
    });

    test('the same token reaches the setup command and every test run', () async {
      final runner = tests();
      await run(runner);
      final tokens = runner.calls.map((c) => c.cancel).toSet();
      expect(tokens, hasLength(1));
      expect(tokens.single, isNotNull);
    });
  });

  group('the dependency config is re-read after setup', () {
    const lockGit = '''
packages:
  analytics:
    dependency: "direct main"
    description:
      path: "."
      ref: abc123
      resolved-ref: "0123456789abcdef0123456789abcdef01234567"
      url: "https://github.com/OpenStrap/analytics"
    source: git
    version: "0.1.0"
''';

    /// A runner whose setup call writes [files] into the export, like pub would.
    FakeProcessRunner settingUp(Map<String, String> files) => FakeProcessRunner((call) {
          if (call.argv.length >= 2 && call.argv[1] == 'pub') {
            for (final e in files.entries) {
              File(p.join(call.cwd, e.key))
                ..createSync(recursive: true)
                ..writeAsStringSync(e.value);
            }
            return const ProcessOutcome(exitCode: 0);
          }
          return outcomeOf(passing());
        });

    test('the report carries what setup resolved, not the preflight', () async {
      const config = '{"configVersion":2,"packages":[{"name":"analytics","rootUri":"file:///x","packageUri":"lib/"}]}';
      final runner = settingUp({'pubspec.lock': lockGit, '.dart_tool/package_config.json': config});
      expect(await run(runner, ['--max-mutants', '1']), 0, reason: err.toString());
      final meta = (jsonDecode(File(p.join(out.path, 'results.json')).readAsStringSync()) as Map)['meta'] as Map;
      final deps = meta['dependencies'] as Map;
      expect(deps['pubspecLockSha256'], sha256.convert(utf8.encode(lockGit)).toString());
      expect(deps['packageConfigSha256'], sha256.convert(utf8.encode(config)).toString());
      expect((deps['gitDependencies'] as List).single['resolvedRef'], '0123456789abcdef0123456789abcdef01234567');
      final before = meta['dependenciesBeforeSetup'] as Map;
      expect(before['pubspecLockSha256'], isNull, reason: 'the export had no lock before setup');
      expect(before['packageConfigSha256'], isNull);
    });

    test('a lock that setup created with a path package is refused, before the baseline', () async {
      final runner = settingUp({
        'pubspec.lock': '''
packages:
  analytics:
    dependency: "direct main"
    description:
      path: "../analytics"
      relative: true
    source: path
    version: "0.1.0"
'''
      });
      expect(await run(runner), 65);
      expect(err.toString(), contains('pubspec.lock'));
      expect(runner.calls, hasLength(1), reason: 'only the setup command ran');
      expect(File(p.join(out.path, 'results.json')).existsSync(), isFalse);
    });

    test('a pubspec_overrides.yaml that setup wrote is refused too', () async {
      final runner = settingUp({'pubspec_overrides.yaml': 'dependency_overrides:\n  analytics:\n    path: ../analytics\n'});
      expect(await run(runner), 65);
      expect(runner.calls, hasLength(1));
    });

    test('with --setup-cmd "" the preflight is the whole story and is recorded once', () async {
      final runner = tests();
      expect(await run(runner, ['--setup-cmd', '', '--max-mutants', '1']), 0, reason: err.toString());
      final meta = (jsonDecode(File(p.join(out.path, 'results.json')).readAsStringSync()) as Map)['meta'] as Map;
      expect(meta['dependencies'], meta['dependenciesBeforeSetup']);
    });
  });

  test('an unknown sha exits 70 and leaves nothing behind', () async {
    final runner = tests();
    final code = await runCli(args(const [], 'deadbeefdeadbeef'), runner: runner, out: stdout_, err: err);
    expect(code, 70);
    expect(runner.calls, isEmpty);
    expect(await fx.worktrees(), isNot(contains('deadbeef')));
  });
}
