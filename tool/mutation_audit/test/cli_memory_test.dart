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
const mib = 1024 * 1024, gib = 1024 * mib;

/// The memory cap across the command line: probed first (fail closed), applied
/// to the sandboxed runs only, recorded, and its verdict classified.
void main() {
  late GitFixture fx;
  late Directory out;
  late String sha;
  final err = StringBuffer();
  final stdout_ = StringBuffer();
  late List<MemoryCap> probed;

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
    probed = [];
  });
  tearDown(() {
    fx.dispose();
    out.deleteSync(recursive: true);
  });

  Future<int> run(FakeProcessRunner runner, [List<String> extra = const [], Future<void> Function(MemoryCap cap)? probe]) => runCli(
        ['--repo', fx.root, '--sha', sha, '--files', 'lib/a.dart', '--test-cmd', 'dart test', '--out', out.path, ...extra],
        runner: runner,
        out: stdout_,
        err: err,
        now: () => DateTime.utc(2026, 10, 9, 8),
        sandboxProbe: () async => 'bubblewrap 9.9.9',
        memoryProbe: probe ?? (cap) async => probed.add(cap),
        sandboxEnvironment: {'HOME': '/nonexistent-home', 'PATH': '/usr/bin'},
      );

  String marker({int peak = 100 * mib, int oom = 0, int max = 4 * gib}) => '$memoryMarker peak=$peak oom_kill=$oom max=$max\n';

  /// Setup writes a package config with a build hook (so there is a warm-up);
  /// sandboxed runs report [peak]; the mutant "a <= b" fails its tests, and with
  /// [oomOn] set, the run of that mutant is killed by the cgroup.
  FakeProcessRunner tests({int peak = 100 * mib, String? oomOn}) => FakeProcessRunner((call) {
        if (call.argv.length >= 2 && call.argv[1] == 'pub') {
          Directory(p.join(call.cwd, '.dart_tool', 'native', 'hook')).createSync(recursive: true);
          File(p.join(call.cwd, '.dart_tool', 'native', 'hook', 'build.dart')).writeAsStringSync('');
          writeConfig(call.cwd, {'demo': ('../', 'lib/'), 'native': ('native', 'lib/')});
          return const ProcessOutcome(exitCode: 0);
        }
        if (call.argv.contains(warmupSuite)) return const ProcessOutcome(exitCode: 1);
        final src = File(p.join(call.cwd, 'lib/a.dart')).readAsStringSync();
        final capped = call.argv.first == 'systemd-run';
        if (oomOn != null && src.contains(oomOn)) {
          return ProcessOutcome(
              exitCode: 137,
              stdoutLines: failing('lt boundary').build(),
              stderr: capped ? marker(peak: 4 * gib, oom: 1) : '');
        }
        final o = src.contains('a <= b') ? outcomeOf(failing('lt boundary'), exitCode: 1) : outcomeOf(passing());
        return capped ? ProcessOutcome(exitCode: o.exitCode, stdoutLines: o.stdoutLines, stderr: marker(peak: peak)) : o;
      });

  Map<String, dynamic> results() => jsonDecode(File(p.join(out.path, 'results.json')).readAsStringSync()) as Map<String, dynamic>;
  Map<String, dynamic> memoryOf(Map<String, dynamic> r) => ((r['meta'] as Map)['isolation'] as Map)['memory'] as Map<String, dynamic>;

  group('the cap is on by default and applied to the sandboxed test runs only', () {
    test('probed once with 4G; baseline, mutants wrapped in systemd-run around bwrap; setup and warm-up are not', () async {
      final runner = tests();
      expect(await run(runner, ['--max-mutants', '2']), 0, reason: err.toString());
      expect(probed.map((c) => c.maxBytes), [4 * gib]);
      final kinds = runner.calls.map((c) => c.argv.first).toList();
      expect(kinds.take(2), ['dart', 'dart'], reason: 'setup and warm-up: no cap, they need the network and no sandbox');
      expect(kinds.skip(2), everyElement('systemd-run'));
      expect(runner.calls.skip(2), hasLength(3), reason: 'baseline and two mutants');
      for (final c in runner.calls.skip(2)) {
        expect(c.argv, containsAllInOrder(['-p', 'MemoryMax=${4 * gib}']));
        expect(c.argv.indexOf('bwrap'), greaterThan(c.argv.indexOf('--')));
      }
    });

    test('--memory-max sets the limit: probe and command line', () async {
      final runner = tests();
      expect(await run(runner, ['--memory-max', '512M', '--max-mutants', '1']), 0, reason: err.toString());
      expect(probed.single.maxBytes, 512 * mib);
      expect(runner.calls.last.argv, contains('MemoryMax=${512 * mib}'));
    });

    test('tmpfs mounts get --size: 1G by default, --tmpfs-size to change', () async {
      var runner = tests();
      await run(runner, ['--max-mutants', '1']);
      expect(runner.calls.last.argv, containsAllInOrder(['--size', '$gib', '--tmpfs', '/tmp']));
      expect((((results()['meta'] as Map)['isolation'] as Map)['tmpfsSizeBytes']), gib);
      runner = tests();
      await run(runner, ['--max-mutants', '1', '--tmpfs-size', '256M']);
      expect(runner.calls.last.argv, containsAllInOrder(['--size', '${256 * mib}', '--tmpfs', '/tmp']));
      expect((((results()['meta'] as Map)['isolation'] as Map)['tmpfsSizeBytes']), 256 * mib);
    });

    test('the cap is recorded in the report: size, no swap', () async {
      expect(await run(tests(), ['--max-mutants', '1']), 0, reason: err.toString());
      expect(memoryOf(results()), {'cap': 'cgroup', 'maxBytes': 4 * gib, 'swapMaxBytes': 0, 'reason': null});
      expect(File(p.join(out.path, 'summary.md')).readAsStringSync(), contains('memory: cgroup MemoryMax 4.0G, no swap'));
    });
  });

  group('fail closed', () {
    test('no usable systemd-run --user: exit 70 with the probe message, nothing is exported or run', () async {
      final runner = tests();
      final code = await run(runner, ['--max-mutants', '1'], (cap) async => throw MemoryCapUnavailable('systemd-run --user cannot start a scope: no bus. Pass --no-memory-cap'));
      expect(code, 70);
      expect(err.toString(), allOf(contains('cannot start a scope'), contains('--no-memory-cap')));
      expect(runner.calls, isEmpty);
      expect(File(p.join(out.path, 'results.json')).existsSync(), isFalse);
    });

    test('--no-memory-cap: proceeds without it (no probe, bwrap alone) and the report says so', () async {
      final runner = tests();
      final code = await run(runner, ['--no-memory-cap', '--max-mutants', '1'], (cap) async => throw StateError('must not be probed'));
      expect(code, 0, reason: err.toString());
      expect(runner.calls.any((c) => c.argv.first == 'systemd-run'), isFalse);
      expect(runner.calls.last.argv.first, 'bwrap');
      expect(memoryOf(results()), {'cap': 'none', 'maxBytes': null, 'swapMaxBytes': null, 'reason': '--no-memory-cap'});
      expect(File(p.join(out.path, 'summary.md')).readAsStringSync(), contains('memory: NOT CAPPED (--no-memory-cap)'));
    });

    test('--memory-max 0 is no cap either, recorded as such', () async {
      final runner = tests();
      expect(await run(runner, ['--memory-max', '0', '--max-mutants', '1'], (cap) async => throw StateError('must not be probed')), 0, reason: err.toString());
      expect(runner.calls.last.argv.first, 'bwrap');
      expect(memoryOf(results())['reason'], '--memory-max 0');
    });

    test('--no-sandbox: nothing to cap (no probe), recorded', () async {
      final runner = tests();
      expect(await run(runner, ['--no-sandbox', '--max-mutants', '1'], (cap) async => throw StateError('must not be probed')), 0, reason: err.toString());
      expect(runner.calls.any((c) => c.argv.first == 'systemd-run' || c.argv.first == 'bwrap'), isFalse);
      expect(memoryOf(results())['reason'], '--no-sandbox');
    });
  });

  group('what the cap reports', () {
    test('peaks are recorded: the baseline in the meta, every mutant in results.json and progress.jsonl; shown on the stderr end line', () async {
      expect(await run(tests(peak: 812 * mib), ['--max-mutants', '2']), 0, reason: err.toString());
      final r = results();
      expect(((r['meta'] as Map)['baseline'] as Map)['memoryPeakBytes'], 812 * mib);
      expect((r['mutants'] as List).map((m) => (m as Map)['memoryPeakBytes']), [812 * mib, 812 * mib]);
      final rows = [for (final l in File(p.join(out.path, 'progress.jsonl')).readAsLinesSync()) jsonDecode(l) as Map<String, dynamic>];
      expect(rows.skip(1).map((m) => m['memoryPeakBytes']), [812 * mib, 812 * mib]);
      expect(err.toString(), allOf(contains('baseline done in'), contains('peak 812M')));
      expect(err.toString(), contains(', peak 812M; elapsed'));
    });

    test('the marker is not left in anything the audit keeps', () async {
      await run(tests(), ['--max-mutants', '1']);
      expect(File(p.join(out.path, 'results.json')).readAsStringSync(), isNot(contains(memoryMarker)));
    });

    test('a mutant killed by the cgroup is resource-limit: counted, listed, outside the score, on the progress line; exit 0', () async {
      expect(await run(tests(oomOn: 'a <= b'), ['--max-mutants', '2']), 0, reason: err.toString());
      final r = results();
      final byStatus = {for (final m in r['mutants'] as List) (m as Map)['original']: m['status']};
      expect(byStatus, {'<': 'resource-limit', '>': 'survived'});
      expect((r['counts'] as Map)['resource-limit'], 1);
      expect(r['score'], 0, reason: 'killed 0 of (killed + survived) 1: the limit hit is no kill and not in the denominator');
      final limited = (r['mutants'] as List).cast<Map>().firstWhere((m) => m['status'] == 'resource-limit');
      expect(limited['killingTests'], isEmpty);
      expect(limited['memoryPeakBytes'], 4 * gib);
      expect(File(p.join(out.path, 'summary.md')).readAsStringSync(), contains('## Resource limits'));
      expect(err.toString(), contains('resource-limit (0 killing, 0 discounted)'));
      final rows = [for (final l in File(p.join(out.path, 'progress.jsonl')).readAsLinesSync()) jsonDecode(l) as Map<String, dynamic>];
      expect(rows.map((m) => m['status']).whereType<String>(), contains('resource-limit'));
    });

    test('a baseline that hits the limit stops the audit (65) and says to raise --memory-max', () async {
      final runner = FakeProcessRunner((call) {
        if (call.argv.length >= 2 && call.argv[1] == 'pub') return const ProcessOutcome(exitCode: 0);
        return ProcessOutcome(exitCode: 137, stdoutLines: passing().build(), stderr: marker(peak: 4 * gib, oom: 1));
      });
      expect(await run(runner, ['--setup-cmd', '', '--max-mutants', '1']), 65);
      expect(err.toString(), allOf(contains('memory limit'), contains('--memory-max'), contains('4.0G')));
      expect(runner.calls, hasLength(1));
    });
  });
}
