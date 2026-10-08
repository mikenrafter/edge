// worker_audit_test.dart — design 02, rev 8: the dispatcher audit sees entries
// from INSIDE the worker.
//
// `WorkerAudit.entered` runs in whatever isolate the entry runs in, and a
// static is isolate-local, so a main-isolate hook alone can only see an entry
// that was called directly on the main isolate (it proves dispatch, not which
// worker ran). A test that installs `onEntry` now also gets `auditPort`: the
// dispatchers hand that SendPort to the worker (`WorkerAudit.wrap` for closure
// dispatchers, a message field / handshake for the spawn entries) and the
// worker reports `(entry, isolate id)` back through it.
//
// Production installs no hook: `auditPort` is null, `wrap` returns the very
// closure it was given, `adopt(null)` does nothing, and an entry that finds no
// port and no hook returns at once, so no audit message is ever sent.

import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/util/worker_audit.dart';
import 'package:openstrap_edge/util/worker_entries.dart';

// A top-level stand-in "entry" so the closure below captures nothing.
int _entryLikeWork() {
  WorkerAudit.entered('fakeEntry');
  return 7;
}

void main() {
  final entries = <EntryEvent>[];
  final dispatches = <DispatchEvent>[];

  tearDown(WorkerAudit.reset);

  group('production: no hook installed', () {
    test('there is no audit port and wrap hands the closure back untouched', () {
      expect(WorkerAudit.auditPort, isNull);
      int work() => 1;
      expect(identical(WorkerAudit.wrap(work), work), isTrue);
    });

    test('adopt(null) and entered() with neither port nor hook do nothing', () {
      WorkerAudit.adopt(null);
      WorkerAudit.entered('x');
      expect(WorkerAudit.auditPort, isNull);
    });

    test('a worker that adopted nothing reports nothing to a main hook',
        () async {
      WorkerAudit.onEntry = entries.add;
      entries.clear();
      // No wrap/adopt: the worker has no port, so its entered() is silent.
      expect(await Isolate.run(_entryLikeWork), 7);
      await pumpEventQueue();
      expect(entries, isEmpty);
    });
  });

  group('with a hook installed', () {
    setUp(() {
      entries.clear();
      dispatches.clear();
      WorkerAudit.onEntry = entries.add;
      WorkerAudit.onDispatch = dispatches.add;
    });

    test('an entry reached through wrap() reports from ITS isolate', () async {
      expect(WorkerAudit.auditPort, isNotNull);
      expect(await Isolate.run(WorkerAudit.wrap(_entryLikeWork)), 7);
      await pumpEventQueue();

      expect(entries.map((e) => e.entry), ['fakeEntry']);
      expect(entries.single.isolateId, isNot(WorkerAudit.currentIsolateId),
          reason: 'the entry ran in a worker, not on the test isolate');
    });

    test('two workers have two different isolate ids', () async {
      await Isolate.run(WorkerAudit.wrap(_entryLikeWork));
      await Isolate.run(WorkerAudit.wrap(_entryLikeWork));
      await pumpEventQueue();
      expect(entries, hasLength(2));
      expect(entries[0].isolateId, isNot(entries[1].isolateId));
    });

    test('a direct call on this isolate is reported with THIS isolate id', () {
      _entryLikeWork();
      expect(entries.single.isolateId, WorkerAudit.currentIsolateId);
    });

    test('a dispatch records the dispatching isolate and the stack', () {
      WorkerAudit.dispatched(Dispatcher.run, 'probe');
      expect(dispatches.single.label, 'probe');
      expect(dispatches.single.kind, Dispatcher.run);
      expect(dispatches.single.isolateId, WorkerAudit.currentIsolateId);
      expect(dispatches.single.stack.toString(), contains('worker_audit_test'));
    });

    test('reset() closes the port: a later install gets a fresh one', () async {
      final first = WorkerAudit.auditPort;
      WorkerAudit.reset();
      expect(WorkerAudit.auditPort, isNull);
      WorkerAudit.onEntry = entries.add;
      expect(WorkerAudit.auditPort, isNot(same(first)));
    });
  });
}
