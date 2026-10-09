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
      expect(buildTestCommand('dart test', tests: ['test/a_test.dart'], plainName: 'g fails'),
          ['dart', 'test', '--reporter', 'json', 'test/a_test.dart', '--plain-name', 'g fails']);
    });

    test('a test name with spaces and quotes stays one argument', () {
      final argv = buildTestCommand('dart test', plainName: 'it\'s "odd" name');
      expect(argv.last, 'it\'s "odd" name');
      expect(argv[argv.length - 2], '--plain-name');
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
