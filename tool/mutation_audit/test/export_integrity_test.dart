import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/git_fixture.dart';

/// The host-side tripwire: after a sandboxed run the export on the host must
/// be what it was before, at the pinned commit.
void main() {
  late GitFixture fx;
  late String root;
  late String sha;

  setUp(() async {
    fx = await GitFixture.create({
      '.gitignore': '.dart_tool/\nbuild/\nignored.txt\ncache_dir/\n',
      'lib/a.dart': 'bool lt(int a, int b) => a < b;\n',
      'test/a_test.dart': '// faked\n',
    });
    root = fx.root;
    sha = await fx.head();
    Directory(p.join(root, 'build')).createSync();
    File(p.join(root, 'build/seed.txt')).writeAsStringSync('seed');
    Directory(p.join(root, '.dart_tool')).createSync();
    Directory(p.join(root, 'cache_dir')).createSync();
  });
  tearDown(() => fx.dispose());

  ExportIntegrity integrity([String? pinned]) => ExportIntegrity(root: root, pinnedSha: pinned ?? sha);
  void write(String rel, String body) => File(p.join(root, rel))
    ..createSync(recursive: true)
    ..writeAsStringSync(body);

  Matcher stops(Object what) =>
      throwsA(isA<ExportStateError>().having((e) => e.message, 'message', what is Matcher ? what : contains(what)));

  group('the pinned commit', () {
    test('HEAD at the pinned sha passes', () async {
      await integrity().requirePinned('before setup');
    });

    test('HEAD somewhere else stops the audit, naming both commits and the moment', () async {
      write('lib/b.dart', 'x');
      await fx.git(['add', '-A']);
      await fx.git(['commit', '-q', '-m', 'second']);
      final other = await fx.head();
      await expectLater(integrity().requirePinned('after setup'), stops(allOf(contains(other), contains(sha), contains('after setup'))));
    });

    test('a moved HEAD is also caught by the comparison after a run', () async {
      final ig = integrity();
      final before = await ig.view();
      await fx.git(['commit', '-q', '--allow-empty', '-m', 'a test committed']);
      await expectLater(ig.verifyUnchanged(before, during: 'a run'), stops('HEAD'));
    });
  });

  group('requireClean', () {
    test('a clean export passes; build artefacts of setup may be untracked', () async {
      Directory(p.join(root, '.flutter-plugins-dependencies')).createSync();
      write('.packages', '{}');
      await integrity().requireClean('after setup');
    });

    test('a tracked file changed by setup stops the audit, naming it', () async {
      write('lib/a.dart', 'changed\n');
      await expectLater(integrity().requireClean('after setup'), stops('lib/a.dart'));
    });

    test('an untracked file that is not ignored stops it', () async {
      write('stray.txt', 'x');
      await expectLater(integrity().requireClean('after setup'), stops('stray.txt'));
    });

    test('setupOutputs exempt more paths, by glob: a lock the project does not commit, a generated directory', () async {
      write('pubspec.lock', 'x');
      write('gen/deep/out.dart', 'x');
      await expectLater(integrity().requireClean('after setup'), stops('pubspec.lock'));
      final ig = ExportIntegrity(root: root, pinnedSha: sha, setupOutputs: ['pubspec.lock', 'gen']);
      await ig.requireClean('after setup');
      write('lib/a.dart', 'changed\n');
      await expectLater(ig.requireClean('after setup'), stops('lib/a.dart'));
    });

    test('HEAD elsewhere stops it before the status is looked at', () async {
      await expectLater(integrity('0' * 40).requireClean('after setup'), stops('after setup'));
    });
  });

  group('verifyUnchanged', () {
    test('an untouched export is unchanged, however often it is looked at', () async {
      final ig = integrity();
      final a = await ig.view(mutatedFile: 'lib/a.dart');
      await ig.verifyUnchanged(a, during: 'a run');
      await ig.verifyUnchanged(a, during: 'another run');
    });

    test('the mutated file may differ from HEAD, as long as it is the same as before the run', () async {
      final ig = integrity();
      write('lib/a.dart', 'bool lt(int a, int b) => a <= b;\n');
      final before = await ig.view(mutatedFile: 'lib/a.dart');
      expect(before.status, contains(' M lib/a.dart'));
      await ig.verifyUnchanged(before, during: 'a run');
    });

    test('a second change to the mutated file is caught by its hash', () async {
      final ig = integrity();
      write('lib/a.dart', 'bool lt(int a, int b) => a <= b;\n');
      final before = await ig.view(mutatedFile: 'lib/a.dart');
      write('lib/a.dart', 'bool lt(int a, int b) => a == b;\n');
      await expectLater(ig.verifyUnchanged(before, during: 'a run'), stops('lib/a.dart'));
    });

    test('a run that wrote a tracked file other than the mutated one is caught', () async {
      final ig = integrity();
      final before = await ig.view(mutatedFile: 'lib/a.dart');
      write('test/a_test.dart', '// edited\n');
      await expectLater(ig.verifyUnchanged(before, during: 'a run'), stops('test/a_test.dart'));
    });

    test('a new untracked file is caught', () async {
      final ig = integrity();
      final before = await ig.view();
      write('leftover.txt', 'x');
      await expectLater(ig.verifyUnchanged(before, during: 'a run'), stops('leftover.txt'));
    });

    test('a new ignored file at the top, or in an ignored directory, is caught', () async {
      final ig = integrity();
      var before = await ig.view();
      write('ignored.txt', 'x');
      await expectLater(ig.verifyUnchanged(before, during: 'a run'), stops('ignored.txt'));
      File(p.join(root, 'ignored.txt')).deleteSync();
      before = await ig.view();
      write('build/x.sqlite', 'db');
      await expectLater(ig.verifyUnchanged(before, during: 'a run'), stops('build'));
    });

    test('a changed ignored file is caught (size and modification time)', () async {
      write('ignored.txt', 'one');
      final ig = integrity();
      final before = await ig.view();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      write('ignored.txt', 'a longer text');
      await expectLater(ig.verifyUnchanged(before, during: 'a run'), stops('ignored.txt'));
    });

    test('a new empty directory, which git does not see, is caught: at the root, and one level down', () async {
      final ig = integrity();
      var before = await ig.view();
      Directory(p.join(root, 'empty_ignored')).createSync();
      await expectLater(ig.verifyUnchanged(before, during: 'a run'), stops('empty_ignored'));
      Directory(p.join(root, 'empty_ignored')).deleteSync();
      before = await ig.view();
      Directory(p.join(root, 'cache_dir/empty')).createSync();
      await expectLater(ig.verifyUnchanged(before, during: 'a run'), stops('cache_dir'));
    });

    test('the message names the moment, so the log says which run broke isolation', () async {
      final ig = integrity();
      final before = await ig.view();
      write('leftover.txt', 'x');
      await expectLater(ig.verifyUnchanged(before, during: 'the run of mutant m1'), stops('the run of mutant m1'));
    });

    test('differences are listed, empty when the same', () async {
      final ig = integrity();
      final a = await ig.view();
      expect(a.differences(await ig.view()), isEmpty);
      write('leftover.txt', 'x');
      expect((await ig.view()).differences(a).join('\n'), contains('leftover.txt'));
    });
  });
}
