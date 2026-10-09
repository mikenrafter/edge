import 'dart:convert';
import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/fakes.dart';
import 'support/git_fixture.dart';
import 'support/package_config.dart';

const lib = 'bool lt(int a, int b) => a < b;\nbool gt(int a, int b) => a > b;\n';

/// Every test invocation runs in bubblewrap; setup does not (it needs the
/// network); `--no-sandbox` is an explicit, visible opt-out; no bubblewrap
/// means no audit.
void main() {
  late GitFixture fx;
  late Directory out;
  late String sha;
  final err = StringBuffer();
  final stdout_ = StringBuffer();
  var probes = 0;

  setUp(() async {
    fx = await GitFixture.create({
      'pubspec.yaml': 'name: demo\nenvironment:\n  sdk: ^3.0.0\n',
      'lib/a.dart': lib,
      'test/a_test.dart': '// faked\n',
    });
    sha = await fx.head();
    out = scratch('mutaudit_out_');
    err.clear();
    stdout_.clear();
    probes = 0;
  });
  tearDown(() {
    fx.dispose();
    out.deleteSync(recursive: true);
  });

  List<String> args([List<String> extra = const []]) =>
      ['--repo', fx.root, '--sha', sha, '--files', 'lib/a.dart', '--test-cmd', 'dart test', '--out', out.path, '--no-memory-cap', ...extra];  // the cap has its own tests (cli_memory_test.dart)

  Future<int> run(FakeProcessRunner runner, [List<String> extra = const [], Future<String> Function()? probe, Map<String, String>? env]) =>
      runCli(args(extra),
          runner: runner,
          out: stdout_,
          err: err,
          now: () => DateTime.utc(2026, 10, 9, 8),
          sandboxProbe: probe ??
              () async {
                probes++;
                return 'bubblewrap 9.9.9';
              },
          sandboxEnvironment: env ?? {'HOME': '/nonexistent-home', 'PATH': '/usr/bin'});

  /// Kills the "<=" mutant, lets everything else pass.
  FakeProcessRunner tests({void Function(Call call)? onRun}) => FakeProcessRunner((call) {
        if (call.argv.length >= 2 && call.argv[1] == 'pub') return const ProcessOutcome(exitCode: 0);
        onRun?.call(call);
        final src = File(p.join(call.cwd, 'lib/a.dart')).readAsStringSync();
        return src.contains('a <= b') ? outcomeOf(failing('lt boundary'), exitCode: 1) : outcomeOf(passing());
      });

  Map<String, dynamic> results() => jsonDecode(File(p.join(out.path, 'results.json')).readAsStringSync()) as Map<String, dynamic>;

  bool wrapped(Call c) => c.argv.first == 'bwrap';
  List<String> inner(Call c) => c.argv.sublist(c.argv.indexOf('--') + 1);

  group('on by default', () {
    test('the setup command runs outside the sandbox; the baseline and every mutant run inside it', () async {
      final runner = tests();
      expect(await run(runner, ['--max-mutants', '2']), 0, reason: err.toString());
      expect(runner.calls.first.argv, ['dart', 'pub', 'get'], reason: 'setup needs the network');
      final testRuns = runner.calls.skip(1).toList();
      expect(testRuns, hasLength(3), reason: 'baseline and two mutants');
      expect(testRuns.every(wrapped), isTrue);
      for (final c in testRuns) {
        expect(inner(c), containsAllInOrder(['dart', 'test', '--reporter', 'json']));
        expect(c.argv, contains('--unshare-net'));
        expect(c.argv, contains('--unshare-pid'));
        final i = c.argv.indexOf('--overlay-src');
        expect(c.argv[i + 1], c.cwd, reason: 'the overlay is the export');
        expect(c.argv.sublist(i, i + 4), ['--overlay-src', c.cwd, '--tmp-overlay', c.cwd]);
      }
    });

    test('the probe runs once, before the export exists', () async {
      String? seenWorktrees;
      final code = await run(tests(), ['--max-mutants', '1'], () async {
        probes++;
        seenWorktrees = await fx.worktrees();
        return 'bubblewrap 9.9.9';
      });
      expect(code, 0, reason: err.toString());
      expect(probes, 1);
      expect(seenWorktrees, isNot(contains('mutation_audit_')));
    });

    test('the report says bubblewrap, its version and what was bound, and no mutant is unisolated', () async {
      expect(await run(tests(), ['--max-mutants', '2']), 0, reason: err.toString());
      final isolation = (results()['meta'] as Map)['isolation'] as Map;
      expect(isolation['mode'], 'bubblewrap');
      expect(isolation['bwrap'], 'bubblewrap 9.9.9');
      expect(isolation['network'], isFalse);
      expect((results()['mutants'] as List).map((m) => (m as Map)['unisolated']), everyElement(isFalse));
      expect(File(p.join(out.path, 'summary.md')).readAsStringSync(), contains('- Isolation: bubblewrap'));
      expect(File(p.join(out.path, 'summary.md')).readAsStringSync(), isNot(contains('unisolated')));
    });

    test('a failing rerun is sandboxed too', () async {
      var n = 0;
      final runner = FakeProcessRunner((call) {
        if (call.argv.length >= 2 && call.argv[1] == 'pub') return const ProcessOutcome(exitCode: 0);
        n++;
        if (n == 2) return outcomeOf(StreamBuilder().loaded('test/a_test.dart').fail('test/a_test.dart', 'flaky').done(success: false), exitCode: 1);
        return outcomeOf(passing());
      });
      expect(await run(runner, ['--max-mutants', '1', '--flaky-test', 'test/a_test.dart::flaky']), 0, reason: err.toString());
      final testRuns = runner.calls.skip(1).toList();
      expect(testRuns, hasLength(3), reason: 'baseline, mutant, rerun');
      expect(testRuns.every(wrapped), isTrue);
      expect(inner(testRuns.last), containsAllInOrder(['--name']));
    });

    test('paths under HOME that the toolchain reads are bound read-only: --sandbox-ro and an allowed sibling', () async {
      // Not under /tmp, which the sandbox replaces and never binds into.
      final realHome = Platform.environment['HOME']!;
      final home = Directory(p.join(realHome, '.mutaudit_cli_home_$pid')).path;
      Directory(home).createSync();
      addTearDown(() => Directory(home).deleteSync(recursive: true));
      final extra = Directory(p.join(home, 'tools'))..createSync();
      final pubCache = Directory(p.join(home, '.pub-cache'))..createSync();
      final runner = tests();
      expect(await run(runner, ['--max-mutants', '1', '--sandbox-ro', extra.path], null, {'HOME': home, 'PATH': '/usr/bin'}), 0,
          reason: err.toString());
      final argv = runner.calls.last.argv;
      expect(argv.sublist(argv.indexOf(extra.path) - 1, argv.indexOf(extra.path) + 2), ['--ro-bind', extra.path, extra.path]);
      expect(argv, contains(pubCache.path));
      expect(((results()['meta'] as Map)['isolation'] as Map)['binds'], containsAll([extra.path, pubCache.path]));
    });
  });

  group('no bubblewrap, no audit', () {
    test('a failing probe exits 70 with its reason and --no-sandbox as the way out; nothing was exported or run', () async {
      final runner = tests();
      final code = await run(runner, const [], () async => throw SandboxUnavailable('bubblewrap ("bwrap") cannot be run: not found. Install it, or pass --no-sandbox'));
      expect(code, 70);
      expect(err.toString(), contains('--no-sandbox'));
      expect(err.toString(), contains('not found'));
      expect(runner.calls, isEmpty);
      expect(await fx.worktrees(), isNot(contains('mutation_audit_')));
      expect(out.listSync(), isEmpty);
    });
  });

  group('build hooks are built before the sandbox, which has no network', () {
    /// Setup writes a package config in which `native` has a build hook, like `pub get`.
    FakeProcessRunner withHooks({ProcessOutcome Function(Call call)? warmup, bool hooks = true}) => FakeProcessRunner((call) {
          if (call.argv.length >= 2 && call.argv[1] == 'pub') {
            if (hooks) {
              Directory(p.join(call.cwd, '.dart_tool', 'native', 'hook')).createSync(recursive: true);
              File(p.join(call.cwd, '.dart_tool', 'native', 'hook', 'build.dart')).writeAsStringSync('');
              writeConfig(call.cwd, {'demo': ('../', 'lib/'), 'native': ('native', 'lib/')});
            }
            return const ProcessOutcome(exitCode: 0);
          }
          if (call.argv.contains(warmupSuite)) return warmup?.call(call) ?? const ProcessOutcome(exitCode: 1);
          final src = File(p.join(call.cwd, 'lib/a.dart')).readAsStringSync();
          return src.contains('a <= b') ? outcomeOf(failing('lt boundary'), exitCode: 1) : outcomeOf(passing());
        });

    test('one warm-up run between setup and the baseline: outside the sandbox, with the network, on a suite that does not exist', () async {
      final runner = withHooks();
      expect(await run(runner, ['--max-mutants', '1']), 0, reason: err.toString());
      expect(runner.calls.map((c) => c.argv.take(2).join(' ')), ['dart pub', 'dart test', 'bwrap --dev', 'bwrap --dev']);
      final warm = runner.calls[1];
      expect(warm.argv, ['dart', 'test', '--reporter', 'json', warmupSuite]);
      expect(warm.argv.contains('--unshare-net'), isFalse);
      expect(warm.cwd, runner.calls.first.cwd);
      expect(warm.timeout, isNotNull);
      expect(File(p.join(out.path, 'setup.log')).existsSync(), isFalse, reason: 'its failing exit is expected');
    });

    test('no hook in the package config, no warm-up', () async {
      final runner = withHooks(hooks: false);
      expect(await run(runner, ['--max-mutants', '1']), 0, reason: err.toString());
      expect(runner.calls.any((c) => c.argv.contains(warmupSuite)), isFalse);
    });

    test('--no-sandbox has the network anyway: no warm-up', () async {
      final runner = withHooks();
      expect(await run(runner, ['--no-sandbox', '--max-mutants', '1']), 0, reason: err.toString());
      expect(runner.calls.any((c) => c.argv.contains(warmupSuite)), isFalse);
    });

    test('a warm-up that times out stops the audit before the baseline, with its log', () async {
      final runner = withHooks(warmup: (_) => const ProcessOutcome(exitCode: -9, timedOut: true, stderr: 'still downloading\n'));
      expect(await run(runner, ['--max-mutants', '1']), 70);
      expect(err.toString(), allOf(contains('timed out'), contains('warmup.log'), contains('still downloading')));
      expect(File(p.join(out.path, 'warmup.log')).readAsStringSync(), contains('still downloading'));
      expect(runner.calls.where(wrapped), isEmpty);
    });
  });

  group('an aborting probe leaves its output behind', () {
    test('the sandbox output goes to <out>/probe.log; the error shows its tail and the path', () async {
      final output = [for (var i = 1; i <= 80; i++) 'probe line $i'].join('\n');
      final code = await run(tests(), const [], () async => throw SandboxUnavailable('"flutter --version" does not run', output: output));
      expect(code, 70);
      final log = File(p.join(out.path, 'probe.log'));
      expect(log.readAsStringSync(), allOf(contains('probe line 1\n'), contains('probe line 80')));
      expect(err.toString(), allOf(contains('does not run'), contains(log.path), contains('probe line 80'), isNot(contains('probe line 10\n'))));
    });

    test('a probe error without output writes no log', () async {
      expect(await run(tests(), const [], () async => throw SandboxUnavailable('nope')), 70);
      expect(File(p.join(out.path, 'probe.log')).existsSync(), isFalse);
    });
  });

  group('--no-sandbox', () {
    test('is explicit: no probe, nothing wrapped, the report says isolation none and every mutant is unisolated', () async {
      final runner = tests();
      expect(await run(runner, ['--no-sandbox', '--max-mutants', '2']), 0, reason: err.toString());
      expect(probes, 0);
      expect(runner.calls.any(wrapped), isFalse);
      expect(runner.calls.skip(1).first.argv.take(2), ['dart', 'test']);
      expect(((results()['meta'] as Map)['isolation'] as Map)['mode'], 'none');
      final mutants = (results()['mutants'] as List).cast<Map<String, dynamic>>();
      expect(mutants.map((m) => m['unisolated']), everyElement(isTrue));
      expect(mutants.where((m) => m['status'] == 'killed'), isNotEmpty);
      final md = File(p.join(out.path, 'summary.md')).readAsStringSync();
      expect(md, contains('- Isolation: NONE (--no-sandbox)'));
      expect(md, contains('unisolated'));
    });

    test('a failing probe does not matter', () async {
      final code = await run(tests(), ['--no-sandbox', '--max-mutants', '1'], () async => throw SandboxUnavailable('no'));
      expect(code, 0, reason: err.toString());
    });

    test('the runs still get a TMPDIR of their own, the sandbox not being there to provide one', () async {
      final runner = tests();
      await run(runner, ['--no-sandbox', '--max-mutants', '1']);
      expect(runner.calls.skip(1).map((c) => c.environment!['TMPDIR']).toSet(), hasLength(2));
    });
  });

  group('the sandbox is checked from the host after every run', () {
    test('a run that wrote into the export on the host stops the audit (exit 70) and no results are published', () async {
      final runner = tests(onRun: (call) {
        if (File(p.join(call.cwd, 'lib/a.dart')).readAsStringSync().contains('a <= b')) File(p.join(call.cwd, 'leaked.txt')).writeAsStringSync('x');
      });
      final code = await run(runner, ['--max-mutants', '1']);
      expect(code, 70);
      expect(err.toString(), contains('isolation did not hold'));
      expect(err.toString(), contains('leaked.txt'));
      expect(File(p.join(out.path, 'results.json')).existsSync(), isFalse);
    });

    test('the same write is not judged with --no-sandbox', () async {
      final runner = tests(onRun: (call) => File(p.join(call.cwd, 'leaked.txt')).writeAsStringSync('x'));
      final code = await run(runner, ['--no-sandbox', '--max-mutants', '1']);
      expect(code, 0, reason: err.toString());
    });
  });
}
