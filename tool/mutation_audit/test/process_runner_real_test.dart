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
}
