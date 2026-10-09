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

    test('--coverage is a flag for flutter test: the path after it is a suite and goes', () {
      expect(rerun('flutter test --coverage test/other_test.dart'),
          ['flutter', 'test', '--coverage', '--reporter', 'json', 'test/failed_test.dart', '--name', '^x\$']);
    });

    test('--coverage takes a directory for dart test: that value stays, the suite goes', () {
      expect(rerun('dart test --coverage cov test/other_test.dart'),
          ['dart', 'test', '--coverage', 'cov', '--reporter', 'json', 'test/failed_test.dart', '--name', '^x\$']);
    });

    test('every positional after the test subcommand is a suite, path-like or not', () {
      expect(rerun('flutter test specs'), ['flutter', 'test', '--reporter', 'json', 'test/failed_test.dart', '--name', '^x\$']);
      expect(rerun('dart test unit integration widgets'),
          ['dart', 'test', '--reporter', 'json', 'test/failed_test.dart', '--name', '^x\$']);
      expect(rerun('flutter test --no-pub specs --tags slow other'),
          ['flutter', 'test', '--no-pub', '--tags', 'slow', '--reporter', 'json', 'test/failed_test.dart', '--name', '^x\$']);
    });

    // The option tables of `flutter test --help` and `dart test --help`
    // (Flutter 3.41.6 / package:test 1.31.1), copied here on purpose: the test
    // is the check on the table in command.dart.
    const flutterValue = [
      '-d', '--device-id', '-D', '--dart-define', '--dart-define-from-file', '--device-user', '--flavor',
      '--name', '--plain-name', '-t', '--tags', '-x', '--exclude-tags', '--coverage-path',
      '--coverage-package', '-j', '--concurrency', '--test-randomize-ordering-seed', '--total-shards',
      '--shard-index', '-r', '--reporter', '--file-reporter', '--timeout', '--dds-port',
    ];
    const flutterFlags = [
      '-h', '--help', '-v', '--verbose', '--pub', '--no-pub', '--track-widget-creation',
      '--no-track-widget-creation', '--start-paused', '--fail-fast', '--no-fail-fast', '--run-skipped',
      '--no-run-skipped', '--coverage', '--merge-coverage', '--branch-coverage', '--update-goldens',
      '--test-assets', '--no-test-assets', '--ignore-timeouts', '--wasm', '--dds', '--no-dds',
    ];
    const dartValue = [
      '-n', '--name', '-N', '--plain-name', '-t', '--tags', '-x', '--exclude-tags', '-p', '--platform',
      '-c', '--compiler', '-P', '--preset', '-j', '--concurrency', '--total-shards', '--shard-index',
      '--timeout', '--suite-load-timeout', '--coverage', '--coverage-path', '--coverage-package',
      '--test-randomize-ordering-seed', '-r', '--reporter', '--file-reporter',
    ];
    const dartFlags = [
      '-h', '--help', '--version', '--run-skipped', '--no-run-skipped', '--ignore-timeouts',
      '--pause-after-load', '--debug', '--branch-coverage', '--chain-stack-traces',
      '--no-chain-stack-traces', '--no-retry', '--fail-fast', '--no-fail-fast', '--verbose-trace',
      '--js-trace', '--color', '--no-color',
    ];
    const nameSelectors = {'-n', '--name', '-N', '--plain-name'};

    for (final (tool, valued, flags) in [
      ('flutter', flutterValue, flutterFlags),
      ('dart', dartValue, dartFlags),
    ]) {
      group('option arity of $tool test', () {
        for (final option in valued) {
          test('$option takes a value: the value stays (or goes with the name selectors), a suite after it goes', () {
            final argv = rerun('$tool test $option VALUE test/other_test.dart specs');
            expect(argv, isNot(contains('test/other_test.dart')), reason: option);
            expect(argv, isNot(contains('specs')), reason: option);
            if (nameSelectors.contains(option)) {
              expect(argv, isNot(contains('VALUE')), reason: option);
              // Only the rerun's own anchored --name is left.
              expect(argv.where((a) => a == option), hasLength(option == '--name' ? 1 : 0), reason: option);
            } else {
              expect(argv, containsAllInOrder([option, 'VALUE']), reason: option);
            }
          });
        }
        for (final option in flags) {
          test('$option is a flag: it stays, the word after it is a suite and goes', () {
            final argv = rerun('$tool test $option test/other_test.dart specs');
            expect(argv, contains(option), reason: option);
            expect(argv, isNot(contains('test/other_test.dart')), reason: option);
            expect(argv, isNot(contains('specs')), reason: option);
          });
        }
      });
    }

    test('an option written --name=value or with an attached short value takes no following word', () {
      expect(rerun('dart test --coverage=cov test/other_test.dart'),
          ['dart', 'test', '--coverage=cov', '--reporter', 'json', 'test/failed_test.dart', '--name', '^x\$']);
      expect(rerun('dart test -j4 test/other_test.dart'),
          ['dart', 'test', '-j4', '--reporter', 'json', 'test/failed_test.dart', '--name', '^x\$']);
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
      expect(defaultTestCommand(dir.path), 'flutter test --no-pub --reporter json');
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
