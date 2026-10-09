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
void main() {
  late GitFixture fx;
  late Directory work;
  Process? tool;
  int? sleeper;

  setUp(() async {
    fx = await GitFixture.create({
      'pubspec.yaml': 'name: demo\nenvironment:\n  sdk: ^3.0.0\n',
      'lib/a.dart': 'bool lt(int a, int b) => a < b;\n',
      'test/a_test.dart': '// faked\n',
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

  Future<void> interruptedAudit(ProcessSignal signal) async {
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
          '--test-cmd', 'sh ${p.join(work.path, 'fake_test.sh')}',
          '--setup-cmd', '',
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
    while (!(mark.existsSync() && mark.readAsStringSync().trim().isNotEmpty)) {
      expect(DateTime.now().isBefore(deadline), isTrue, reason: 'the mutant run never started: $stderr');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    sleeper = int.parse(mark.readAsStringSync().trim());
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

  test('SIGINT while a mutant is running: tests reaped, file restored, export removed, exit 130',
      () => interruptedAudit(ProcessSignal.sigint),
      timeout: const Timeout(Duration(seconds: 180)));

  test('SIGTERM does the same',
      () => interruptedAudit(ProcessSignal.sigterm),
      timeout: const Timeout(Duration(seconds: 180)));
}
