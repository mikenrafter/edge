import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Splits a command line into arguments: whitespace separates, single and
/// double quotes group (and are removed), a backslash escapes the next
/// character outside single quotes. An unterminated quote is a
/// [FormatException].
List<String> splitCommand(String command) {
  final args = <String>[];
  final cur = StringBuffer();
  var inToken = false;
  String? quote;
  for (var i = 0; i < command.length; i++) {
    final c = command[i];
    if (quote == "'") {
      if (c == "'") {
        quote = null;
      } else {
        cur.write(c);
      }
    } else if (c == r'\') {
      inToken = true;
      cur.write(i + 1 < command.length ? command[++i] : c);
    } else if (quote == '"') {
      if (c == '"') {
        quote = null;
      } else {
        cur.write(c);
      }
    } else if (c == '"' || c == "'") {
      quote = c;
      inToken = true;
    } else if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      if (inToken) {
        args.add(cur.toString());
        cur.clear();
        inToken = false;
      }
    } else {
      inToken = true;
      cur.write(c);
    }
  }
  if (quote != null) throw FormatException('unterminated $quote in command', command);
  if (inToken) args.add(cur.toString());
  return args;
}

/// The argv for one test run: [testCmd] split, `--reporter json` appended when
/// the command names no reporter (`--reporter`, `-r`), then [tests] (files),
/// then `--name '^<escaped fullName>$'` when [fullName] is given.
///
/// [fullName] is the whole test name, selected with an anchored, regex-escaped
/// `--name`: `--plain-name` is a substring match and would also run every test
/// whose name merely contains it. A run for one test is a rerun of one suite,
/// so suite selectors (files, directories) and name selectors (`--name`,
/// `-n`, `--plain-name`, `-N`) embedded in [testCmd] are dropped first (every
/// positional after `test` is a suite); other options and their values stay,
/// using the real option arities (see [flutterTestValueOptions]). Without [fullName] [testCmd] is used as given.
List<String> buildTestCommand(
  String testCmd, {
  List<String> tests = const [],
  String? fullName,
}) {
  var argv = splitCommand(testCmd);
  if (fullName != null) argv = _withoutSelectors(argv);
  final hasReporter =
      argv.any((a) => a == '--reporter' || a == '-r' || a.startsWith('--reporter='));
  if (!hasReporter) argv.addAll(const ['--reporter', 'json']);
  argv.addAll(tests);
  if (fullName != null) argv.addAll(['--name', '^${RegExp.escape(fullName)}\$']);
  return argv;
}

/// A suite that does not exist. The warm-up run names it: the test tool builds
/// the build hooks of the dependencies before it loads a suite, finds this one
/// missing and stops, so no project test code runs.
const warmupSuite = 'test/mutation_audit_warmup_does_not_exist_test.dart';

/// [testCmd] with its suite and name selectors dropped and [warmupSuite] as the
/// only suite (`--reporter json` is added like for any test run).
List<String> buildWarmupCommand(String testCmd) {
  final argv = _withoutSelectors(splitCommand(testCmd));
  final hasReporter = argv.any((a) => a == '--reporter' || a == '-r' || a.startsWith('--reporter='));
  return [...argv, if (!hasReporter) ...const ['--reporter', 'json'], warmupSuite];
}

/// Options that take a value, from `flutter test --help` (Flutter 3.41.6) and
/// `dart test --help` (package:test 1.31.1). Everything else is a flag. The
/// two tools differ: `--coverage` is a flag for flutter and takes a directory
/// for dart. A value option written `--opt=value`, or a short one with the
/// value attached (`-j4`), takes no following word.
const flutterTestValueOptions = {
  '-d', '--device-id', '-D', '--dart-define', '--dart-define-from-file', '--device-user', '--flavor',
  '--name', '--plain-name', '-t', '--tags', '-x', '--exclude-tags', '--coverage-path',
  '--coverage-package', '-j', '--concurrency', '--test-randomize-ordering-seed', '--total-shards',
  '--shard-index', '-r', '--reporter', '--file-reporter', '--timeout', '--dds-port',
};
const dartTestValueOptions = {
  '-n', '--name', '-N', '--plain-name', '-t', '--tags', '-x', '--exclude-tags', '-p', '--platform',
  '-c', '--compiler', '-P', '--preset', '-j', '--concurrency', '--total-shards', '--shard-index',
  '--timeout', '--suite-load-timeout', '--coverage', '--coverage-path', '--coverage-package',
  '--test-randomize-ordering-seed', '-r', '--reporter', '--file-reporter',
};
const _nameOptions = {'-n', '--name', '-N', '--plain-name'};

