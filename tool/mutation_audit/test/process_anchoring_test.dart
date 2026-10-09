import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';
import 'package:test/test.dart';

import 'support/fake_host.dart';

const term = ProcessSignal.sigterm;

/// Finding 4 (review round 3): a process is adopted into the captured
/// family only when it is anchored to a member whose identity is re-validated
/// in the same scan, and did not start before it.
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

  group('adoption is anchored', () {
    test('the exit-time session scan runs after the root pid was reused: the newcomer\'s session is not ours', () async {
      late FakeProc stranger, kid, holder;
      host.script = (h) {
        // Something unrelated keeps the pipes open so the run ends by timeout.
        holder = h.bystander()..holdsOutput = true;
        h.at(const Duration(seconds: 1), () {
          h.rootExits(0);
          // Before the exit-time scan reads the table: the number 100 is handed
          // out again, the newcomer starts a session, and has a child in it.
          stranger = h.reusePid(FakeHost.rootPid, sid: FakeHost.rootPid);
          kid = h.spawn(parent: stranger.pid, sid: FakeHost.rootPid);
        });
      };
      final o = await run(timeout: const Duration(seconds: 10));
      expect(o.timedOut, isTrue);
      expect(signalled().containsKey(kid.pid), isFalse, reason: 'a child of the newcomer');
      expect(signalled().containsKey(stranger.pid), isFalse);
      expect(kid.alive && stranger.alive, isTrue);
      expect(host.refused, isEmpty, reason: 'nothing was even attempted on them');
      holder.holdsOutput = false;
    });

    test('a mixed-generation snapshot: the old parent entry next to a child of the process that replaced it', () async {
      late FakeProc parent, replacement, child;
      late ProcIdentity oldParent;
      host.script = (h) {
        h.root.holdsOutput = true;
        parent = h.spawn();
        h.at(const Duration(milliseconds: 2500), () {
          oldParent = h.identityNow(parent);
          h.exits(parent.pid);
          replacement = h.reusePid(parent.pid, ppid: 1, sid: 1);
          child = h.spawn(parent: replacement.pid, sid: 1);
          // The scan read the old entry of the number, then the new child.
          h.snapshotFilter = (real) => {...real, parent.pid: oldParent};
        });
      };
      final o = await run(timeout: const Duration(seconds: 10));
      expect(o.timedOut, isTrue);
      expect(signalled().containsKey(child.pid), isFalse);
      expect(signalled().containsKey(replacement.pid), isFalse);
      expect(child.alive && replacement.alive, isTrue);
    });

    test('a candidate that started before its supposed parent is not adopted', () async {
      late FakeProc older;
      host.script = (h) {
        h.root.holdsOutput = true;
        older = h.spawn(sid: 4242);
        older.started = 0; // older than the root: cannot be its child
      };
      final o = await run(timeout: const Duration(seconds: 5));
      expect(o.timedOut, isTrue);
      expect(signalled().containsKey(older.pid), isFalse);
      expect(older.alive, isTrue);
    });

    test('a member that is the same process at the snapshot but another one when re-read is not an anchor', () async {
      late FakeProc member, grandchild, replacement;
      host.script = (h) {
        h.root.holdsOutput = true;
        member = h.spawn(sid: 5000);
        h.at(const Duration(milliseconds: 1500), () {
          // The member dies and its number is reused after the snapshot is
          // taken but before the scan re-validates it.
          final stale = h.identityNow(member);
          h.exits(member.pid);
          replacement = h.reusePid(member.pid, ppid: 1, sid: 1);
          grandchild = h.spawn(parent: replacement.pid, sid: 1);
          h.snapshotFilter = (real) => {...real, member.pid: stale};
        });
      };
      await run(timeout: const Duration(seconds: 10));
      expect(signalled().containsKey(grandchild.pid), isFalse);
      expect(grandchild.alive, isTrue);
    });

    test('legitimate adoption still works: a child, a grandchild and the session of a live root', () async {
      late FakeProc child, grandchild, session;
      host.script = (h) {
        child = h.spawn(holdsOutput: true);
        grandchild = h.spawn(parent: child.pid, holdsOutput: true);
        session = h.spawn(parent: 1, sid: FakeHost.rootPid, holdsOutput: true);
      };
      final o = await run(timeout: const Duration(seconds: 5));
      expect(o.timedOut, isTrue);
      expect(signalled().keys.toSet(), containsAll([child.pid, grandchild.pid, session.pid]));
      expect(host.procs.values.where((p) => p.alive), isEmpty);
    });
  });
}
