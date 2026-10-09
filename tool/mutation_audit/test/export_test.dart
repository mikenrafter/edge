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

    group('every creation path, not just an explicit exportDir', () {
      test('a parentDir inside the checkout is refused, and nothing is created there', () async {
        final inside = Directory(p.join(fx.root, 'tmp_here'))..createSync();
        final before = inside.listSync().length;
        await expectLater(DisposableExport.create(repo: fx.root, sha: firstSha, parentDir: inside.path),
            throwsA(isA<UnsafeExportTarget>()));
        expect(inside.listSync(), hasLength(before));
        expect(await fx.worktrees(), isNot(contains('mutation_audit_')));
      });

      test('the checkout itself as parentDir', () async {
        await expectLater(DisposableExport.create(repo: fx.root, sha: firstSha, parentDir: fx.root),
            throwsA(isA<UnsafeExportTarget>()));
        expect(Directory(fx.root).listSync().map((e) => p.basename(e.path)), isNot(contains(startsWith('mutation_audit_'))));
      });

      test('a symlinked parentDir that resolves into the checkout', () async {
        final inside = Directory(p.join(fx.root, 'tmp_here'))..createSync();
        final link = p.join(fx.parent, 'tmp_link');
        Link(link).createSync(inside.path);
        await expectLater(DisposableExport.create(repo: fx.root, sha: firstSha, parentDir: link),
            throwsA(isA<UnsafeExportTarget>()));
        expect(inside.listSync(), isEmpty);
      });

      test('a parentDir that does not exist yet but would be inside the checkout', () async {
        await expectLater(
            DisposableExport.create(repo: fx.root, sha: firstSha, parentDir: p.join(fx.root, 'not', 'yet')),
            throwsA(isA<UnsafeExportTarget>()));
        expect(Directory(p.join(fx.root, 'not')).existsSync(), isFalse);
      });
    });

    group('other worktrees of the same repository are developer checkouts too', () {
      late String linked;
      setUp(() async {
        linked = p.join(fx.parent, 'linked_wt');
        await fx.git(['worktree', 'add', '--detach', linked, 'HEAD']);
      });

      test('an exportDir inside a linked worktree is refused', () async {
        await expectLater(
            DisposableExport.create(repo: fx.root, sha: firstSha, exportDir: p.join(linked, 'sub')),
            throwsA(isA<UnsafeExportTarget>()));
      });

      test('a parentDir inside a linked worktree is refused', () async {
        await expectLater(DisposableExport.create(repo: fx.root, sha: firstSha, parentDir: linked),
            throwsA(isA<UnsafeExportTarget>()));
        expect(Directory(linked).listSync().map((e) => p.basename(e.path)), isNot(contains(startsWith('mutation_audit_'))));
      });

      test('a directory that contains a linked worktree is refused', () async {
        final outer = scratch('mutaudit_outer_');
        made.add(outer);
        final inner = p.join(outer.path, 'exp', 'wt');
        await fx.git(['worktree', 'add', '--detach', inner, 'HEAD']);
        await expectLater(
            DisposableExport.create(repo: fx.root, sha: firstSha, exportDir: p.join(outer.path, 'exp')),
            throwsA(isA<UnsafeExportTarget>()));
      });

      test('auditing from a linked worktree protects the main checkout as well', () async {
        await expectLater(
            DisposableExport.create(repo: linked, sha: firstSha, exportDir: p.join(fx.root, 'sub')),
            throwsA(isA<UnsafeExportTarget>()));
        await expectLater(
            DisposableExport.create(repo: linked, sha: firstSha, parentDir: fx.root),
            throwsA(isA<UnsafeExportTarget>()));
      });

      test('a system-temp style location beside them is fine', () async {
        final parent = scratch('mutaudit_parent_');
        made.add(parent);
        final e = await DisposableExport.create(repo: fx.root, sha: firstSha, parentDir: parent.path);
        addTearDown(e.dispose);
        expect(p.isWithin(parent.path, e.path), isTrue);
      });
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
          body: (e, cancel) async {
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
              body: (e, cancel) async {
                seen = e.path;
                throw StateError('boom');
              }),
          throwsA(isA<StateError>()));
      expect(Directory(seen!).existsSync(), isFalse);
      expect(await fx.worktrees(), isNot(contains(seen)));
    });

    group('Ctrl-C', () {
      test('cancels the token; the export is removed only AFTER the body has cleaned up and returned', () async {
        final interrupts = StreamController<ProcessSignal>();
        final started = Completer<String>();
        final log = <String>[];
        String? path;
        final run = withDisposableExport<void>(
            repo: fx.root,
            sha: firstSha,
            interrupts: interrupts.stream,
            body: (e, cancel) async {
              path = e.path;
              started.complete(e.path);
              await cancel.whenCancelled;
              log.add('body saw the cancel');
              // Reaping the process tree and restoring files takes a while.
              for (var i = 0; i < 20; i++) {
                await Future<void>.delayed(Duration.zero);
              }
              log.add('export still there during cleanup: ${Directory(e.path).existsSync()}');
              log.add('cleanup done');
            });
        await started.future;
        expect(Directory(path!).existsSync(), isTrue);
        interrupts.add(ProcessSignal.sigint);
        await expectLater(run, throwsA(isA<InterruptedError>()));
        expect(log, ['body saw the cancel', 'export still there during cleanup: true', 'cleanup done']);
        expect(Directory(path!).existsSync(), isFalse);
        expect(await fx.worktrees(), isNot(contains(path)));
        await interrupts.close();
      });

      test('SIGTERM is an interrupt too', () async {
        final interrupts = StreamController<ProcessSignal>();
        final run = withDisposableExport<void>(
            repo: fx.root,
            sha: firstSha,
            interrupts: interrupts.stream,
            body: (e, cancel) async {
              interrupts.add(ProcessSignal.sigterm);
              await cancel.whenCancelled;
            });
        await expectLater(run, throwsA(isA<InterruptedError>()));
        await interrupts.close();
      });

      test('a body that ignores the token is waited for, never deleted from under', () async {
        final interrupts = StreamController<ProcessSignal>();
        var existedAtEnd = false;
        final started = Completer<void>();
        final run = withDisposableExport<void>(
            repo: fx.root,
            sha: firstSha,
            interrupts: interrupts.stream,
            body: (e, cancel) async {
              started.complete();
              await cancel.whenCancelled;
              for (var i = 0; i < 50; i++) {
                await Future<void>.delayed(Duration.zero); // not looking at the token any more
              }
              existedAtEnd = Directory(e.path).existsSync();
            });
        await started.future;
        interrupts.add(ProcessSignal.sigint);
        await expectLater(run, throwsA(isA<InterruptedError>()));
        expect(existedAtEnd, isTrue);
        await interrupts.close();
      });

      test('the handler is installed before the export is created: an immediate signal is not lost', () async {
        final interrupts = StreamController<ProcessSignal>();
        var ran = false;
        final run = withDisposableExport<void>(
            repo: fx.root,
            sha: firstSha,
            interrupts: interrupts.stream,
            body: (e, cancel) async {
              ran = true;
            });
        expect(interrupts.hasListener, isTrue, reason: 'subscribed synchronously, before the first await');
        interrupts.add(ProcessSignal.sigint);
        await expectLater(run, throwsA(isA<InterruptedError>()));
        expect(ran, isFalse, reason: 'no work starts after the signal');
        expect(await fx.worktrees(), isNot(contains('mutation_audit_')));
        await interrupts.close();
      });

      test('the subscription is dropped afterwards', () async {
        final interrupts = StreamController<ProcessSignal>();
        await withDisposableExport<void>(
            repo: fx.root, sha: firstSha, interrupts: interrupts.stream, body: (e, cancel) async {});
        expect(interrupts.hasListener, isFalse);
        await interrupts.close();
      });

      test('a signal that arrives after the body returned still ends in InterruptedError (exit 130)', () async {
        final interrupts = StreamController<ProcessSignal>();
        final run = withDisposableExport<int>(
            repo: fx.root,
            sha: firstSha,
            interrupts: interrupts.stream,
            body: (e, cancel) async {
              interrupts.add(ProcessSignal.sigint);
              await Future<void>.delayed(Duration.zero);
              return 5;
            });
        await expectLater(run, throwsA(isA<InterruptedError>()));
        await interrupts.close();
      });
    });

    test('an unsafe target is refused before the body runs', () async {
      var ran = false;
      await expectLater(
          withDisposableExport<void>(
              repo: fx.root,
              sha: firstSha,
              exportDir: fx.root,
              body: (e, cancel) async {
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

    String sibling() => p.join(fx.parent, 'analytics');

    test('pubspec_overrides.yaml with a path is refused, and hashed when allowed', () async {
      write('pubspec.yaml', 'name: demo\n');
      write('pubspec_overrides.yaml', 'dependency_overrides:\n  analytics:\n    path: ${sibling()}\n');
      await expectLater(resolveDependencyConfig(export.path, repo: fx.root), throwsA(isA<PathOverrideRefused>()));
      final c = await resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: [sibling()]);
      expect(c.overridesFileSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(c.pathOverrides.single.package, 'analytics');
      expect(c.pathOverrides.single.source, 'pubspec_overrides.yaml');
      expect(c.pathOverrides.single.resolvedPath, sibling());
    });

    test('the allowed path may be given relative to the repo', () async {
      write('pubspec.yaml', 'name: demo\n');
      write('pubspec_overrides.yaml', 'dependency_overrides:\n  analytics:\n    path: ${sibling()}\n');
      final c = await resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: ['../analytics']);
      expect(c.pathOverrides, hasLength(1));
    });

    test('an override to somewhere else than the allowed path is still refused', () async {
      write('pubspec.yaml', 'name: demo\n');
      write('pubspec_overrides.yaml', 'dependency_overrides:\n  analytics:\n    path: ${p.join(fx.parent, 'other')}\n');
      await expectLater(
          resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: ['../analytics']),
          throwsA(isA<PathOverrideRefused>()));
    });

    test('every override must be allowed, not just one', () async {
      write('pubspec.yaml', 'name: demo\n');
      write('pubspec_overrides.yaml',
          'dependency_overrides:\n  analytics:\n    path: ${sibling()}\n  protocol:\n    path: ${p.join(fx.parent, 'protocol')}\n');
      await expectLater(
          resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: ['../analytics']),
          throwsA(isA<PathOverrideRefused>()));
    });

    group('a relative override is resolved against the export, as Pub does', () {
      test('../analytics in the export is not the developer repo\'s ../analytics', () async {
        // The export lives in its own temp directory: `../analytics` from there
        // is a different place than `../analytics` from the developer checkout.
        write('pubspec.yaml', 'name: demo\n');
        write('pubspec_overrides.yaml', 'dependency_overrides:\n  analytics:\n    path: ../analytics\n');
        final e = await resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: ['../analytics'])
            .then<Object?>((_) => null, onError: (Object e) => e);
        expect(e, isA<PathOverrideRefused>());
        final message = (e as PathOverrideRefused).message;
        expect(message, contains(p.join(p.dirname(export.resolveSymbolicLinksSync()), 'analytics')),
            reason: 'names where Pub would really look');
        expect(message, contains(sibling()), reason: 'and what was authorised');
      });

      test('it passes when the export really is beside the authorised sibling', () async {
        final beside = Directory(p.join(fx.parent, 'exports', 'one'))..createSync(recursive: true);
        File(p.join(beside.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');
        File(p.join(beside.path, 'pubspec_overrides.yaml'))
            .writeAsStringSync('dependency_overrides:\n  analytics:\n    path: ../../analytics\n');
        final c = await resolveDependencyConfig(beside.path, repo: fx.root, allowedOverrides: [sibling()]);
        expect(c.pathOverrides.single.resolvedPath, sibling());
      });

      test('spellings are canonicalised: .., ., a trailing slash and a symlink', () async {
        Directory(sibling()).createSync();
        final link = p.join(fx.parent, 'analytics_link');
        Link(link).createSync(sibling());
        write('pubspec.yaml', 'name: demo\n');
        write('pubspec_overrides.yaml',
            'dependency_overrides:\n  analytics:\n    path: ${p.join(fx.parent, 'x', '..', '.', 'analytics_link')}/\n');
        final c = await resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: [sibling()]);
        expect(c.pathOverrides.single.resolvedPath, sibling());
        final d = await resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: [link]);
        expect(d.pathOverrides, hasLength(1));
      });

      test('the lock file\'s relative path package is resolved against the export too', () async {
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
        await expectLater(resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: ['../analytics']),
            throwsA(isA<PathOverrideRefused>()));
      });
    });

    group('the audited sibling is recorded with its git state', () {
      setUp(() {
        write('pubspec.yaml', 'name: demo\n');
        write('pubspec_overrides.yaml', 'dependency_overrides:\n  analytics:\n    path: ${sibling()}\n');
      });

      Future<String> initSibling() async {
        Directory(sibling()).createSync();
        File(p.join(sibling(), 'a.dart')).writeAsStringSync('one\n');
        for (final args in [
          ['init', '-q', '-b', 'main'],
          ['add', '-A'],
          ['-c', 'user.name=t', '-c', 'user.email=t@e.com', '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'x'],
        ]) {
          await Process.run('git', args, workingDirectory: sibling());
        }
        return ((await Process.run('git', ['rev-parse', 'HEAD'], workingDirectory: sibling())).stdout as String).trim();
      }

      test('HEAD sha and a clean tree', () async {
        final head = await initSibling();
        final c = await resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: [sibling()]);
        expect(c.pathOverrides.single.gitHead, head);
        expect(c.pathOverrides.single.dirty, isFalse);
        expect(c.toJson()['pathOverrides'], [
          {
            'package': 'analytics',
            'path': sibling(),
            'source': 'pubspec_overrides.yaml',
            'resolvedPath': sibling(),
            'gitHead': head,
            'dirty': false,
          }
        ]);
      });

      test('a modified or untracked file makes it dirty', () async {
        await initSibling();
        File(p.join(sibling(), 'a.dart')).writeAsStringSync('two\n');
        var c = await resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: [sibling()]);
        expect(c.pathOverrides.single.dirty, isTrue);
        await Process.run('git', ['checkout', '--', 'a.dart'], workingDirectory: sibling());
        File(p.join(sibling(), 'new.dart')).writeAsStringSync('x\n');
        c = await resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: [sibling()]);
        expect(c.pathOverrides.single.dirty, isTrue);
      });

      test('a sibling that is not a git repository (or does not exist) records null, not a guess', () async {
        var c = await resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: [sibling()]);
        expect(c.pathOverrides.single.gitHead, isNull);
        expect(c.pathOverrides.single.dirty, isNull);
        Directory(sibling()).createSync();
        c = await resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: [sibling()]);
        expect(c.pathOverrides.single.gitHead, isNull);
        expect(c.pathOverrides.single.dirty, isNull);
      });
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
      path: "${sibling()}"
      relative: false
    source: path
    version: "0.1.0"
''');
      await expectLater(resolveDependencyConfig(export.path, repo: fx.root), throwsA(isA<PathOverrideRefused>()));
      final c = await resolveDependencyConfig(export.path, repo: fx.root, allowedOverrides: ['../analytics']);
      expect(c.pathOverrides.single.source, 'pubspec.lock');
    });
  });
}
