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
/// then `--plain-name <plainName>` when [plainName] is given.
List<String> buildTestCommand(
  String testCmd, {
  List<String> tests = const [],
  String? plainName,
}) {
  final argv = splitCommand(testCmd);
  final hasReporter =
      argv.any((a) => a == '--reporter' || a == '-r' || a.startsWith('--reporter='));
  if (!hasReporter) argv.addAll(const ['--reporter', 'json']);
  argv.addAll(tests);
  if (plainName != null) argv.addAll(['--plain-name', plainName]);
  return argv;
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
