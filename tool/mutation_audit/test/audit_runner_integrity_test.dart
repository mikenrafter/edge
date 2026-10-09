import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/fakes.dart';
import 'support/git_fixture.dart';

const source = 'bool lt(int a, int b) { return a < b; }\nbool gt(int a, int b) { return a > b; }\n';

/// The audit loop with a sandbox: nothing is restored between runs, but after
/// every run (baseline, mutant, rerun) the host export is compared with what
/// it was before, and the audit stops when it is not the same.
void main() {
  late GitFixture fx;
  late String root;
  late String sha;

  setUp(() async {
    fx = await GitFixture.create({
      '.gitignore': 'build/\n',
      'lib/a.dart': source,
      'test/a_test.dart': '// faked\n',
    });
    root = fx.root;
    sha = await fx.head();
  });
  tearDown(() => fx.dispose());

  AuditConfig config() => const AuditConfig(
      repo: '/dev/checkout', sha: 'abc', files: ['lib/a.dart'], testCmd: 'dart test', outDir: '/out', timeout: Duration(seconds: 90));

  Mutant lt() {
    final at = source.indexOf('<');
    return Mutant(
      id: 'lib/a.dart:$at:relational:1',
      file: 'lib/a.dart',
      line: 1,
      column: at + 1,
      byteOffset: at,
      byteLength: 1,
      operator: MutationOperator.relational,
      original: '<',
      mutated: '<=',
    );
  }

  AuditRunner audit(FakeProcessRunner runner, {bool integrity = true, bool isolated = true}) => AuditRunner(
        runner: runner,
        integrity: integrity ? ExportIntegrity(root: root, pinnedSha: sha) : null,
        isolated: isolated,
      );

  String mutatedText() => File(p.join(root, 'lib/a.dart')).readAsStringSync();
  void write(String rel, String body) => File(p.join(root, rel))
    ..createSync(recursive: true)
    ..writeAsStringSync(body);

  /// Passes unless [breach] says otherwise for the call (the n-th, 0-based).
  FakeProcessRunner runner({void Function(int n)? breach, bool killWhenMutated = false}) {
    var n = 0;
    return FakeProcessRunner((call) {
      breach?.call(n++);
      if (killWhenMutated && mutatedText().contains('a <= b')) return outcomeOf(failing('lt boundary'), exitCode: 1);
      return outcomeOf(passing());
    });
  }

  Matcher stops(Object what) => throwsA(isA<ExportStateError>().having((e) => e.message, 'message', what is Matcher ? what : contains(what)));

  test('clean runs: results are recorded as isolated, and the mutated file is back', () async {
    final r = await audit(runner(killWhenMutated: true)).run(config: config(), root: root, mutants: [lt()]);
    expect(r.results.single.classification.status, MutantStatus.killed);
    expect(r.results.single.isolated, isTrue);
    expect(mutatedText(), source);
  });

  test('without a sandbox the result is not isolated and files left behind are not judged', () async {
    final r = await audit(runner(breach: (n) => write('leftover.txt', 'x$n')), isolated: false)
        .run(config: config(), root: root, mutants: [lt()]);
    expect(r.results.single.isolated, isFalse);
  });

  test('without a sandbox the pinned commit is still enforced after every run', () async {
    await expectLater(
        audit(runner(breach: (n) {
          if (n == 1) Process.runSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@e', 'commit', '-q', '--allow-empty', '-m', 'x'], workingDirectory: root);
        }), isolated: false)
            .run(config: config(), root: root, mutants: [lt()]),
        stops('HEAD'));
    expect(mutatedText(), source);
  });

  test('without a checker nothing is looked at', () async {
    final r = await audit(runner(breach: (n) => write('leftover.txt', 'x$n')), integrity: false, isolated: false)
        .run(config: config(), root: root, mutants: [lt()]);
    expect(r.results.single.isolated, isFalse);
  });

  test('a baseline run that wrote to the host stops the audit before any mutant is written', () async {
    var mutatedSeen = false;
    final fake = FakeProcessRunner((call) {
      if (mutatedText() != source) mutatedSeen = true;
      write('leftover.txt', 'x');
      return outcomeOf(passing());
    });
    await expectLater(audit(fake).run(config: config(), root: root, mutants: [lt()]), stops(allOf(contains('baseline'), contains('leftover.txt'))));
    expect(mutatedSeen, isFalse);
  });

  test('a mutant run that wrote to the host stops the audit, names the mutant, and the file is put back first', () async {
    final m = lt();
    await expectLater(
        audit(runner(breach: (n) {
          if (n == 1) write('leftover.txt', 'x');
        }, killWhenMutated: true))
            .run(config: config(), root: root, mutants: [m]),
        stops(allOf(contains(m.id), contains('leftover.txt'), contains('isolation did not hold'))));
    expect(mutatedText(), source);
  });

  test('a confirming rerun that wrote to the host stops the audit too', () async {
    var n = 0;
    final fake = FakeProcessRunner((call) {
      n++;
      if (n == 1) return outcomeOf(passing());
      if (n == 2) {
        // a failure without an error event: it must be re-run alone
        return outcomeOf(StreamBuilder().loaded('test/a_test.dart').fail('test/a_test.dart', 'flaky').done(success: false), exitCode: 1);
      }
      write('from_rerun.txt', 'x');
      return outcomeOf(passing());
    });
    await expectLater(
        audit(fake).run(config: config().withFlaky(['test/a_test.dart::flaky']), root: root, mutants: [lt()]),
        stops(allOf(contains('rerun'), contains('from_rerun.txt'))));
    expect(mutatedText(), source);
  });

  test('a run that moved HEAD stops the audit', () async {
    await expectLater(
        audit(runner(breach: (n) {
          if (n == 1) Process.runSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@e', 'commit', '-q', '--allow-empty', '-m', 'x'], workingDirectory: root);
        })).run(config: config(), root: root, mutants: [lt()]),
        stops('HEAD'));
  });

  test('a run that changed the mutated file again stops the audit', () async {
    await expectLater(
        audit(runner(breach: (n) {
          if (n == 1) write('lib/a.dart', 'bool lt(int a, int b) { return a == b; }\n');
        })).run(config: config(), root: root, mutants: [lt()]),
        stops('lib/a.dart'));
    expect(mutatedText(), source);
  });

  test('a run that wrote an ignored file in the export root stops the audit', () async {
    await expectLater(
        audit(runner(breach: (n) {
          if (n == 0) write('build/x.sqlite', 'db');
        })).run(config: config(), root: root, mutants: [lt()]),
        stops('build'));
  });

  test('a cancelled run is not judged', () async {
    final token = CancelToken();
    final fake = FakeProcessRunner((call) {
      token.cancel();
      write('leftover.txt', 'x');
      return const ProcessOutcome(exitCode: -15, cancelled: true);
    });
    await expectLater(audit(fake).run(config: config(), root: root, mutants: [lt()], cancel: token), throwsA(isA<InterruptedError>()));
  });

  test('with a sandbox the runner is not given a TMPDIR of its own (the sandbox owns /tmp); without one it is', () async {
    final boxed = runner();
    await audit(boxed).run(config: config(), root: root, mutants: [lt()]);
    expect(boxed.calls.map((c) => c.environment!.containsKey('TMPDIR')), everyElement(isFalse));
    final plain = runner();
    await audit(plain, integrity: false, isolated: false).run(config: config(), root: root, mutants: [lt()]);
    expect(plain.calls.map((c) => c.environment!['TMPDIR']), everyElement(isNotNull));
  });
}

extension on AuditConfig {
  AuditConfig withFlaky(List<String> keys) => AuditConfig(
      repo: repo, sha: sha, files: files, testCmd: testCmd, outDir: outDir, timeout: timeout, flakyTests: keys);
}
