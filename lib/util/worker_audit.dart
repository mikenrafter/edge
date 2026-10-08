// worker_audit.dart — the dispatcher audit hook (design 02, rev 4/5/6/8).
//
// The derivation engine's dispatchers (`_runIsolateCancellable`, the two
// `Isolate.spawn` sites, the kcal `Isolate.run`) report each dispatch with
// [WorkerAudit.dispatched] (kind, label, dispatching isolate and the call stack
// at the dispatch); the registered worker entries in lib/ report that they
// started with [WorkerAudit.entered]. The reader / UI `Isolate.run` sites do
// not report yet (they migrate to persisted artifacts).
//
// A static is ISOLATE-LOCAL: a hook installed on the test's isolate is null in
// every worker, so `entered` there cannot see it. The audit therefore reports
// from inside the worker through a SendPort:
//   * the test installs [onEntry]; [auditPort] then returns the port that
//     forwards worker reports to it (null when no hook is installed);
//   * a dispatcher hands that port to the worker: [wrap] for closure
//     dispatchers, a message field for `_dayBlocksIsolateEntry`, an `audit`
//     command for the prepare worker; the worker calls [adopt];
//   * [entered], running in the worker, sends `(entry, isolate id)` through it.
// The test can then assert WHICH registered entry ran and that it ran in a
// different isolate than the dispatcher.
//
// Production installs nothing: [auditPort] is null, [wrap] returns its argument,
// [adopt] ignores null and [entered] returns at once when it has neither a port
// nor a hook, so no message is ever sent and no extra object is captured.
//
// Pure Dart (resolved by the guard's fixture packages too).

import 'dart:async';
import 'dart:isolate';

import 'worker_entries.dart';

class DispatchEvent {
  final Dispatcher kind;
  final String label;

  /// The isolate that dispatched (see [WorkerAudit.currentIsolateId]).
  final String isolateId;
  final StackTrace stack;

  /// Per-dispatch token (RED stub: always 0, real ids start at 1). The worker
  /// echoes it in every [EntryEvent] it reports, so a dispatch is matched by the
  /// entry reports it caused and by no others.
  final int id;
  const DispatchEvent(this.kind, this.label, this.isolateId, this.stack,
      {this.id = 0});

  @override
  String toString() => '${kind.name}:$label';
}

/// A registered worker entry started, in [isolateId].
class EntryEvent {
  final String entry;
  final String isolateId;

  /// The [DispatchEvent.id] of the dispatch whose worker reported this entry
  /// (RED stub: never set). Null for an entry called directly, with no dispatch.
  final int? dispatchId;
  const EntryEvent(this.entry, this.isolateId, {this.dispatchId});

  /// The plain, sendable form sent through the audit port.
  List<String> toMessage() => <String>[entry, isolateId];

  factory EntryEvent.fromMessage(List<dynamic> m) =>
      EntryEvent(m[0] as String, m[1] as String);

  @override
  String toString() => '$entry@$isolateId';
}

class WorkerAudit {
  WorkerAudit._();

  /// Installed by tests; null in production.
  static void Function(DispatchEvent event)? onDispatch;

  /// Installed by tests; null in production. Receives entries from every
  /// isolate: those reported through [auditPort] and direct calls on this one.
  static void Function(EntryEvent event)? onEntry;

  /// Worker side: where this isolate reports its entries. Set by [adopt].
  static SendPort? _report;

  /// Test side: the receive port that forwards worker reports to [onEntry].
  static ReceivePort? _inbox;

  /// A stable identity of the current isolate (the hash of its control port is
  /// the same wherever it is read and differs between isolates).
  static String get currentIsolateId =>
      '${Isolate.current.controlPort.hashCode}';

  /// The port a dispatcher hands to its worker, or null when no [onEntry] hook
  /// is installed (production). Created on first use.
  static SendPort? get auditPort {
    if (onEntry == null) return null;
    var inbox = _inbox;
    if (inbox == null) {
      inbox = _inbox = ReceivePort();
      inbox.listen((message) {
        final hook = onEntry;
        if (hook != null && message is List) {
          hook(EntryEvent.fromMessage(message));
        }
      });
    }
    return inbox.sendPort;
  }

  /// Closure dispatchers: returns [work] itself when no hook is installed,
  /// otherwise a closure that adopts the audit port in the worker, then runs
  /// [work].
  static FutureOr<T> Function() wrap<T>(FutureOr<T> Function() work,
      [int? dispatchId]) {
    final port = auditPort;
    if (port == null) return work;
    return () {
      adopt(port);
      return work();
    };
  }

  /// Worker side: report this isolate's entries to [port]. Null does nothing.
  static void adopt(SendPort? port, [int? dispatchId]) {
    if (port != null) _report = port;
  }

  /// An approved dispatcher is about to run work on another isolate. Returns
  /// the dispatch's id (RED stub: always 0).
  static int dispatched(Dispatcher kind, String label) {
    final hook = onDispatch;
    if (hook != null) {
      hook(DispatchEvent(kind, label, currentIsolateId, StackTrace.current));
    }
    return 0;
  }

  /// A registered worker entry started, in the isolate it runs in.
  static void entered(String entry) {
    final port = _report;
    final hook = onEntry;
    if (port == null && hook == null) return;
    final event = EntryEvent(entry, currentIsolateId);
    if (port != null) {
      port.send(event.toMessage());
    } else if (hook != null) {
      hook(event);
    }
  }

  /// Clears both hooks and closes the audit port.
  static void reset() {
    onDispatch = null;
    onEntry = null;
    _report = null;
    _inbox?.close();
    _inbox = null;
  }
}
