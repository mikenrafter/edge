import 'dart:convert';
import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/fakes.dart';
import 'support/git_fixture.dart';

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
      ['--repo', fx.root, '--sha', sha, '--files', 'lib/a.dart', '--test-cmd', 'dart test', '--out', out.path, ...extra];

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
      final home = Directory.systemTemp.createTempSync('mutaudit_home_').resolveSymbolicLinksSync();
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
