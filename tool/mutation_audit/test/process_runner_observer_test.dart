import 'package:mutation_audit/mutation_audit.dart';
import 'package:test/test.dart';

import 'support/fake_host.dart';

/// The real runner tells a watcher the pid and every stdout line while the
/// child is still running (the heartbeat's input); the outcome is unchanged.
void main() {
  late FakeHost host;
  late SystemProcessRunner runner;

  setUp(() {
    host = FakeHost();
    runner = SystemProcessRunner(host: host);
  });

  Future<ProcessOutcome> run(RunObserver? observer) =>
      host.clock.drive(runner.run(['tool', 'test'], workingDirectory: '/x', observer: observer));

  test('the pid arrives at start, the lines while the child runs, and the outcome keeps them all', () async {
    final events = <String>[];
    host.script = (h) {
      h.print('one');
      h.at(const Duration(seconds: 1), () {
        events.add('t=1s');
        h.print('two');
      });
      h.at(const Duration(seconds: 2), () {
        events.add('exit');
        h.rootExits(0);
      });
    };
    final o = await run(RunObserver(
      onStart: (pid) => events.add('pid $pid'),
      onStdoutLine: (l) => events.add('line $l'),
    ));
    expect(events, ['pid 100', 'line one', 't=1s', 'line two', 'exit']);
    expect(o.stdoutLines, ['one', 'two']);
  });

  test('a line split over chunks is delivered once, whole; a last line without newline at the end', () async {
    final lines = <String>[];
    host.script = (h) {
      h.at(const Duration(seconds: 1), () {
        h.write('{"type":"te');
        h.write('st"}\nsecond\nthi');
      });
      h.at(const Duration(seconds: 2), () {
        h.write('rd');
        h.rootExits(0);
      });
    };
    final o = await run(RunObserver(onStdoutLine: lines.add));
    expect(lines, ['{"type":"test"}', 'second', 'third']);
    expect(o.stdoutLines, ['{"type":"test"}', 'second', 'third']);
  });

  test('a multi-byte character cut between chunks is not mangled', () async {
    final lines = <String>[];
    host.script = (h) {
      h.at(const Duration(seconds: 1), () => h.write('café → ok\n'));
      h.at(const Duration(seconds: 2), () => h.rootExits(0));
    };
    await run(RunObserver(onStdoutLine: lines.add));
    expect(lines, ['café → ok']);
  });

  test('an observer that throws cannot break the run or lose output', () async {
    host.script = (h) {
      h.print('one');
      h.print('two');
      h.at(const Duration(seconds: 1), () => h.rootExits(3));
    };
    final o = await run(RunObserver(onStart: (_) => throw StateError('x'), onStdoutLine: (_) => throw StateError('y')));
    expect(o.exitCode, 3);
    expect(o.stdoutLines, ['one', 'two']);
  });

  test('no observer: nothing changes', () async {
    host.script = (h) {
      h.print('one');
      h.at(const Duration(seconds: 1), () => h.rootExits(0));
    };
    expect((await run(null)).stdoutLines, ['one']);
  });
}
