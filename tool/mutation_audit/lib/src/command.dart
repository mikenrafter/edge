/// Splits a command line into arguments: whitespace separates, single and
/// double quotes group (and are removed), a backslash escapes the next
/// character outside single quotes. An unterminated quote is a
/// [FormatException].
List<String> splitCommand(String command) =>
    throw UnimplementedError('splitCommand');

/// The argv for one test run: [testCmd] split, `--reporter json` appended when
/// the command names no reporter (`--reporter`, `-r`), then [tests] (files),
/// then `--plain-name <plainName>` when [plainName] is given.
List<String> buildTestCommand(
  String testCmd, {
  List<String> tests = const [],
  String? plainName,
}) =>
    throw UnimplementedError('buildTestCommand');

/// The test command for the repository at [repoPath]: `flutter test --reporter
/// json` when its pubspec.yaml depends on the flutter SDK, else `dart test
/// --reporter json`.
String defaultTestCommand(String repoPath) =>
    throw UnimplementedError('defaultTestCommand');

/// The `.dart` files under [root] matching any of [patterns] (globs relative to
/// [root]), as root-relative paths with `/` separators, sorted, without
/// duplicates. A pattern that matches nothing is a [FormatException] (a typo
/// must not silently audit nothing).
List<String> expandFileGlobs(String root, List<String> patterns) =>
    throw UnimplementedError('expandFileGlobs');

/// The package-config command a fresh export needs before its tests can run:
/// `flutter pub get` when the pubspec depends on the flutter SDK, else
/// `dart pub get`.
String defaultSetupCommand(String repoPath) =>
    throw UnimplementedError('defaultSetupCommand');
