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
/// `-n`, `--plain-name`, `-N`) embedded in [testCmd] are dropped first; other
/// options and their values stay. Without [fullName] [testCmd] is used as given.
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

/// Options of `dart test` / `flutter test` that take a separate value.
const _valueOptions = {
  '-n', '--name', '-N', '--plain-name', '-t', '--tags', '-x', '--exclude-tags', '-r', '--reporter',
  '--file-reporter', '-p', '--platform', '-j', '--concurrency', '--timeout', '--total-shards',
  '--shard-index', '--test-randomize-ordering-seed', '--coverage', '--coverage-path',
  '--dart-define', '--dart-define-from-file', '-d', '--device-id', '--flavor', '--pub-serve',
};
const _nameOptions = {'-n', '--name', '-N', '--plain-name'};

/// Removes suite selectors (positional paths after the `test` subcommand) and
/// name selectors from [argv].
List<String> _withoutSelectors(List<String> argv) {
  final subcommand = argv.indexOf('test');
  final out = <String>[...argv.take(subcommand < 0 ? 1 : subcommand + 1)];
  for (var i = subcommand < 0 ? 1 : subcommand + 1; i < argv.length; i++) {
    final a = argv[i];
    if (a.startsWith('-')) {
      final eq = a.indexOf('=');
      final name = eq < 0 ? a : a.substring(0, eq);
      if (_nameOptions.contains(name)) {
        if (eq < 0) i++; // its value
        continue;
      }
      out.add(a);
      if (eq < 0 && _valueOptions.contains(a) && i + 1 < argv.length) out.add(argv[++i]);
      continue;
    }
    // A positional argument. dart/flutter test take only suite paths here.
    final looksLikePath = a.endsWith('.dart') || a.contains('/') || a == 'test' || a == 'integration_test';
    if (!looksLikePath) out.add(a);
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

/// The test command for the repository at [repoPath]: `flutter test --reporter
/// json` when its pubspec.yaml depends on the flutter SDK, else `dart test
/// --reporter json`.
String defaultTestCommand(String repoPath) =>
    _isFlutterPackage(repoPath) ? 'flutter test --reporter json' : 'dart test --reporter json';

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
