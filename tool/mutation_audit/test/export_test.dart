import 'dart:async';
import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/git_fixture.dart';

void main() {
  late GitFixture fx;
  late String firstSha;
  late String secondSha;
  final made = <Directory>[];

  setUp(() async {
    fx = await GitFixture.create({'lib/a.dart': 'one\n', 'pubspec.yaml': 'name: demo\n'});
    firstSha = await fx.head();
    secondSha = await fx.commit({'lib/a.dart': 'two\n'}, 'second');
  });
  tearDown(() {
    for (final d in made) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
    made.clear();
    fx.dispose();
  });

  group('DisposableExport.create', () {
    test('exports the pinned commit, not the working tree or HEAD', () async {
      File(p.join(fx.root, 'lib/a.dart')).writeAsStringSync('dirty\n');
      final e = await DisposableExport.create(repo: fx.root, sha: firstSha);
      addTearDown(e.dispose);
      expect(File(p.join(e.path, 'lib/a.dart')).readAsStringSync(), 'one\n');
      expect(e.sha, firstSha);
      expect(e.repo, fx.root);
    });

    test('resolves a branch or short sha to the full commit', () async {
      final byBranch = await DisposableExport.create(repo: fx.root, sha: 'main');
      addTearDown(byBranch.dispose);
      expect(byBranch.sha, secondSha);
      final byShort = await DisposableExport.create(repo: fx.root, sha: firstSha.substring(0, 8));
      addTearDown(byShort.dispose);
      expect(byShort.sha, firstSha);
      expect(byShort.sha, hasLength(40));
    });

    test('the export lives outside the developer checkout', () async {
      final e = await DisposableExport.create(repo: fx.root, sha: firstSha);
      addTearDown(e.dispose);
      expect(p.isWithin(fx.root, e.path), isFalse);
      expect(p.equals(fx.root, e.path), isFalse);
    });

    test('the developer checkout is left exactly as it was', () async {
      File(p.join(fx.root, 'lib/a.dart')).writeAsStringSync('dirty\n');
      final headBefore = await fx.head();
      final statusBefore = await fx.status();
      final branchBefore = await fx.git(['rev-parse', '--abbrev-ref', 'HEAD']);
      final e = await DisposableExport.create(repo: fx.root, sha: firstSha);
      await e.dispose();
      expect(await fx.head(), headBefore);
      expect(await fx.status(), statusBefore);
      expect(await fx.git(['rev-parse', '--abbrev-ref', 'HEAD']), branchBefore);
      expect(await fx.git(['stash', 'list']), isEmpty);
      expect(File(p.join(fx.root, 'lib/a.dart')).readAsStringSync(), 'dirty\n');
    });

    test('it is a registered worktree while it lives, and gone after dispose', () async {
      final e = await DisposableExport.create(repo: fx.root, sha: firstSha);
      expect(await fx.worktrees(), contains(e.path));
      await e.dispose();
      expect(Directory(e.path).existsSync(), isFalse);
      expect(await fx.worktrees(), isNot(contains(e.path)));
    });

    test('dispose is idempotent and survives a directory that is already gone', () async {
      final e = await DisposableExport.create(repo: fx.root, sha: firstSha);
      Directory(e.path).deleteSync(recursive: true);
      await e.dispose();
      await e.dispose();
      expect(await fx.worktrees(), isNot(contains(e.path)));
    });

    test('an unknown sha fails cleanly and leaves nothing behind', () async {
      final parent = scratch('mutaudit_parent_');
      made.add(parent);
      await expectLater(
          DisposableExport.create(repo: fx.root, sha: 'deadbeefdeadbeef', parentDir: parent.path),
          throwsA(isA<ExportFailed>()));
      expect(parent.listSync(), isEmpty);
      expect(await fx.worktrees(), isNot(contains(parent.path)));
    });

    test('a directory that is not a git repository fails cleanly', () async {
      final notRepo = scratch('mutaudit_notrepo_');
      made.add(notRepo);
      await expectLater(DisposableExport.create(repo: notRepo.path, sha: 'HEAD'), throwsA(isA<ExportFailed>()));
    });

    test('parentDir decides where it goes', () async {
      final parent = scratch('mutaudit_parent_');
      made.add(parent);
      final e = await DisposableExport.create(repo: fx.root, sha: firstSha, parentDir: parent.path);
      addTearDown(e.dispose);
      expect(p.isWithin(parent.path, e.path), isTrue);
    });
  });

  group('the developer checkout is never the target', () {
    Future<void> refuses(String exportDir) async {
      final before = File(p.join(fx.root, 'lib/a.dart')).readAsStringSync();
      await expectLater(
          DisposableExport.create(repo: fx.root, sha: firstSha, exportDir: exportDir),
          throwsA(isA<UnsafeExportTarget>()));
      expect(File(p.join(fx.root, 'lib/a.dart')).readAsStringSync(), before);
      expect(Directory(p.join(fx.root, 'lib')).existsSync(), isTrue);
    }

    test('the checkout itself', () => refuses(fx.root));
    test('a directory inside it', () => refuses(p.join(fx.root, 'export_here')));
    test('its parent, which contains it', () => refuses(fx.parent));
    test('a spelling of it that is not the same string', () => refuses(p.join(fx.root, 'lib', '..')));

    test('a symlink that points at it', () async {
      final link = p.join(fx.parent, 'link_to_repo');
      Link(link).createSync(fx.root);
      await refuses(link);
    });

    test('a fresh directory elsewhere is accepted', () async {
      final target = p.join(scratch('mutaudit_elsewhere_').path, 'x');
      made.add(Directory(p.dirname(target)));
      final e = await DisposableExport.create(repo: fx.root, sha: firstSha, exportDir: target);
      addTearDown(e.dispose);
      expect(e.path, target);
      expect(File(p.join(target, 'lib/a.dart')).existsSync(), isTrue);
    });
  });

  group('withDisposableExport', () {
    test('runs the body in the export and removes it afterwards', () async {
      String? seen;
      final result = await withDisposableExport<int>(
          repo: fx.root,
          sha: firstSha,
          body: (e) async {
            seen = e.path;
            expect(Directory(e.path).existsSync(), isTrue);
            return 42;
          });
      expect(result, 42);
      expect(Directory(seen!).existsSync(), isFalse);
      expect(await fx.worktrees(), isNot(contains(seen)));
    });

    test('removes it when the body throws, and rethrows', () async {
      String? seen;
      await expectLater(
          withDisposableExport<void>(
              repo: fx.root,
              sha: firstSha,
              body: (e) async {
                seen = e.path;
                throw StateError('boom');
              }),
          throwsA(isA<StateError>()));
      expect(Directory(seen!).existsSync(), isFalse);
      expect(await fx.worktrees(), isNot(contains(seen)));
    });

    test('removes it on Ctrl-C, abandons the body and throws InterruptedError', () async {
      final interrupts = StreamController<ProcessSignal>();
      final started = Completer<String>();
      final never = Completer<void>();
      final run = withDisposableExport<void>(
          repo: fx.root,
          sha: firstSha,
          interrupts: interrupts.stream,
          body: (e) async {
            started.complete(e.path);
            await never.future;
          });
      final path = await started.future;
      expect(Directory(path).existsSync(), isTrue);
      interrupts.add(ProcessSignal.sigint);
      await expectLater(run, throwsA(isA<InterruptedError>()));
      expect(Directory(path).existsSync(), isFalse);
      expect(await fx.worktrees(), isNot(contains(path)));
      await interrupts.close();
    });

    test('an unsafe target is refused before the body runs', () async {
      var ran = false;
      await expectLater(
          withDisposableExport<void>(
              repo: fx.root,
              sha: firstSha,
              exportDir: fx.root,
              body: (e) async {
                ran = true;
              }),
          throwsA(isA<UnsafeExportTarget>()));
      expect(ran, isFalse);
    });
  });

  group('resolveDependencyConfig', () {
    late Directory export;
    setUp(() {
      export = scratch('mutaudit_deps_');
      made.add(export);
    });

    void write(String name, String body) => File(p.join(export.path, name)).writeAsStringSync(body);

    const gitLock = '''
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
  collection:
    dependency: transitive
    description:
      name: collection
      url: "https://pub.dev"
    source: hosted
    version: "1.19.1"
''';

    test('no lock, no overrides: nothing recorded, nothing refused', () async {
      write('pubspec.yaml', 'name: demo\n');
      final c = await resolveDependencyConfig(export.path, repo: fx.root);
      expect(c.lockSha256, isNull);
      expect(c.overridesFileSha256, isNull);
      expect(c.pathOverrides, isEmpty);
      expect(c.gitDependencies, isEmpty);
    });

    test('a git pin is recorded with its resolved ref; the lock is hashed', () async {
      write('pubspec.yaml', 'name: demo\n');
      write('pubspec.lock', gitLock);
      final c = await resolveDependencyConfig(export.path, repo: fx.root);
      expect(c.lockSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(c.gitDependencies.single.package, 'analytics');
      expect(c.gitDependencies.single.url, 'https://github.com/OpenStrap/analytics');
      expect(c.gitDependencies.single.resolvedRef, '0123456789abcdef0123456789abcdef01234567');
      expect(c.toJson()['gitDependencies'], isA<List<Object?>>());
    });

    test('the same lock hashes the same, another lock differently', () async {
      write('pubspec.yaml', 'name: demo\n');
      write('pubspec.lock', gitLock);
      final a = await resolveDependencyConfig(export.path, repo: fx.root);
      final b = await resolveDependencyConfig(export.path, repo: fx.root);
      write('pubspec.lock', '$gitLock\n# changed\n');
      final c = await resolveDependencyConfig(export.path, repo: fx.root);
      expect(a.lockSha256, b.lockSha256);
      expect(a.lockSha256, isNot(c.lockSha256));
    });

    test('a git package whose description has path "." is a git pin, not a path override', () async {
      // `path: "."` there is the folder inside the git repository.
      write('pubspec.yaml', 'name: demo\n');
      write('pubspec.lock', gitLock);
      final c = await resolveDependencyConfig(export.path, repo: fx.root);
      expect(c.pathOverrides, isEmpty);
      expect(c.gitDependencies, hasLength(1));
    });

    test('the real edge lock file is not refused', () async {
      final real = File('../../pubspec.lock');
      if (!real.existsSync()) {
        markTestSkipped('run from tool/mutation_audit inside the edge checkout');
        return;
      }
      write('pubspec.yaml', 'name: demo\n');
      write('pubspec.lock', real.readAsStringSync());
      final c = await resolveDependencyConfig(export.path, repo: fx.root);
      expect(c.pathOverrides, isEmpty);
      expect(c.gitDependencies, isNotEmpty, reason: 'the sibling packages are pinned from git');
    });

    test('pubspec_overrides.yaml with a path is refused, and hashed when allowed', () async {
      write('pubspec.yaml', 'name: demo\n');
      write('pubspec_overrides.yaml', 'dependency_overrides:\n  analytics:\n    path: ../analytics\n');
      await expectLater(resolveDependencyConfig(export.path, repo: fx.root), throwsA(isA<PathOverrideRefused>()));
      final c = await resolveDependencyConfig(export.path,
          repo: fx.root, allowedOverrides: [p.join(fx.parent, 'analytics')]);
      expect(c.overridesFileSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(c.pathOverrides.single.package, 'analytics');
      expect(c.pathOverrides.single.source, 'pubspec_overrides.yaml');
    });

    test('the allowed path may be given relative to the repo', () async {
      write('pubspec.yaml', 'name: demo\n');
      write('pubspec_overrides.yaml', 'dependency_overrides:\n  analytics:\n    path: ../analytics\n');
      final c = await resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: ['../analytics']);
      expect(c.pathOverrides, hasLength(1));
    });

    test('an override to somewhere else than the allowed path is still refused', () async {
      write('pubspec.yaml', 'name: demo\n');
      write('pubspec_overrides.yaml', 'dependency_overrides:\n  analytics:\n    path: ../other\n');
      await expectLater(
          resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: ['../analytics']),
          throwsA(isA<PathOverrideRefused>()));
    });

    test('every override must be allowed, not just one', () async {
      write('pubspec.yaml', 'name: demo\n');
      write('pubspec_overrides.yaml',
          'dependency_overrides:\n  analytics:\n    path: ../analytics\n  protocol:\n    path: ../protocol\n');
      await expectLater(
          resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: ['../analytics']),
          throwsA(isA<PathOverrideRefused>()));
    });

    test('dependency_overrides with a path in pubspec.yaml is refused', () async {
      write('pubspec.yaml', 'name: demo\ndependency_overrides:\n  analytics:\n    path: ../analytics\n');
      await expectLater(resolveDependencyConfig(export.path, repo: fx.root), throwsA(isA<PathOverrideRefused>()));
    });

    test('dependency_overrides that are not paths are fine', () async {
      write('pubspec.yaml', 'name: demo\ndependency_overrides:\n  collection: 1.19.1\n');
      final c = await resolveDependencyConfig(export.path, repo: fx.root);
      expect(c.pathOverrides, isEmpty);
    });

    test('a path package in the lock file is a path override too', () async {
      write('pubspec.yaml', 'name: demo\n');
      write('pubspec.lock', '''
packages:
  analytics:
    dependency: "direct main"
    description:
      path: "../analytics"
      relative: true
    source: path
    version: "0.1.0"
''');
      await expectLater(resolveDependencyConfig(export.path, repo: fx.root), throwsA(isA<PathOverrideRefused>()));
      final c = await resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: ['../analytics']);
      expect(c.pathOverrides.single.source, 'pubspec.lock');
    });
  });
}
