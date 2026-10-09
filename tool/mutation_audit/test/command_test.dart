import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/git_fixture.dart';

void main() {
  group('splitCommand', () {
    test('whitespace separates', () {
      expect(splitCommand('flutter test  --reporter json'), ['flutter', 'test', '--reporter', 'json']);
      expect(splitCommand('  dart   test '), ['dart', 'test']);
      expect(splitCommand(''), isEmpty);
    });

    test('quotes group and disappear', () {
      expect(splitCommand('sh -c "dart pub get && dart test"'), ['sh', '-c', 'dart pub get && dart test']);
      expect(splitCommand("a 'b c' d"), ['a', 'b c', 'd']);
      expect(splitCommand('a "it\'s" b'), ['a', "it's", 'b']);
      expect(splitCommand('a "" b'), ['a', '', 'b']);
    });

    test('a backslash escapes outside single quotes', () {
      expect(splitCommand(r'a\ b c'), ['a b', 'c']);
      expect(splitCommand(r'a "x\"y"'), ['a', 'x"y']);
      expect(splitCommand(r"a 'x\y'"), ['a', r'x\y']);
    });

    test('an unterminated quote is refused', () {
      expect(() => splitCommand('a "b'), throwsFormatException);
      expect(() => splitCommand("a 'b"), throwsFormatException);
    });
  });

  group('buildTestCommand', () {
    test('adds the json reporter when none is named', () {
      expect(buildTestCommand('flutter test'), ['flutter', 'test', '--reporter', 'json']);
    });

    test('keeps a reporter that is already there, in any spelling', () {
      expect(buildTestCommand('dart test --reporter json'), ['dart', 'test', '--reporter', 'json']);
      expect(buildTestCommand('dart test -r json'), ['dart', 'test', '-r', 'json']);
      expect(buildTestCommand('dart test --reporter=json'), ['dart', 'test', '--reporter=json']);
    });

    test('test files follow, then the single-test filter', () {
      expect(buildTestCommand('dart test', tests: ['test/a_test.dart', 'test/b_test.dart']),
          ['dart', 'test', '--reporter', 'json', 'test/a_test.dart', 'test/b_test.dart']);
      expect(buildTestCommand('dart test', tests: ['test/a_test.dart'], fullName: 'g fails'),
          ['dart', 'test', '--reporter', 'json', 'test/a_test.dart', '--name', r'^g fails$']);
    });

    test('a test name with spaces and quotes stays one argument', () {
      final argv = buildTestCommand('dart test', fullName: 'it\'s "odd" name');
      expect(argv.last, r'''^it's "odd" name$''');
      expect(argv[argv.length - 2], '--name');
    });
  });

  group('the single-test selector is the whole name, anchored and escaped', () {
    String selector(String name) {
      final argv = buildTestCommand('dart test', fullName: name);
      expect(argv[argv.length - 2], '--name');
      return argv.last;
    }

    test('regex metacharacters in the name are escaped', () {
      final sel = selector(r'lt (a<b) [x]+ costs $5 | a.b? {1} ^');
      final re = RegExp(sel);
      expect(re.hasMatch(r'lt (a<b) [x]+ costs $5 | a.b? {1} ^'), isTrue);
      expect(re.hasMatch(r'lt (a<b) [x]+ costs $5 | aXb? {1} ^'), isFalse, reason: 'the dot is a dot');
    });

    test('a name that is a prefix or suffix of another test selects only itself', () {
      final re = RegExp(selector('g adds'));
      expect(re.hasMatch('g adds'), isTrue);
      expect(re.hasMatch('g adds two'), isFalse);
      expect(re.hasMatch('other g adds'), isFalse);
      expect(re.hasMatch('g adds\nmore'), isFalse);
    });

    test('names that differ only in a regex-significant way do not collide', () {
      final re = RegExp(selector('a|b'));
      expect(re.hasMatch('a'), isFalse);
      expect(re.hasMatch('b'), isFalse);
      expect(re.hasMatch('a|b'), isTrue);
    });
  });

  group('rerun: only the failed suite runs', () {
    List<String> rerun(String cmd) =>
        buildTestCommand(cmd, tests: ['test/failed_test.dart'], fullName: 'x');

    test('suite files embedded in the test command are dropped', () {
      expect(rerun('flutter test test/a_test.dart test/b_test.dart'),
          ['flutter', 'test', '--reporter', 'json', 'test/failed_test.dart', '--name', '^x\$']);
    });

    test('directories and a bare test directory are dropped', () {
      expect(rerun('flutter test test/ integration_test'),
          ['flutter', 'test', '--reporter', 'json', 'test/failed_test.dart', '--name', '^x\$']);
      expect(rerun('dart test test/unit'), ['dart', 'test', '--reporter', 'json', 'test/failed_test.dart', '--name', '^x\$']);
    });

    test('name selectors embedded in the test command are dropped, in every spelling', () {
      for (final cmd in [
        'dart test --name foo',
        'dart test -n foo',
        'dart test --plain-name foo',
        'dart test -N foo',
        'dart test --name=foo',
        'dart test --plain-name=foo',
      ]) {
        final argv = rerun(cmd);
        expect(argv.where((a) => a == 'foo' || a.contains('foo')), isEmpty, reason: cmd);
        expect(argv.where((a) => a == '--name'), hasLength(1), reason: cmd);
      }
    });

    test('other options and their values survive', () {
      expect(rerun('flutter test --tags slow -j 2 --timeout 60s test/a_test.dart --dart-define X=1 --no-pub'),
          ['flutter', 'test', '--tags', 'slow', '-j', '2', '--timeout', '60s', '--dart-define', 'X=1', '--no-pub',
           '--reporter', 'json', 'test/failed_test.dart', '--name', '^x\$']);
    });

    test('a path that is the value of a value option is not a suite', () {
      expect(rerun('flutter test --dart-define-from-file env/ci.json test/a_test.dart'),
          ['flutter', 'test', '--dart-define-from-file', 'env/ci.json', '--reporter', 'json', 'test/failed_test.dart', '--name', '^x\$']);
    });

    test('a wrapper before the subcommand is kept', () {
      expect(rerun('fvm flutter test test/a_test.dart'),
          ['fvm', 'flutter', 'test', '--reporter', 'json', 'test/failed_test.dart', '--name', '^x\$']);
    });

    test('without a single-test filter the command is left exactly as given', () {
      expect(buildTestCommand('flutter test test/a_test.dart --name foo', tests: ['test/b_test.dart']),
          ['flutter', 'test', 'test/a_test.dart', '--name', 'foo', '--reporter', 'json', 'test/b_test.dart']);
    });
  });

  group('defaults from the repository', () {
    late Directory dir;
    setUp(() => dir = scratch());
    tearDown(() => dir.deleteSync(recursive: true));

    void pubspec(String body) => File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(body);

    test('a flutter package gets flutter', () {
      pubspec('name: app\ndependencies:\n  flutter:\n    sdk: flutter\n');
      expect(defaultTestCommand(dir.path), 'flutter test --reporter json');
      expect(defaultSetupCommand(dir.path), 'flutter pub get');
    });

    test('a pure dart package gets dart', () {
      pubspec('name: lib\nenvironment:\n  sdk: ^3.0.0\ndev_dependencies:\n  test: ^1.0.0\n');
      expect(defaultTestCommand(dir.path), 'dart test --reporter json');
      expect(defaultSetupCommand(dir.path), 'dart pub get');
    });
  });

  group('expandFileGlobs', () {
    late Directory dir;
    setUp(() {
      dir = scratch();
      for (final f in ['lib/a.dart', 'lib/src/b.dart', 'lib/src/c.dart', 'lib/src/notes.md', 'test/a_test.dart']) {
        File(p.join(dir.path, f)).createSync(recursive: true);
      }
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('expands globs to sorted, root-relative dart files', () {
      expect(expandFileGlobs(dir.path, ['lib/**.dart']), ['lib/a.dart', 'lib/src/b.dart', 'lib/src/c.dart']);
      expect(expandFileGlobs(dir.path, ['lib/src/*.dart']), ['lib/src/b.dart', 'lib/src/c.dart']);
    });

    test('several patterns merge without duplicates', () {
      expect(expandFileGlobs(dir.path, ['lib/src/b.dart', 'lib/**.dart', 'test/*.dart']),
          ['lib/a.dart', 'lib/src/b.dart', 'lib/src/c.dart', 'test/a_test.dart']);
    });

    test('only dart files, even for a catch-all', () {
      expect(expandFileGlobs(dir.path, ['lib/**']), isNot(contains('lib/src/notes.md')));
    });

    test('a pattern that matches nothing is refused', () {
      expect(() => expandFileGlobs(dir.path, ['lib/nope/**.dart']), throwsFormatException);
      expect(() => expandFileGlobs(dir.path, ['lib/a.dart', 'typo/**.dart']), throwsFormatException);
    });
  });
}
