@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/events.dart';
import 'support/git_fixture.dart';

/// The real tool, a real SIGINT. The fake test command passes on the
/// unmutated tree; once the mutant is applied it starts a TERM-ignoring
/// `sleep` and waits. Bounded by timeouts, not by sleeps.
///
/// Two variants: `--no-sandbox` (the process family is found by identity; the
/// sleeper's pid comes through a file) and the default, bubblewrap (the fake
/// test lives in the export and nothing it writes is visible on the host, so
/// the sleeper is found by its unique command line in /proc).
String? _noBwrap() {
  try {
    final r = Process.runSync('bwrap', ['--ro-bind', '/', '/', '--unshare-pid', '--die-with-parent', 'true']);
    return r.exitCode == 0 ? null : 'bubblewrap cannot create a sandbox here';
  } on ProcessException {
    return 'bubblewrap (bwrap) is not installed';
  }
}

void main() {
  late GitFixture fx;
  late Directory work;
  Process? tool;
  int? sleeper;
  // Unique per test process: found in /proc/*/cmdline.
  final sleepMarker = '9$pid.5';

  int? findSleeper() {
    for (final e in Directory('/proc').listSync(followLinks: false)) {
      final n = int.tryParse(p.basename(e.path));
      if (n == null) continue;
      try {
        if (File('${e.path}/cmdline').readAsStringSync().contains('sleep\u0000$sleepMarker')) return n;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  late String passingJsonl;
  setUp(() async {
    passingJsonl = '${passing().build().join('\n')}\n';
    fx = await GitFixture.create({
      'pubspec.yaml': 'name: demo\nenvironment:\n  sdk: ^3.0.0\n',
      'lib/a.dart': 'bool lt(int a, int b) => a < b;\n',
      'test/a_test.dart': '// faked\n',
      // For the sandboxed variant: /tmp is not visible inside, the export is.
      'fake/passing.jsonl': passingJsonl,
      'fake/fake_test.sh': '''
#!/bin/sh
if grep -q 'a <= b' lib/a.dart; then
  trap '' TERM
  sleep $sleepMarker &
  wait
fi
cat fake/passing.jsonl
''',
    });
    work = scratch('mutaudit_e2e_');
  });
  tearDown(() {
    tool?.kill(ProcessSignal.sigkill);
    if (sleeper != null) Process.killPid(sleeper!, ProcessSignal.sigkill);
    fx.dispose();
    work.deleteSync(recursive: true);
  });

  bool dead(int pid) {
    final stat = File('/proc/$pid/stat');
    if (!stat.existsSync()) return true;
    final text = stat.readAsStringSync();
    return text.substring(text.lastIndexOf(')') + 2).startsWith('Z');
  }

  Future<void> interruptedAudit(ProcessSignal signal, {required bool sandbox}) async {
    File(p.join(work.path, 'passing.jsonl')).writeAsStringSync('${passing().build().join('\n')}\n');
    File(p.join(work.path, 'fake_test.sh')).writeAsStringSync('''
#!/bin/sh
if grep -q 'a <= b' lib/a.dart; then
  trap '' TERM
  sleep 300 &
  echo \$! > "\$MARK"
  wait
fi
cat "\$PASSING"
''');
    final mark = File(p.join(work.path, 'mark'));
    final sha = await fx.head();
    final statusBefore = await fx.status();
    final out = p.join(work.path, 'out');
    tool = await Process.start(
        'dart',
        [
          'bin/mutation_audit.dart',
          '--repo', fx.root,
          '--sha', sha,
          '--files', 'lib/a.dart',
          '--test-cmd', sandbox ? 'sh fake/fake_test.sh' : 'sh ${p.join(work.path, 'fake_test.sh')}',
          '--setup-cmd', '',
          if (!sandbox) '--no-sandbox',
          '--no-guards',
          '--timeout', '120',
          '--env', 'MARK=${mark.path}',
          '--env', 'PASSING=${p.join(work.path, 'passing.jsonl')}',
          '--out', out,
        ],
        workingDirectory: Directory.current.path);
    final stderr = StringBuffer();
    tool!.stderr.transform(utf8.decoder).listen(stderr.write);
    tool!.stdout.drain<void>();

    // Real time, bounded: the tool has to compile, export and reach the mutant.
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    bool started() => sandbox ? findSleeper() != null : mark.existsSync() && mark.readAsStringSync().trim().isNotEmpty;
    while (!started()) {
      expect(DateTime.now().isBefore(deadline), isTrue, reason: 'the mutant run never started: $stderr');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    sleeper = sandbox ? findSleeper() : int.parse(mark.readAsStringSync().trim());
    expect(dead(sleeper!), isFalse);

    tool!.kill(signal);
    final code = await tool!.exitCode.timeout(const Duration(seconds: 60));
    expect(code, 130, reason: '$stderr');
    expect(stderr.toString(), contains('interrupted'));
    expect(dead(sleeper!), isTrue, reason: 'the running tests were stopped, SIGTERM being ignored');
    expect(await fx.worktrees(), isNot(contains('mutation_audit_')), reason: 'the export was removed');
    expect(Directory(out).existsSync() && File(p.join(out, 'results.json')).existsSync(), isFalse);
    expect(await fx.status(), statusBefore);
    expect(File(p.join(fx.root, 'lib/a.dart')).readAsStringSync(), 'bool lt(int a, int b) => a < b;\n');
  }

  test('SIGINT while a mutant is running (--no-sandbox): tests reaped, file restored, export removed, exit 130',
      () => interruptedAudit(ProcessSignal.sigint, sandbox: false),
      timeout: const Timeout(Duration(seconds: 180)));

  test('SIGTERM does the same (--no-sandbox)',
      () => interruptedAudit(ProcessSignal.sigterm, sandbox: false),
      timeout: const Timeout(Duration(seconds: 180)));

  test('SIGINT while a sandboxed mutant run is going: the sandbox and its TERM-ignoring sleeper are gone, exit 130',
      () => interruptedAudit(ProcessSignal.sigint, sandbox: true),
      skip: _noBwrap(),
      timeout: const Timeout(Duration(seconds: 180)));

  test('SIGTERM does the same (sandboxed)',
      () => interruptedAudit(ProcessSignal.sigterm, sandbox: true),
      skip: _noBwrap(),
      timeout: const Timeout(Duration(seconds: 180)));
}
