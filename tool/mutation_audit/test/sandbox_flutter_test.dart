@TestOn('linux')
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sandbox_real_test.dart' show tree;
import 'support/git_fixture.dart';

/// One real `flutter test` of a one-file package, inside the sandbox: the
/// toolchain (flutter_tester, the VM service on loopback, the kernel compiler,
/// the pub cache) works with a read-only host, an overlay export, a fresh HOME
/// and no network. Skipped, with the reason, where Flutter or bubblewrap is
/// missing, or the package cannot be resolved offline.
void main() {
  String? skip;
  late Directory pkg;
  var ready = false;

  setUpAll(() async {
    try {
      final b = Process.runSync('bwrap', ['--ro-bind', '/', '/', '--unshare-pid', 'true']);
      if (b.exitCode != 0) skip = 'bubblewrap cannot create a sandbox here';
    } on ProcessException {
      skip = 'bubblewrap (bwrap) is not installed';
    }
    if (skip != null) return;
    pkg = scratch('mutaudit_flutter_');
    Directory(p.join(pkg.path, 'lib')).createSync();
    Directory(p.join(pkg.path, 'test')).createSync();
    File(p.join(pkg.path, 'pubspec.yaml')).writeAsStringSync('name: probe\npublish_to: none\n'
        'environment:\n  sdk: ^3.0.0\ndependencies:\n  flutter:\n    sdk: flutter\n'
        'dev_dependencies:\n  flutter_test:\n    sdk: flutter\n');
    File(p.join(pkg.path, 'lib/a.dart')).writeAsStringSync('bool lt(int a, int b) => a < b;\n');
    File(p.join(pkg.path, 'test/a_test.dart')).writeAsStringSync("import 'package:flutter_test/flutter_test.dart';\n"
        "import 'package:probe/a.dart';\n"
        "void main() { test('lt', () { expect(lt(1, 2), isTrue); expect(lt(2, 1), isFalse); }); }\n");
    try {
      final r = await Process.run('flutter', ['pub', 'get', '--offline'], workingDirectory: pkg.path)
          .timeout(const Duration(minutes: 2));
      if (r.exitCode != 0) {
        skip = '`flutter pub get --offline` failed here (flutter_test dependencies not in the pub cache): ${(r.stderr as String).trim().split('\n').first}';
        return;
      }
      ready = true;
    } on ProcessException {
      skip = 'flutter is not on PATH';
    }
  });
  tearDownAll(() {
    if (ready) pkg.deleteSync(recursive: true);
  });

  // --no-pub: no implicit `pub get` (which would need the network) inside the sandbox.
  const testCmd = ['flutter', 'test', '--no-pub', '--reporter', 'json', 'test/a_test.dart'];
  const runner = SystemProcessRunner();

  test('flutter test passes inside the sandbox, leaves the host export untouched, and costs about what it costs outside', () async {
    if (skip != null) markTestSkipped(skip!);
    if (skip != null) return;
    final before = tree(pkg.path);
    await runner.run(testCmd, workingDirectory: pkg.path, timeout: const Duration(minutes: 2)); // warm-up
    final plain = await runner.run(testCmd, workingDirectory: pkg.path, timeout: const Duration(minutes: 2));
    expect(parseReporterStream(plain.stdoutLines, root: pkg.path).doneSuccess, isTrue, reason: plain.stderr);
    final afterPlain = tree(pkg.path);
    final sandbox = Sandbox.discover(pkg.path, command: testCmd);
    final boxed = SandboxedProcessRunner(runner, sandbox);
    final inside = await boxed.run(testCmd, workingDirectory: pkg.path, timeout: const Duration(minutes: 2));
    final parsed = parseReporterStream(inside.stdoutLines, root: pkg.path);
    expect(parsed.loadErrors, isEmpty, reason: '${inside.stderr}\n${inside.stdoutLines.take(5).join('\n')}');
    expect(parsed.sawDone && parsed.doneSuccess, isTrue, reason: inside.stderr);
    expect(parsed.tests.where((t) => !t.skipped && !t.failed), hasLength(1));
    expect(inside.exitCode, 0);
    expect(inside.survivors, isEmpty);
    expect(tree(pkg.path), afterPlain, reason: 'the sandboxed run wrote nothing to the host export');
    expect(before, isNotEmpty);
    // ignore: avoid_print
    print('flutter test, one file: unsandboxed ${plain.elapsed.inMilliseconds} ms, sandboxed ${inside.elapsed.inMilliseconds} ms; '
        'read-only under HOME: ${sandbox.binds}');
    // The JSON stream is clean: the first-run banner of a fresh HOME is suppressed.
    expect(inside.stdoutLines.where((l) => !l.startsWith('{')), isEmpty);
  });

  test('the pub cache has to be bound: without it the same run cannot load its test', () async {
    if (skip != null) return;
    final full = Sandbox.discover(pkg.path, command: testCmd);
    final home = Platform.environment['HOME'];
    final cache = Platform.environment['PUB_CACHE'] ?? (home == null ? null : '$home/.pub-cache');
    if (cache == null || !full.binds.contains(cache)) {
      markTestSkipped('the pub cache is not a bind of its own here: nothing hides it');
      return;
    }
    final bare = Sandbox(
        exportPath: pkg.path,
        home: full.home,
        binds: [for (final b in full.binds) if (b != cache) b],
        symlinks: full.symlinks);
    // Without the cache flutter reports the missing package files; it may then
    // linger under load, so the run is bounded and judged by what it printed.
    final o = await SandboxedProcessRunner(runner, bare)
        .run(testCmd, workingDirectory: pkg.path, timeout: const Duration(seconds: 45));
    final parsed = parseReporterStream(o.stdoutLines, root: pkg.path);
    expect(parsed.sawDone && parsed.doneSuccess, isFalse, reason: 'the test cannot pass without the pub cache');
    expect('${o.stdoutLines.join('\n')}\n${o.stderr}', contains('.pub-cache'),
        reason: 'it names the files it could not read\nexit ${o.exitCode}');
  });
}
