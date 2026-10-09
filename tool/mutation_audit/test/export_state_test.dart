import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/fakes.dart';
import 'support/git_fixture.dart';

/// Finding 3 (review round 4): the files a test run leaves in the export must
/// not reach the next run (a mutant's, or a confirming rerun).
const source = 'bool lt(int a, int b) { return a < b; }\nbool gt(int a, int b) { return a > b; }\n';

void main() {
  late GitFixture fx;
  late String root;

  setUp(() async {
    fx = await GitFixture.create({
      'pubspec.yaml': 'name: demo\n',
      '.gitignore': '.dart_tool/\nbuild/\ngen/\n*.log\n',
      'lib/a.dart': source,
      'test/fixture.txt': 'original fixture\n',
      'test/a_test.dart': '// faked\n',
    });
    root = fx.root;
    // Ignored files that exist before the audit starts.
    File(p.join(root, 'gen/seed.bin'))
      ..createSync(recursive: true)
      ..writeAsStringSync('seed');
    File(p.join(root, '.dart_tool/cache.bin'))
      ..createSync(recursive: true)
      ..writeAsStringSync('cache');
  });
  tearDown(() => fx.dispose());

  String at(String rel) => p.join(root, rel);
  void write(String rel, String body) => File(at(rel))
    ..createSync(recursive: true)
    ..writeAsStringSync(body);

  ExportStateGuard guard({List<String> caches = const []}) => ExportStateGuard(root: root, cacheDirs: caches);

  group('snapshot', () {
    test('a clean export passes; the default caches may hold anything', () async {
      write('.dart_tool/package_config.json', '{}');
      write('build/out.o', 'x');
      write('.flutter-plugins-dependencies', '{}');
      await guard().snapshot();
    });

    test('a modified tracked file refuses the audit, naming the file', () async {
      write('test/fixture.txt', 'changed by setup\n');
      await expectLater(guard().snapshot(),
          throwsA(isA<ExportStateError>().having((e) => e.message, 'message', contains('test/fixture.txt'))));
    });

    test('an untracked file that is not ignored refuses the audit', () async {
      write('stray.txt', 'x');
      await expectLater(guard().snapshot(),
          throwsA(isA<ExportStateError>().having((e) => e.message, 'message', contains('stray.txt'))));
    });
  });

  group('restore', () {
    late ExportStateGuard g;
    setUp(() async {
      g = guard();
      await g.snapshot();
    });

    test('nothing changed: nothing restored', () async {
      expect(await g.restore(), 0);
    });

    test('a modified, a deleted and a staged tracked file are put back', () async {
      write('test/fixture.txt', 'changed\n');
      File(at('pubspec.yaml')).deleteSync();
      write('lib/a.dart', 'changed\n');
      await fx.git(['add', 'lib/a.dart']);
      expect(await g.restore(), 3);
      expect(File(at('test/fixture.txt')).readAsStringSync(), 'original fixture\n');
      expect(File(at('pubspec.yaml')).readAsStringSync(), 'name: demo\n');
      expect(File(at('lib/a.dart')).readAsStringSync(), source);
      expect(await fx.status(), isEmpty);
    });

    test('untracked files and directories (empty ones too) are removed, but not the caches', () async {
      write('junk.txt', 'x');
      write('deep/er/junk.txt', 'x');
      Directory(at('empty/dir')).createSync(recursive: true);
      write('.dart_tool/new.bin', 'kept');
      expect(await g.restore(), greaterThanOrEqualTo(2));
      expect(File(at('junk.txt')).existsSync(), isFalse);
      expect(Directory(at('deep')).existsSync(), isFalse);
      expect(Directory(at('empty')).existsSync(), isFalse);
      expect(File(at('.dart_tool/new.bin')).existsSync(), isTrue);
    });

    test('a cache name is anchored at the root: lib/build/x is not a cache', () async {
      write('lib/build/x.txt', 'x');
      expect(await g.restore(), 1);
      expect(File(at('lib/build/x.txt')).existsSync(), isFalse);
    });

    test('files in a cache directory may change', () async {
      write('.dart_tool/cache.bin', 'different');
      write('build/new.o', 'x');
      expect(await g.restore(), 0);
    });

    test('keep: the mutated file stays as it is, everything else is restored', () async {
      write('lib/a.dart', 'MUTATED\n');
      write('test/fixture.txt', 'changed\n');
      expect(await g.restore(keep: {'lib/a.dart'}), 1);
      expect(File(at('lib/a.dart')).readAsStringSync(), 'MUTATED\n');
      expect(File(at('test/fixture.txt')).readAsStringSync(), 'original fixture\n');
    });

    test('a new ignored file outside the caches is removed and counted', () async {
      write('gen/new.out', 'x');
      write('run.log', 'x');
      expect(await g.restore(), 2);
      expect(File(at('gen/new.out')).existsSync(), isFalse);
      expect(File(at('run.log')).existsSync(), isFalse);
      expect(File(at('gen/seed.bin')).readAsStringSync(), 'seed');
    });

    test('a changed ignored file outside the caches cannot be restored: the audit is aborted', () async {
      write('gen/seed.bin', 'tampered');
      await expectLater(g.restore(),
          throwsA(isA<ExportStateError>().having((e) => e.message, 'message', contains('gen/seed.bin'))));
    });

    test('a removed ignored file outside the caches cannot be restored either', () async {
      File(at('gen/seed.bin')).deleteSync();
      await expectLater(g.restore(), throwsA(isA<ExportStateError>()));
    });

    test('HEAD that moved (a test committed) aborts: the tree cannot be put back to the pinned commit', () async {
      write('test/fixture.txt', 'changed\n');
      await fx.git(['add', '-A']);
      await fx.git(['commit', '-q', '-m', 'sneaky']);
      await expectLater(g.restore(), throwsA(isA<ExportStateError>().having((e) => e.message, 'message', contains('HEAD'))));
    });
  });

  test('--cache-dir adds to the defaults: a declared directory may change', () async {
    write('gen/more.bin', 'x');
    final g = guard(caches: ['gen']);
    await g.snapshot();
    write('gen/seed.bin', 'changed');
    write('gen/other.bin', 'y');
    expect(await g.restore(), 0);
  });

  group('the audit runner', () {
    Mutant mutant() {
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

    AuditConfig config({List<String> flaky = const []}) => AuditConfig(
        repo: '/dev/checkout', sha: 'abc', files: const ['lib/a.dart'], testCmd: 'dart test', outDir: '/out', flakyTests: flaky);

    /// What a run sees of the leftovers of the runs before it.
    final seen = <Map<String, Object?>>[];
    FakeProcessRunner leaving() => FakeProcessRunner((call) {
          final tmp = call.environment?['TMPDIR'];
          seen.add({
            'fixture': File(at('test/fixture.txt')).readAsStringSync(),
            'stray': File(at('stray.txt')).existsSync(),
            'ignored': File(at('gen/run.out')).existsSync(),
            'tmp': tmp,
            'tmpExists': tmp != null && Directory(tmp).existsSync(),
            'tmpEntries': tmp != null && Directory(tmp).existsSync() ? Directory(tmp).listSync().length : -1,
          });
          File(at('test/fixture.txt')).writeAsStringSync('dirty\n');
          File(at('stray.txt')).writeAsStringSync('x');
          File(at('gen/run.out')).writeAsStringSync('x');
          if (tmp != null && Directory(tmp).existsSync()) File(p.join(tmp, 'left.txt')).writeAsStringSync('x');
          return outcomeOf(passing());
        });
    setUp(seen.clear);

    test('a baseline that dirties the export aborts the audit (the snapshot is not clean)', () async {
      await expectLater(AuditRunner(runner: leaving(), stateGuard: guard()).run(config: config(), root: root, mutants: [mutant()]),
          throwsA(isA<ExportStateError>()));
    });

    FakeProcessRunner leavingAfterBaseline() {
      var n = 0;
      return FakeProcessRunner((call) {
        final first = n++ == 0;
        final tmp = call.environment?['TMPDIR'];
        if (!first) {
          seen.add({
            'fixture': File(at('test/fixture.txt')).readAsStringSync(),
            'stray': File(at('stray.txt')).existsSync(),
            'ignored': File(at('gen/run.out')).existsSync(),
            'tmp': tmp,
            'tmpEntries': tmp != null && Directory(tmp).existsSync() ? Directory(tmp).listSync().length : -1,
          });
          File(at('test/fixture.txt')).writeAsStringSync('dirty\n');
          File(at('stray.txt')).writeAsStringSync('x');
          File(at('gen/run.out')).writeAsStringSync('x');
          if (tmp != null && Directory(tmp).existsSync()) File(p.join(tmp, 'left.txt')).writeAsStringSync('x');
        } else {
          seen.add({'tmp': tmp});
        }
        return outcomeOf(passing());
      });
    }

    test('mutant runs: every run starts from the pinned state, with a fresh empty TMPDIR', () async {
      final result = await AuditRunner(runner: leavingAfterBaseline(), stateGuard: guard())
          .run(config: config(), root: root, mutants: [mutant(), mutant()]);
      final runs = seen.sublist(1);
      expect(runs, hasLength(2));
      for (final r in runs) {
        expect(r['fixture'], 'original fixture\n');
        expect(r['stray'], isFalse);
        expect(r['ignored'], isFalse);
        expect(r['tmpEntries'], 0, reason: 'a fresh, empty per-run directory');
      }
      expect(seen.map((s) => s['tmp']).toSet(), hasLength(3), reason: 'a different TMPDIR for each run');
      for (final t in seen.map((s) => s['tmp'] as String?)) {
        expect(t, isNotNull);
        expect(p.isWithin(root, t!), isFalse, reason: 'outside the export');
        expect(Directory(t).existsSync(), isFalse, reason: 'deleted after the run');
      }
      expect(result.results.map((r) => r.stateRestored), [3, 3], reason: 'fixture, stray.txt, gen/run.out');
      expect(await fx.status(), isEmpty);
      expect(File(at('lib/a.dart')).readAsStringSync(), source);
    });

    test('a confirming rerun starts clean too, and the mutant is still applied during it', () async {
      final saw = <String>[];
      var n = 0;
      final runner = FakeProcessRunner((call) {
        final i = n++;
        if (i == 0) return outcomeOf(passing());
        saw.add('${File(at('lib/a.dart')).readAsStringSync().contains('a <= b')}|'
            '${File(at('test/fixture.txt')).readAsStringSync().trim()}|${File(at('stray.txt')).existsSync()}');
        File(at('test/fixture.txt')).writeAsStringSync('dirty\n');
        File(at('stray.txt')).writeAsStringSync('x');
        // The first mutant run fails without an error event: ambiguous, re-run alone.
        if (i == 1) {
          return outcomeOf(StreamBuilder().loaded('test/a_test.dart').test('test/a_test.dart', 'lt', result: TestResult.failure).done(success: false),
              exitCode: 1);
        }
        return outcomeOf(StreamBuilder().loaded('test/a_test.dart').fail('test/a_test.dart', 'lt').done(success: false), exitCode: 1);
      });
      final r = await AuditRunner(runner: runner, stateGuard: guard()).run(config: config(), root: root, mutants: [mutant()]);
      expect(saw, ['true|original fixture|false', 'true|original fixture|false'],
          reason: 'mutated both times, clean both times');
      expect(r.results.single.stateRestored, greaterThanOrEqualTo(4));
      expect(File(at('lib/a.dart')).readAsStringSync(), source);
    });

    test('an ignored file outside the caches that a run changed aborts the audit (exit 70 in the CLI)', () async {
      var n = 0;
      final runner = FakeProcessRunner((call) {
        if (n++ > 0) File(at('gen/seed.bin')).writeAsStringSync('tampered');
        return outcomeOf(passing());
      });
      await expectLater(AuditRunner(runner: runner, stateGuard: guard()).run(config: config(), root: root, mutants: [mutant(), mutant()]),
          throwsA(isA<ExportStateError>()));
      expect(runner.calls, hasLength(2), reason: 'no run after the abort');
      expect(File(at('lib/a.dart')).readAsStringSync(), source, reason: 'the mutated file was still put back');
    });

    test('without a guard nothing changes (and the TMPDIR is still per run)', () async {
      final runner = FakeProcessRunner((call) => outcomeOf(passing()));
      final r = await AuditRunner(runner: runner).run(config: config(), root: root, mutants: [mutant()]);
      expect(r.results.single.stateRestored, 0);
      expect(runner.calls.map((c) => c.environment!['TMPDIR']).toSet(), hasLength(2), reason: 'baseline and mutant: one directory each');
    });
  });
}
