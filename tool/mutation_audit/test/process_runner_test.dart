import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:test/test.dart';

import 'support/fake_host.dart';

const term = ProcessSignal.sigterm;
const kill = ProcessSignal.sigkill;

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

  /// Every pid that got a signal, and which.
  Map<int, List<ProcessSignal>> signalled() {
    final out = <int, List<ProcessSignal>>{};
    for (final (pid, sig) in host.signals) {
      out.putIfAbsent(pid, () => []).add(sig);
    }
    return out;
  }

  group('a run that finishes by itself', () {
    test('returns the output and exit code, signals nothing, leaves no timer behind', () async {
      host.script = (h) {
        h.print('one');
        h.print('two');
        h.at(const Duration(seconds: 3), () => h.rootExits(7));
      };
      final o = await run();
      expect(o.stdoutLines, ['one', 'two']);
      expect(o.exitCode, 7);
      expect(o.timedOut, isFalse);
      expect(o.cancelled, isFalse);
      expect(o.outputComplete, isTrue);
      expect(host.signals, isEmpty);
      expect(host.clock.pending, 0, reason: 'the timeout alarm was cancelled');
    });

    test('no timeout: no alarm at all', () async {
      host.script = (h) => h.at(const Duration(seconds: 1), () => h.rootExits(0));
      await run(timeout: null);
      expect(host.clock.pending, 0);
    });

    test('a program that cannot be started is exit code 127 with the reason', () async {
      final o = await host.clock.drive(runner.run(['missing'], workingDirectory: '/x'));
      expect(o.exitCode, 127);
      expect(o.stderr, contains('No such file'));
      expect(host.starts, 0);
    });
  });

  group('a timeout', () {
    test('stops a process that obeys SIGTERM: only SIGTERM, to the whole family, nothing else', () async {
      late FakeProc child, grandchild;
      host.script = (h) {
        h.print('partial');
        child = h.spawn(holdsOutput: true);
        grandchild = h.spawn(parent: child.pid, holdsOutput: true);
      };
      final o = await run(timeout: const Duration(seconds: 10));
      expect(o.timedOut, isTrue);
      expect(o.cancelled, isFalse);
      expect(o.outputComplete, isTrue);
      expect(o.stdoutLines, ['partial']);
      expect(signalled().keys.toSet(), {FakeHost.rootPid, child.pid, grandchild.pid});
      expect(host.signals.every((s) => s.$2 == term), isTrue, reason: 'nobody needed SIGKILL');
      expect(host.signals.first.$1, grandchild.pid, reason: 'deepest first');
      expect(host.procs.values.where((p) => p.alive), isEmpty);
    });

    test('a descendant that ignores SIGTERM gets SIGKILL after the grace period, and only it', () async {
      late FakeProc stubborn, polite;
      host.script = (h) {
        stubborn = h.spawn(ignoresTerm: true, holdsOutput: true);
        polite = h.spawn(holdsOutput: true);
      };
      final o = await run(timeout: const Duration(seconds: 10));
      expect(o.timedOut, isTrue);
      expect(signalled()[stubborn.pid], [term, kill]);
      expect(signalled()[polite.pid], [term], reason: 'it was already gone when the grace ran out');
      expect(signalled()[FakeHost.rootPid], [term]);
      expect(host.clock.now, greaterThanOrEqualTo(const Duration(seconds: 15)),
          reason: '10 s timeout + 5 s grace, in virtual time');
      expect(host.procs.values.where((p) => p.alive), isEmpty);
      expect(o.outputComplete, isTrue);
    });

    test('SIGKILL is a real SIGKILL, not a second SIGTERM', () async {
      host.script = (h) => h.root.ignoresTerm = true;
      await run(timeout: const Duration(seconds: 1));
      expect(signalled()[FakeHost.rootPid], [term, kill]);
    });

    test('the wrapper exits at once but a child keeps the pipes open: the timeout still applies', () async {
      late FakeProc orphan;
      host.script = (h) {
        h.print('started');
        orphan = h.spawn(ignoresTerm: true, holdsOutput: true);
        h.at(const Duration(seconds: 1), () => h.rootExits(0));
      };
      final o = await run(timeout: const Duration(seconds: 30));
      expect(o.timedOut, isTrue, reason: 'exit alone is not the end of the run');
      expect(o.stdoutLines, ['started']);
      expect(o.outputComplete, isTrue);
      expect(orphan.alive, isFalse);
      expect(signalled()[orphan.pid], [term, kill], reason: 'found by session after the wrapper reparented it');
      expect(signalled().containsKey(FakeHost.rootPid), isFalse, reason: 'an exited root is not signalled (its pid may be reused)');
    });

    test('processes that forked while SIGTERM was being handled are found by the rescan', () async {
      late FakeProc late_;
      host.script = (h) {
        h.root.ignoresTerm = true;
        // Forks 1 s after the timeout, during the grace period.
        h.at(const Duration(seconds: 11), () => late_ = h.spawn(holdsOutput: true));
      };
      await run(timeout: const Duration(seconds: 10));
      expect(late_.alive, isFalse);
      expect(signalled()[late_.pid], [kill]);
    });

    test('a process that cannot be killed does not hang the run: output is reported incomplete', () async {
      late FakeProc stuck;
      host.script = (h) {
        h.print('before');
        stuck = h.spawn(ignoresTerm: true, holdsOutput: true)..unkillable = true;
      };
      final o = await run(timeout: const Duration(seconds: 10));
      expect(o.timedOut, isTrue);
      expect(o.outputComplete, isFalse);
      expect(o.stdoutLines, ['before'], reason: 'what was read stays');
      expect(stuck.alive, isTrue);
    });

    test('only the family is signalled: unrelated processes are left alone', () async {
      final other = host.bystander();
      final sibling = host.bystander(ppid: 1, sid: 4242);
      host.script = (h) => h.spawn(holdsOutput: true);
      await run(timeout: const Duration(seconds: 5));
      expect(signalled().containsKey(other.pid), isFalse);
      expect(signalled().containsKey(sibling.pid), isFalse);
      expect(host.signals.every((s) => s.$1 > 1), isTrue, reason: 'never a group, never init');
    });

    test('without a session of its own only descendants are found (a reparented child is out of reach)', () async {
      setUpHost(ownsSession: false);
      late FakeProc reparented, descendant;
      host.script = (h) {
        reparented = h.spawn(holdsOutput: true);
        descendant = h.spawn(holdsOutput: true);
        h.at(const Duration(milliseconds: 500), () => reparented.ppid = 1);
      };
      final o = await run(timeout: const Duration(seconds: 1));
      expect(o.timedOut, isTrue);
      expect(o.outputComplete, isFalse, reason: 'the reparented child still holds the pipes; the runner gave up waiting');
      expect(signalled().containsKey(descendant.pid), isTrue);
      expect(signalled().containsKey(reparented.pid), isFalse);
    });
  });

  group('cancellation', () {
    test('a cancelled run stops the family and says so', () async {
      final token = CancelToken();
      late FakeProc child;
      host.script = (h) {
        child = h.spawn(ignoresTerm: true, holdsOutput: true);
        h.at(const Duration(seconds: 2), token.cancel);
      };
      final o = await run(cancel: token);
      expect(o.cancelled, isTrue);
      expect(o.timedOut, isFalse);
      expect(child.alive, isFalse);
      expect(signalled()[child.pid], [term, kill]);
      expect(host.clock.pending, 0);
    });

    test('a token that is already cancelled starts nothing', () async {
      final token = CancelToken()..cancel();
      final o = await run(cancel: token);
      expect(o.cancelled, isTrue);
      expect(host.starts, 0);
    });

    test('cancel after a normal finish changes nothing', () async {
      final token = CancelToken();
      host.script = (h) => h.at(const Duration(seconds: 1), () => h.rootExits(0));
      final o = await run(cancel: token);
      token.cancel();
      expect(o.cancelled, isFalse);
      expect(host.signals, isEmpty);
    });
  });

  group('CancelToken', () {
    test('cancel is idempotent and visible through the flag and the future', () async {
      final t = CancelToken();
      expect(t.isCancelled, isFalse);
      var seen = false;
      t.whenCancelled.then((_) => seen = true);
      t.cancel();
      t.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(t.isCancelled, isTrue);
      expect(seen, isTrue);
    });
  });
}
