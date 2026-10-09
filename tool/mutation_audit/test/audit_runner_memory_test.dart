import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/fake_time.dart';
import 'support/fakes.dart';
import 'support/git_fixture.dart';

const source = 'bool lt(int a, int b) { return a < b; }\nbool gt(int a, int b) { return a > b; }\n';
const mib = 1024 * 1024;

Mutant mutant(String original, String mutated) {
  final at = source.indexOf(original);
  return Mutant(
    id: 'lib/a.dart:$at:relational:${mutated.hashCode.toRadixString(16)}',
    file: 'lib/a.dart',
    line: 1,
    column: at + 1,
    byteOffset: at,
    byteLength: original.length,
    operator: MutationOperator.relational,
    original: original,
    mutated: mutated,
  );
}

AuditConfig config({List<String> flaky = const [], int memoryMax = 2048 * mib}) => AuditConfig(
      repo: '/dev/checkout',
      sha: 'abc',
      files: const ['lib/a.dart'],
      testCmd: 'dart test',
      outDir: '/out',
      flakyTests: flaky,
      memoryMax: memoryMax,
      timeout: const Duration(seconds: 90),
    );

/// What the audit loop does with the memory facts of a run: the peak is
/// recorded and shown, a run that hit the limit is not a result, and the
/// baseline hitting it stops the audit.
void main() {
  late Directory root;
  late File file;
  late FakeTime time;
  late List<String> lines;

  setUp(() {
    root = scratch('mutaudit_mem_run_');
    file = File(p.join(root.path, 'lib/a.dart'))..createSync(recursive: true);
    file.writeAsStringSync(source);
    time = FakeTime();
    lines = [];
  });
  tearDown(() => root.deleteSync(recursive: true));

  ProgressReporter reporter() => ProgressReporter(now: time.now, write: lines.add, heartbeat: Duration.zero);
  List<String> messages() => [for (final l in lines) l.substring(l.indexOf(' ') + 1)];

  test('the baseline peak is in the summary and on the "baseline done" line', () async {
    final runner = FakeProcessRunner((c) => outcomeOf(passing(), memoryPeakBytes: 1200 * mib));
    final b = await AuditRunner(runner: runner, progress: reporter()).runBaseline(config(), root.path);
    expect(b.memoryPeakBytes, 1200 * mib);
    expect(messages().last, 'baseline done in 0.0s: 1 test passed, peak 1.2G');
  });

  test('a baseline that hit the limit aborts, says so, and suggests a higher --memory-max', () async {
    final runner = FakeProcessRunner(
        (c) => outcomeOf(passing(), exitCode: 137, oomKills: 1, memoryPeakBytes: 2048 * mib));
    await expectLater(
        AuditRunner(runner: runner).runBaseline(config(memoryMax: 2048 * mib), root.path),
        throwsA(isA<BaselineFailedError>().having(
            (e) => e.message, 'message', allOf(contains('memory limit'), contains('--memory-max'), contains('2.0G'), contains('higher')))));
  });

  test('the baseline hitting the limit takes precedence over what its stream shows', () async {
    final runner = FakeProcessRunner((c) => outcomeOf(failing('g fails'), exitCode: 137, oomKills: 1));
    await expectLater(AuditRunner(runner: runner).runBaseline(config(), root.path),
        throwsA(isA<BaselineFailedError>().having((e) => e.message, 'message', contains('memory limit'))));
  });

  test('the mutant records the peak of its run; the end line shows it', () async {
    var n = 0;
    final runner = FakeProcessRunner((c) => outcomeOf(passing(), memoryPeakBytes: (n++ == 0 ? 100 : 812) * mib));
    final run = await AuditRunner(runner: runner, progress: reporter()).run(
        config: config(), root: root.path, mutants: [mutant('<', '<=')]);
    expect(run.results.single.memoryPeakBytes, 812 * mib);
    expect(messages().last, matches(RegExp(r'^\[1/1\] survived \(0 killing, 0 discounted\) [\d.]+s, peak 812M; elapsed ')));
  });

  test('the mutant peak is the largest of its runs, reruns included', () async {
    var n = 0;
    final runner = FakeProcessRunner((c) {
      n++;
      if (n == 1) return outcomeOf(passing(), memoryPeakBytes: 50 * mib); // baseline
      if (n == 2) {
        return outcomeOf(StreamBuilder().loaded('test/a_test.dart').fail('test/a_test.dart', 'flaky one').done(success: false),
            exitCode: 1, memoryPeakBytes: 300 * mib);
      }
      return outcomeOf(StreamBuilder().loaded('test/a_test.dart').fail('test/a_test.dart', 'flaky one').done(success: false),
          exitCode: 1, memoryPeakBytes: 700 * mib); // the rerun
    });
    final run = await AuditRunner(runner: runner).run(
        config: config(flaky: ['test/a_test.dart::flaky one']), root: root.path, mutants: [mutant('<', '<=')]);
    expect(run.results.single.memoryPeakBytes, 700 * mib);
  });

  test('unknown peaks stay unknown: no number on the line, null in the result', () async {
    final runner = FakeProcessRunner((c) => outcomeOf(passing()));
    final run = await AuditRunner(runner: runner, progress: reporter()).run(
        config: config(), root: root.path, mutants: [mutant('<', '<=')]);
    expect(run.baseline.memoryPeakBytes, isNull);
    expect(run.results.single.memoryPeakBytes, isNull);
    expect(messages().last, isNot(contains('peak')));
  });

  test('a mutant run that hit the limit is resource-limit, the file is restored, and the audit goes on', () async {
    final runner = FakeProcessRunner((c) {
      if (file.readAsStringSync() == source) return outcomeOf(passing());
      if (file.readAsStringSync().contains('a <= b')) {
        return outcomeOf(failing('lt boundary'), exitCode: 137, oomKills: 1, memoryPeakBytes: 2048 * mib);
      }
      return outcomeOf(passing());
    });
    final run = await AuditRunner(runner: runner, progress: reporter())
        .run(config: config(), root: root.path, mutants: [mutant('<', '<='), mutant('>', '>=')]);
    expect(run.results.map((r) => r.classification.status), [MutantStatus.resourceLimit, MutantStatus.survived]);
    expect(run.results.first.memoryPeakBytes, 2048 * mib);
    expect(file.readAsStringSync(), source);
    expect(messages().where((m) => m.startsWith('[1/2] resource-limit')), [
      matches(RegExp(r'^\[1/2\] resource-limit \(0 killing, 0 discounted\) [\d.]+s, peak 2\.0G; elapsed ')),
    ]);
  });

  test('a rerun that hit the limit is shown as such and the failure stays unconfirmed', () async {
    var n = 0;
    final runner = FakeProcessRunner((c) {
      n++;
      if (n == 1) return outcomeOf(passing());
      final failed = StreamBuilder().loaded('test/a_test.dart').fail('test/a_test.dart', 'flaky one').done(success: false);
      return n == 2
          ? outcomeOf(failed, exitCode: 1)
          : outcomeOf(failed, exitCode: 137, oomKills: 1, memoryPeakBytes: 2048 * mib);
    });
    final run = await AuditRunner(runner: runner, progress: reporter()).run(
        config: config(flaky: ['test/a_test.dart::flaky one']), root: root.path, mutants: [mutant('<', '<=')]);
    expect(run.results.single.classification.status, MutantStatus.unconfirmed);
    expect(messages(), contains(matches(RegExp(r'rerun test/a_test\.dart::flaky one: exit 137 \(memory limit, peak 2\.0G\) in '))));
  });
}
