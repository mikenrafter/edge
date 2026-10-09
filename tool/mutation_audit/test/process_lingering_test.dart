import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:test/test.dart';

import 'support/fake_host.dart';

const term = ProcessSignal.sigterm;
const kill = ProcessSignal.sigkill;

/// Finding 5 (review round 3): the family is stopped before run() returns on
/// every path, a normal finish included, and the run says how many processes
/// it had to stop.
void main() {
  late FakeHost host;
  late SystemProcessRunner runner;

  void setUpHost({bool ownsSession = true}) {
    host = FakeHost(ownsSession: ownsSession);
    runner = SystemProcessRunner(
      host: host,
      termGrace: const Duration(seconds: 5),
      drainGrace: const Duration(seconds: 2),
      pollEvery: const Duration(milliseconds: 100),
    );
  }

  setUp(setUpHost);

  Future<ProcessOutcome> run({Duration? timeout = const Duration(seconds: 60), CancelToken? cancel}) =>
      host.clock.drive(runner.run(['tool', 'test'], workingDirectory: '/x', timeout: timeout, cancel: cancel));

  Map<int, List<ProcessSignal>> signalled() {
    final out = <int, List<ProcessSignal>>{};
    for (final (pid, sig) in host.signals) {
      out.putIfAbsent(pid, () => []).add(sig);
    }
    return out;
  }

  group('nothing is left behind, whatever ended the run', () {
    test('a normal finish: a detached child that left the pipes is stopped before run() returns', () async {
      late FakeProc lingering;
      host.script = (h) {
        h.print('done');
        lingering = h.spawn(holdsOutput: false);
        h.at(const Duration(seconds: 3), () => h.rootExits(0));
      };
      final o = await run();
      expect(o.timedOut, isFalse);
      expect(o.exitCode, 0);
      expect(o.stdoutLines, ['done']);
      expect(lingering.alive, isFalse);
      expect(signalled()[lingering.pid], [term]);
      expect(o.lingeringStopped, 1);
      expect(signalled().containsKey(FakeHost.rootPid), isFalse, reason: 'the exited root is not signalled');
    });

    test('a normal finish with a child that ignores TERM: KILL after the grace period', () async {
      late FakeProc stubborn;
      host.script = (h) {
        stubborn = h.spawn(ignoresTerm: true, holdsOutput: false);
        h.at(const Duration(seconds: 3), () => h.rootExits(0));
      };
      final o = await run();
      expect(stubborn.alive, isFalse);
      expect(signalled()[stubborn.pid], [term, kill]);
      expect(o.lingeringStopped, 1);
      expect(host.clock.now, greaterThanOrEqualTo(const Duration(seconds: 8)), reason: '3 s + 5 s grace');
    });

    test('a normal finish with nothing left: no signal, nothing counted', () async {
      host.script = (h) {
        final quick = h.spawn(holdsOutput: false);
        h.at(const Duration(seconds: 1), () => h.exits(quick.pid));
        h.at(const Duration(seconds: 3), () => h.rootExits(0));
      };
      final o = await run();
      expect(host.signals, isEmpty);
      expect(o.lingeringStopped, 0);
    });

    test('no session of its own: a descendant sampled while the root ran is stopped after a normal finish', () async {
      setUpHost(ownsSession: false);
      late FakeProc child, grandchild;
      host.script = (h) {
        child = h.spawn(holdsOutput: false);
        grandchild = h.spawn(parent: child.pid, holdsOutput: false);
        h.at(const Duration(seconds: 3), () => h.rootExits(0));
      };
      final o = await run();
      expect(child.alive || grandchild.alive, isFalse);
      expect(o.lingeringStopped, 2);
    });

    test('a lingering process whose pid was reused is not signalled and not counted', () async {
      late FakeProc quitter, stranger;
      host.script = (h) {
        quitter = h.spawn(holdsOutput: false);
        h.at(const Duration(seconds: 2), () => h.exits(quitter.pid));
        h.at(const Duration(milliseconds: 2500), () => stranger = h.reusePid(quitter.pid, ppid: 1));
        h.at(const Duration(seconds: 3), () => h.rootExits(0));
      };
      final o = await run();
      expect(stranger.alive, isTrue);
      expect(signalled().containsKey(quitter.pid), isFalse);
      expect(o.lingeringStopped, 0);
    });

    test('a timeout counts the processes other than the child', () async {
      host.script = (h) {
        h.spawn(holdsOutput: true);
        h.spawn(holdsOutput: true);
      };
      final o = await run(timeout: const Duration(seconds: 5));
      expect(o.timedOut, isTrue);
      expect(o.lingeringStopped, 2);
    });

    test('a cancellation counts them too', () async {
      final token = CancelToken();
      host.script = (h) {
        h.spawn(holdsOutput: true);
        h.at(const Duration(seconds: 1), token.cancel);
      };
      final o = await run(cancel: token);
      expect(o.cancelled, isTrue);
      expect(o.lingeringStopped, 1);
    });

    test('a run that finishes cleanly counts zero', () async {
      host.script = (h) => h.at(const Duration(seconds: 1), () => h.rootExits(0));
      expect((await run()).lingeringStopped, 0);
    });
  });
}
