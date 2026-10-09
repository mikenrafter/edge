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
        h.at(const Duration(milliseconds: 200), () => reparented.ppid = 1);
      };
      final o = await run(timeout: const Duration(seconds: 5));
      expect(o.timedOut, isTrue);
      expect(o.outputComplete, isFalse, reason: 'the reparented child still holds the pipes; the runner gave up waiting');
      expect(signalled().containsKey(descendant.pid), isTrue);
      expect(signalled().containsKey(reparented.pid), isFalse);
    });
  });

  group('the family is remembered across the whole cleanup', () {
    test('no session of its own: a polite root exits on SIGTERM, its TERM-ignoring child is reparented and still gets SIGKILL', () async {
      setUpHost(ownsSession: false);
      late FakeProc stubborn;
      host.script = (h) => stubborn = h.spawn(ignoresTerm: true, holdsOutput: true);
      final o = await run(timeout: const Duration(seconds: 10));
      expect(o.timedOut, isTrue);
      expect(stubborn.alive, isFalse, reason: 'reparented to init when the root died, but captured before that');
      expect(signalled()[stubborn.pid], [term, kill]);
      expect(o.outputComplete, isTrue);
    });

    test('a descendant that made its own session is still found after the root is gone', () async {
      late FakeProc own;
      host.script = (h) => own = h.spawn(ignoresTerm: true, holdsOutput: true, sid: 777);
      final o = await run(timeout: const Duration(seconds: 10));
      expect(own.alive, isFalse);
      expect(signalled()[own.pid], [term, kill]);
      expect(o.outputComplete, isTrue);
    });

    test('a grandchild of a captured process that exits is reached through the captured set', () async {
      setUpHost(ownsSession: false);
      late FakeProc mid, leaf;
      host.script = (h) {
        mid = h.spawn(holdsOutput: false); // polite
        leaf = h.spawn(parent: mid.pid, ignoresTerm: true, holdsOutput: true);
      };
      await run(timeout: const Duration(seconds: 10));
      expect(leaf.alive, isFalse);
      expect(signalled()[leaf.pid], [term, kill]);
    });
  });

  group('sampling while the child runs', () {
    test('no session: a child captured while the root lived is still ours after the root exits and it is reparented', () async {
      setUpHost(ownsSession: false);
      late FakeProc child;
      host.script = (h) {
        child = h.spawn(ignoresTerm: true, holdsOutput: true);
        h.at(const Duration(seconds: 3), () => h.rootExits(0)); // reparents the child to init
      };
      final o = await run(timeout: const Duration(seconds: 20));
      expect(o.timedOut, isTrue);
      expect(child.alive, isFalse);
      expect(signalled()[child.pid], [term, kill]);
    });

    test('no session: a child forked and reparented between two samples is out of reach (documented limit)', () async {
      setUpHost(ownsSession: false);
      late FakeProc quick;
      host.script = (h) {
        h.at(const Duration(milliseconds: 1200), () {
          quick = h.spawn(ignoresTerm: true, holdsOutput: true);
          quick.ppid = 1; // already reparented when the next sample looks
        });
      };
      final o = await run(timeout: const Duration(seconds: 10));
      expect(quick.alive, isTrue);
      expect(o.outputComplete, isFalse);
    });

    test('the sampler stops with the run: no alarm is left behind', () async {
      host.script = (h) => h.at(const Duration(seconds: 5), () => h.rootExits(0));
      await run();
      expect(host.clock.pending, 0);
    });
  });

  group('process identity: a reused pid is never signalled', () {
    test('the root exits early, its pid is handed to an unrelated process that starts its own session', () async {
      late FakeProc orphan, stranger;
      host.script = (h) {
        orphan = h.spawn(ignoresTerm: true, holdsOutput: true);
        h.at(const Duration(seconds: 1), () => h.rootExits(0));
        // Later the number 100 is reused, and the newcomer calls setsid(): sid == 100.
        h.at(const Duration(seconds: 3), () => stranger = h.reusePid(FakeHost.rootPid, sid: FakeHost.rootPid));
      };
      final o = await run(timeout: const Duration(seconds: 10));
      expect(o.timedOut, isTrue);
      expect(stranger.alive, isTrue);
      expect(signalled().containsKey(FakeHost.rootPid), isFalse, reason: 'same pid, different start time');
      expect(signalled()[orphan.pid], [term, kill], reason: 'the real session member was captured while the root was alive');
      expect(o.outputComplete, isTrue);
    });

    test('a captured process exits on its own, its pid is reused: the SIGKILL round skips it', () async {
      late FakeProc quitter, stranger;
      host.script = (h) {
        h.root.ignoresTerm = true; // forces a SIGKILL round
        quitter = h.spawn(holdsOutput: false);
        // Gone by the time SIGTERM arrives (10 s), its pid is reused at 12 s.
        h.at(const Duration(seconds: 2), () => h.exits(quitter.pid));
        h.at(const Duration(seconds: 12), () => stranger = h.reusePid(quitter.pid, ppid: 1));
      };
      await run(timeout: const Duration(seconds: 10));
      expect(stranger.alive, isTrue, reason: 'an unrelated process that merely got the number');
      expect(signalled().containsKey(quitter.pid), isFalse);
      expect(signalled()[FakeHost.rootPid], [term, kill]);
    });

    test('a captured process dies during the grace period and its pid is reused: no SIGKILL to the newcomer', () async {
      late FakeProc polite, stranger;
      host.script = (h) {
        h.root.ignoresTerm = true;
        polite = h.spawn(holdsOutput: false);
        // SIGTERM kills it at 10 s; at 11 s the number is taken by someone else.
        h.at(const Duration(seconds: 11), () => stranger = h.reusePid(polite.pid, ppid: 1));
      };
      await run(timeout: const Duration(seconds: 10));
      expect(signalled()[polite.pid], [term]);
      expect(stranger.alive, isTrue);
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