/// Removes every suite selector (every positional argument after the `test`
/// subcommand) and every name selector from [argv].
///
/// Without a `test` subcommand (a custom runner) the structure is unknown:
/// only name selectors and path-like words (`*.dart`, containing `/`) go.
List<String> _withoutSelectors(List<String> argv) {
  final subcommand = argv.indexOf('test');
  final known = subcommand >= 0;
  final start = known ? subcommand + 1 : 1;
  final valued = argv.take(start).any((a) => a == 'flutter' || a.endsWith('/flutter'))
      ? flutterTestValueOptions
      : dartTestValueOptions;
  final out = <String>[...argv.take(start)];
  for (var i = start; i < argv.length; i++) {
    final a = argv[i];
    if (a.startsWith('-') && a != '-') {
      final eq = a.indexOf('=');
      final name = eq < 0 ? a : a.substring(0, eq);
      final takesNext = eq < 0 && valued.contains(a) && i + 1 < argv.length;
      if (_nameOptions.contains(name)) {
        if (takesNext) i++; // its value goes with it
        continue;
      }
      out.add(a);
      if (takesNext) out.add(argv[++i]);
      continue;
    }
    // A positional: a suite file or directory.
    if (!known && !(a.endsWith('.dart') || a.contains('/'))) out.add(a);
  }
  return out;
}

bool _isFlutterPackage(String repoPath) {
  final file = File(p.join(repoPath, 'pubspec.yaml'));
  if (!file.existsSync()) return false;
  final doc = loadYaml(file.readAsStringSync());
  if (doc is! YamlMap) return false;
  final deps = doc['dependencies'];
  if (deps is! YamlMap) return false;
  final flutter = deps['flutter'];
  return flutter is YamlMap && flutter['sdk'] == 'flutter';
}

/// The test command for the repository at [repoPath]: `flutter test --no-pub
/// --reporter json` when its pubspec.yaml depends on the flutter SDK, else
/// `dart test --reporter json`. `--no-pub`: the setup command has resolved the
/// packages, and the sandboxed runs have no network, so an implicit `pub get`
/// (which Flutter may start on its own) could only fail or re-resolve.
String defaultTestCommand(String repoPath) =>
    _isFlutterPackage(repoPath) ? 'flutter test --no-pub --reporter json' : 'dart test --reporter json';

/// The package-config command a fresh export needs before its tests can run:
/// `flutter pub get` when the pubspec depends on the flutter SDK, else
/// `dart pub get`.
String defaultSetupCommand(String repoPath) =>
    _isFlutterPackage(repoPath) ? 'flutter pub get' : 'dart pub get';

/// The `.dart` files under [root] matching any of [patterns] (globs relative to
/// [root]), as root-relative paths with `/` separators, sorted, without
/// duplicates. A pattern that matches nothing is a [FormatException] (a typo
/// must not silently audit nothing).
List<String> expandFileGlobs(String root, List<String> patterns) {
  final all = <String>[];
  void walk(Directory dir, String prefix) {
    for (final entity in dir.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      final rel = prefix.isEmpty ? name : '$prefix/$name';
      if (entity is Directory) {
        if (name == '.git' || name == '.dart_tool') continue;
        walk(entity, rel);
      } else if (entity is File && name.endsWith('.dart')) {
        all.add(rel);
      }
    }
  }

  walk(Directory(root), '');
  final matched = <String>{};
  for (final pattern in patterns) {
    final glob = Glob(pattern, context: p.posix);
    final hits = all.where(glob.matches).toList();
    if (hits.isEmpty) throw FormatException('no .dart file matches', pattern);
    matched.addAll(hits);
  }
  return matched.toList()..sort();
}
