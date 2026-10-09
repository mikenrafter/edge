import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/git_fixture.dart' show scratch;
import 'support/package_config.dart';

/// A package whose build hook downloads a library (sqlite3 does) cannot do it
/// in the sandbox, which has no network: the hooks are built by a warm-up run
/// after setup, outside the sandbox, on a suite that does not exist.
void main() {
  late Directory root;
  setUp(() => root = scratch('mutaudit_hooks_'));
  tearDown(() => root.deleteSync(recursive: true));

  void package(String relative, {required bool hook}) {
    final dir = Directory(p.normalize(p.join(root.path, '.dart_tool', relative)))..createSync(recursive: true);
    if (hook) File(p.join(dir.path, 'hook', 'build.dart')).createSync(recursive: true);
  }

  group('packagesWithBuildHooks', () {
    test('no package config yet: none', () {
      expect(packagesWithBuildHooks(root.path), isEmpty);
    });

    test('the packages of the config that have hook/build.dart, wherever they live', () {
      package('../', hook: false);
      package('../vendor/native', hook: true);
      package('../vendor/plain', hook: false);
      final outside = scratch('mutaudit_hooks_outside_');
      addTearDown(() => outside.deleteSync(recursive: true));
      File(p.join(outside.path, 'hook', 'build.dart')).createSync(recursive: true);
      writeConfig(root.path, {
        'demo': ('../', 'lib/'),
        'native': ('../vendor/native', 'lib/'),
        'plain': ('../vendor/plain', 'lib/'),
        'sqlite3': (outside.uri.toString(), 'lib/'),
      });
      expect(packagesWithBuildHooks(root.path), ['native', 'sqlite3']);
    });

    test('the audited package itself counts', () {
      package('../', hook: true);
      writeDemoConfig(root.path);
      expect(packagesWithBuildHooks(root.path), ['demo']);
    });

    test('a damaged config or a package that is gone: none', () {
      File(p.join(root.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{ not json');
      expect(packagesWithBuildHooks(root.path), isEmpty);
      writeConfig(root.path, {'gone': ('../nowhere', 'lib/')});
      expect(packagesWithBuildHooks(root.path), isEmpty);
    });
  });

  group('buildWarmupCommand: the test command on a suite that does not exist', () {
    test('selectors are dropped, the other options stay, a missing file is the only suite', () {
      final argv = buildWarmupCommand('flutter test --no-pub --reporter json --plain-name x test/a_test.dart -j 2');
      expect(argv.take(5), ['flutter', 'test', '--no-pub', '--reporter', 'json']);
      expect(argv, containsAllInOrder(['-j', '2']));
      expect(argv, isNot(contains('test/a_test.dart')));
      expect(argv, isNot(contains('--plain-name')));
      expect(argv.last, warmupSuite);
      expect(File(p.join(root.path, warmupSuite)).existsSync(), isFalse);
    });

    test('a wrapper and its arguments are kept', () {
      expect(buildWarmupCommand('nix develop . -c flutter test --no-pub').take(6), ['nix', 'develop', '.', '-c', 'flutter', 'test']);
    });
  });
}
