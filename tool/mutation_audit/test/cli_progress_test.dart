import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/fake_time.dart';
import 'support/fakes.dart';
import 'support/git_fixture.dart';
import 'support/package_config.dart';

const lib = 'bool lt(int a, int b) => a < b;\nbool gt(int a, int b) => a > b;\n';

/// What an operator sees of a whole run: phase lines on stderr, the heartbeat,
/// and the partial progress.jsonl next to results that are still published
/// only on success.
void main() {
  late GitFixture fx;
  late Directory out;
  late String sha;
  late FakeTime time;
  final err = StringBuffer();
  final stdout_ = StringBuffer();

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
    time = FakeTime();
  });
  tearDown(() {
    fx.dispose();
    out.deleteSync(recursive: true);
  });

  List<String> args([List<String> extra = const []]) =>
      ['--repo', fx.root, '--sha', sha, '--files', 'lib/a.dart', '--test-cmd', 'dart test', '--out', out.path, ...extra];

  Future<int> run(FakeProcessRunner runner, [List<String> extra = const [], Stream<ProcessSignal>? interrupts]) => runCli(
        args(extra),
        runner: runner,
        out: stdout_,
        err: err,
        now: () => DateTime.utc(2026, 10, 9, 8),
        progressNow: time.now,
        heartbeatAlarm: time.alarm,
        interrupts: interrupts,
        sandboxProbe: () async => 'bubblewrap 9.9.9',
        sandboxEnvironment: {'HOME': '/nonexistent-home', 'PATH': '/usr/bin'},
      );

  /// Setup writes a package config in which `native` has a build hook (so there is a warm-up run);
  /// each run takes [takes] of fake time; "a <= b" fails the tests.
  FakeProcessRunner tests({Duration takes = const Duration(seconds: 10), int pid = 777}) => FakeProcessRunner((call) async {
        call.observer?.onStart?.call(pid);
        await time.advance(takes);
        if (call.argv.length >= 2 && call.argv[1] == 'pub') {
          Directory(p.join(call.cwd, '.dart_tool', 'native', 'hook')).createSync(recursive: true);
          File(p.join(call.cwd, '.dart_tool', 'native', 'hook', 'build.dart')).writeAsStringSync('');
          writeConfig(call.cwd, {'demo': ('../', 'lib/'), 'native': ('native', 'lib/')});
          return const ProcessOutcome(exitCode: 0);
        }
        if (call.argv.contains(warmupSuite)) return const ProcessOutcome(exitCode: 1);
        final src = File(p.join(call.cwd, 'lib/a.dart')).readAsStringSync();
        return src.contains('a <= b') ? outcomeOf(failing('lt boundary'), exitCode: 1) : outcomeOf(passing());
      });

  List<String> stderrLines() => err.toString().split('\n').where((l) => l.isNotEmpty).toList();
  List<String> messages() => [for (final l in stderrLines()) l.substring(l.indexOf(' ') + 1)];
  File progressFile() => File(p.join(out.path, 'progress.jsonl'));
  List<Map<String, dynamic>> progressRows() =>
      [for (final l in progressFile().readAsLinesSync()) jsonDecode(l) as Map<String, dynamic>];
  List<String> outFiles() => [for (final e in out.listSync()) p.basename(e.path)]..sort();

  test('phase lines on stderr, in order, each with the wall-clock time', () async {
    final runner = tests();
    expect(await run(runner, ['--sample', '1', '--seed', '7', '--heartbeat', '0']), 0, reason: err.toString());
    final lines = stderrLines();
    expect(lines.first, matches(RegExp(r'^2026-10-09T08:00:00Z export created: \S+ at ' '$sha\$')));
    // Mask what varies (the export path) and the clock, keep the wording and the order.
    final shape = [for (final m in messages()) m.replaceFirst(RegExp(r'export created: \S+ at'), 'export created: <path> at')];
    expect(shape, hasLength(11));
    expect(shape.take(9).toList(), [
      'export created: <path> at $sha',
      'setup start',
      'setup done in 10s',
      'warm-up start',
      'warm-up done in 10s',
      'detection done: 1 suites, 0 flagged, 0 allowlisted',
      'mutants generated: 2 candidates, 1 selected (seed 7)',
      'baseline start',
      'baseline done in 10s: 1 tests passed',
    ]);
    expect(shape[9], matches(RegExp(r"^\[1/1\] lib/a\.dart:\d+:relational:[0-9a-f]+ lib/a\.dart:1 relational '.'→'.+'$")));
    expect(shape[10], matches(RegExp(r'^\[1/1\] (killed|survived) \(\d killing, 0 discounted\) 10s; elapsed 10s; ETA 0\.0s$')));
    // The timestamps are the injected clock's: 10 s per run.
    expect(lines[1], startsWith('2026-10-09T08:00:00Z setup start'));
    expect(lines[2], startsWith('2026-10-09T08:00:10Z setup done'));
    expect(lines[4], startsWith('2026-10-09T08:00:20Z warm-up done'));
    expect(stdout_.toString(), isNot(contains('setup start')), reason: 'progress is stderr only');
  });

  test('--no-sandbox: no warm-up lines', () async {
    expect(await run(tests(), ['--no-sandbox', '--max-mutants', '1']), 0, reason: err.toString());
    expect(messages().where((m) => m.startsWith('warm-up')), isEmpty);
    expect(messages(), contains('setup start'));
  });

  test('--setup-cmd "": no setup lines either', () async {
    expect(await run(tests(), ['--setup-cmd', '', '--no-sandbox', '--max-mutants', '1']), 0, reason: err.toString());
    expect(messages().where((m) => m.startsWith('setup')), isEmpty);
  });

  group('heartbeat', () {
    test('defaults to 60 s: a long setup is not silent, with the pid', () async {
      expect(await run(tests(takes: const Duration(seconds: 130), pid: 31337), ['--no-sandbox', '--max-mutants', '1']), 0, reason: err.toString());
      final beats = messages().where((m) => m.startsWith('…')).toList();
      expect(beats.take(2), [
        '… still running setup for 1m00s (pid 31337): 0 tests done (0 passed, 0 failed)',
        '… still running setup for 2m00s (pid 31337): 0 tests done (0 passed, 0 failed)',
      ]);
      expect(beats.where((b) => b.contains('baseline')), hasLength(2));
      expect(beats.where((b) => b.contains('mutant [1/1]')), hasLength(2));
    });

    test('--heartbeat 30 changes the interval', () async {
      expect(await run(tests(takes: const Duration(seconds: 65)), ['--heartbeat', '30', '--no-sandbox', '--setup-cmd', '', '--max-mutants', '1']), 0,
          reason: err.toString());
      expect(messages().where((m) => m.contains('still running baseline')), [
        '… still running baseline for 30s (pid 777): 0 tests done (0 passed, 0 failed)',
        '… still running baseline for 1m00s (pid 777): 0 tests done (0 passed, 0 failed)',
      ]);
    });

    test('--heartbeat 0 disables it', () async {
      expect(await run(tests(takes: const Duration(hours: 1)), ['--heartbeat', '0', '--no-sandbox', '--max-mutants', '1']), 0, reason: err.toString());
      expect(err.toString(), isNot(contains('still running')));
      expect(messages(), contains(startsWith('mutants generated')), reason: 'the phase lines stay');
    });

    test('no timer outlives the run', () async {
      expect(await run(tests(takes: const Duration(seconds: 100)), ['--no-sandbox', '--max-mutants', '1']), 0, reason: err.toString());
      expect(time.pending, 0);
    });
  });

  group('progress.jsonl', () {
    test('meta first, then one line per mutant; results.json and summary.md published as before; nothing else left', () async {
      expect(await run(tests(), ['--no-sandbox', '--setup-cmd', '', '--max-mutants', '2']), 0, reason: err.toString());
      final rows = progressRows();
      expect(rows, hasLength(3));
      expect(rows.every((r) => r['partial'] == true), isTrue);
      expect(rows[0]['type'], 'meta');
      expect(rows[0]['sha'], sha);
      expect(rows[0]['seed'], isNull);
      expect(rows[0]['selected'], 2);
      expect(rows[0]['candidates'], 2);
      expect(rows.skip(1).map((r) => r['index']), [1, 2]);
      expect(rows.skip(1).map((r) => r['total']), [2, 2]);
      expect(rows.skip(1).map((r) => r['status']), containsAll(['killed', 'survived']));
      final killed = rows.firstWhere((r) => r['status'] == 'killed');
      expect(killed['killers'], [
        {'test': 'test/a_test.dart::lt boundary', 'kind': 'assertion'}
      ]);
      expect(killed['discounted'], isEmpty);
      expect(killed['operator'], 'relational');
      expect(killed['file'], 'lib/a.dart');
      expect(killed['line'], 1);
      expect(killed['durationMs'], 10000);
      expect(outFiles(), ['progress.jsonl', 'results.json', 'summary.md']);
      final results = jsonDecode(File(p.join(out.path, 'results.json')).readAsStringSync()) as Map<String, dynamic>;
      expect((results['mutants'] as List), hasLength(2));
    });

    test('a cancel keeps what was written so far and publishes no results', () async {
      final interrupts = StreamController<ProcessSignal>();
      var mutantRuns = 0;
      final runner = FakeProcessRunner((call) async {
        final src = File(p.join(call.cwd, 'lib/a.dart')).readAsStringSync();
        if (src == lib) return outcomeOf(passing());
        if (++mutantRuns == 2) {
          interrupts.add(ProcessSignal.sigint);
          await call.cancel!.whenCancelled;
          return outcomeOf(StreamBuilder().loaded('test/a_test.dart'), exitCode: -15, cancelled: true);
        }
        return outcomeOf(passing());
      });
      final code = await run(runner, ['--no-sandbox', '--setup-cmd', '', '--max-mutants', '2'], interrupts.stream);
      expect(code, 130, reason: err.toString());
      final rows = progressRows();
      expect(rows.map((r) => r['type']), ['meta', 'mutant']);
      expect(rows.last['index'], 1);
      expect(outFiles(), ['progress.jsonl'], reason: 'no results.json, summary.md or temporaries');
      await interrupts.close();
    });

    test('a failed baseline leaves the meta line (what was about to run) next to baseline.log', () async {
      final runner = FakeProcessRunner((call) => outcomeOf(failing('already broken'), exitCode: 1));
      expect(await run(runner, ['--no-sandbox', '--setup-cmd', '', '--max-mutants', '1']), 65);
      expect(progressRows().map((r) => r['type']), ['meta']);
      expect(outFiles(), containsAll(['progress.jsonl', 'baseline.log']));
    });

    test('an older progress.jsonl does not survive into the new run', () async {
      progressFile().writeAsStringSync('{"type":"mutant","index":99}\n');
      expect(await run(tests(), ['--no-sandbox', '--setup-cmd', '', '--max-mutants', '1']), 0, reason: err.toString());
      expect(progressRows().map((r) => r['index']), [null, 1]);
    });
  });
}
