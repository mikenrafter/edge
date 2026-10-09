@TestOn('linux')
library;

import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/git_fixture.dart';

/// Real children, bounded to a few seconds each. These pin the one thing a
/// fake cannot: that processes that ignore SIGTERM and hold the pipes really
/// are stopped, and that the runner really returns.
void main() {
  // Short grace periods keep the real children to a couple of seconds.
  const runner = SystemProcessRunner(
      termGrace: Duration(milliseconds: 400), drainGrace: Duration(seconds: 1), pollEvery: Duration(milliseconds: 50));
  late Directory dir;
  setUp(() => dir = scratch('mutaudit_real_'));
  tearDown(() => dir.deleteSync(recursive: true));

  String script(String body) {
    final f = File(p.join(dir.path, 'child.sh'))..writeAsStringSync('#!/bin/sh\n$body\n');
    return f.path;
  }

  /// Gone, or a zombie waiting to be reaped by someone else.
  bool dead(int pid) {
    final stat = File('/proc/$pid/stat');
    if (!stat.existsSync()) return true;
    final text = stat.readAsStringSync();
    return text.substring(text.lastIndexOf(')') + 2).startsWith('Z');
  }

  int grandchild(ProcessOutcome o) {
    final line = o.stdoutLines.firstWhere((l) => l.startsWith('gc='));
    return int.parse(line.substring(3));
  }

  test('an ordinary run: output lines, stderr, exit code, nothing stopped', () async {
    final path = script('echo one; echo two; echo err >&2; exit 3');
    final outcome = await runner.run(['sh', path], workingDirectory: dir.path, timeout: const Duration(seconds: 10));
    expect(outcome.stdoutLines, ['one', 'two']);
    expect(outcome.stderr.trim(), 'err');
    expect(outcome.exitCode, 3);
    expect(outcome.timedOut, isFalse);
    expect(outcome.cancelled, isFalse);
    expect(outcome.outputComplete, isTrue);
  });

  test('a program that does not exist is a failed run (non-zero exit), not an exception', () async {
    final outcome = await runner.run(['/definitely/not/here'], workingDirectory: dir.path, timeout: const Duration(seconds: 5));
    expect(outcome.exitCode, isNot(0));
    expect(outcome.timedOut, isFalse);
  });

  test('a cancelled run stops a TERM-ignoring tree and returns once it is gone', () async {
    final path = script('''
trap '' TERM
sleep 120 &
echo "gc=\$!"
wait''');
    final token = CancelToken();
    final running = runner.run(['sh', path], workingDirectory: dir.path, cancel: token);
    // Real time, bounded: wait for the child to say it is up, then cancel.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!File(p.join(dir.path, 'up')).existsSync() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (File(path).existsSync()) break; // the script is already written; give it a moment to start
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    token.cancel();
    final outcome = await running;
    final gc = grandchild(outcome);
    addTearDown(() => Process.killPid(gc, ProcessSignal.sigkill));
    expect(outcome.cancelled, isTrue);
    expect(outcome.timedOut, isFalse);
    expect(dead(gc), isTrue);
    expect(outcome.elapsed, lessThan(const Duration(seconds: 6)));
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('identity is checked before a signal: a stale start time is refused, the real one is honoured', () async {
    final sleeper = await Process.start('sleep', ['120']);
    addTearDown(() => sleeper.kill(ProcessSignal.sigkill));
    const host = SystemProcessHost();
    final real = host.identityOf(sleeper.pid)!;
    final stale = ProcIdentity(real.pid, '${real.start}0', real.ppid, real.sid);
    expect(host.signal(stale, ProcessSignal.sigkill), isFalse, reason: 'same pid, another start time: another process');
    expect(host.identityOf(sleeper.pid), isNotNull);
    expect((await host.snapshot())[sleeper.pid]!.start, real.start);
    expect(host.signal(real, ProcessSignal.sigterm), isTrue);
    await sleeper.exitCode.timeout(const Duration(seconds: 5));
    expect(host.signal(real, ProcessSignal.sigkill), isFalse, reason: 'gone');
    expect(host.identityOf(sleeper.pid), isNull);
  });

  test('a polite parent exits on SIGTERM, its TERM-ignoring child is reparented: still killed', () async {
    final path = script('''
( trap '' TERM; exec sleep 120 ) &
echo "gc=\$!"
wait''');
    final outcome = await runner.run(['sh', path], workingDirectory: dir.path, timeout: const Duration(seconds: 1));
    final gc = grandchild(outcome);
    addTearDown(() => Process.killPid(gc, ProcessSignal.sigkill));
    expect(outcome.timedOut, isTrue);
    expect(dead(gc), isTrue);
    expect(outcome.outputComplete, isTrue);
    expect(outcome.elapsed, lessThan(const Duration(seconds: 6)));
  }, timeout: const Timeout(Duration(seconds: 20)));

  group('a timeout stops the whole tree, with a TERM that is ignored', () {
    test('the wrapper exits at once, a TERM-ignoring child keeps the pipe open', () async {
      final path = script('''
trap '' TERM
( trap '' TERM; exec sleep 120 ) &
echo "gc=\$!"
exit 0''');
      final outcome = await runner
          .run(['sh', path], workingDirectory: dir.path, timeout: const Duration(seconds: 1));
      final gc = grandchild(outcome);
      addTearDown(() => Process.killPid(gc, ProcessSignal.sigkill));
      expect(outcome.timedOut, isTrue, reason: 'the run is bounded until the streams close, not only until the wrapper exits');
      expect(outcome.elapsed, lessThan(const Duration(seconds: 6)));
      expect(outcome.stdoutLines, contains(startsWith('gc=')));
      expect(dead(gc), isTrue, reason: 'the surviving child was stopped (SIGKILL after SIGTERM was ignored)');
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('the parent and its child both ignore TERM', () async {
      final path = script('''
trap '' TERM
sleep 120 &
echo "gc=\$!"
wait''');
      final outcome = await runner
          .run(['sh', path], workingDirectory: dir.path, timeout: const Duration(seconds: 1));
      final gc = grandchild(outcome);
      addTearDown(() => Process.killPid(gc, ProcessSignal.sigkill));
      expect(outcome.timedOut, isTrue);
      expect(outcome.elapsed, lessThan(const Duration(seconds: 6)));
      expect(dead(gc), isTrue);
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('a normal finish leaves nothing behind (isolation between mutants)', () {
    test('the child exits 0 and its detached helper, which let go of the pipes, is stopped before run() returns', () async {
      final path = script('''
sleep 213 >/dev/null 2>&1 </dev/null &
echo "gc=\$!"
exit 0''');
      final outcome = await runner.run(['sh', path], workingDirectory: dir.path, timeout: const Duration(seconds: 10));
      final gc = grandchild(outcome);
      addTearDown(() => Process.killPid(gc, ProcessSignal.sigkill));
      expect(outcome.timedOut, isFalse, reason: 'it finished normally: the pipes closed');
      expect(outcome.exitCode, 0);
      expect(dead(gc), isTrue, reason: 'still running after run() returned would leak into the next mutant');
      expect(outcome.lingeringStopped, 1);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a helper that ignores TERM gets KILL', () async {
      final path = script('''
( trap '' TERM; exec sleep 214 ) >/dev/null 2>&1 </dev/null &
echo "gc=\$!"
exit 0''');
      final outcome = await runner.run(['sh', path], workingDirectory: dir.path, timeout: const Duration(seconds: 10));
      final gc = grandchild(outcome);
      addTearDown(() => Process.killPid(gc, ProcessSignal.sigkill));
      expect(outcome.timedOut, isFalse);
      expect(dead(gc), isTrue);
      expect(outcome.lingeringStopped, 1);
      expect(outcome.elapsed, lessThan(const Duration(seconds: 6)));
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a clean child leaves nothing to stop', () async {
      final path = script('echo one; exit 0');
      final outcome = await runner.run(['sh', path], workingDirectory: dir.path, timeout: const Duration(seconds: 10));
      expect(outcome.lingeringStopped, 0);
    });
  });
}
