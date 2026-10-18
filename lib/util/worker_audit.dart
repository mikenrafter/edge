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
//   * a dispatcher hands that port to the worker, with the id [dispatched]
//     returned for this dispatch: [wrap] for closure dispatchers, message
//     fields for `_dayBlocksIsolateEntry`, an `audit` command for the prepare
//     worker; the worker calls [adopt];
//   * [entered], running in the worker, sends `(entry, isolate id, dispatch id)`
//     through it.
// The test can then assert WHICH registered entry ran, that it ran in a
// different isolate than the dispatcher, and that it ran FOR that dispatch: a
// dispatch is matched by the reports carrying its id, never by the set of
// entries seen anywhere in the run.
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

  /// Per-dispatch token: unique within the process, starting at 1. The
  /// dispatcher hands it to the worker with the audit port and the worker echoes
  /// it in every [EntryEvent] it reports, so a dispatch is matched by the entry
  /// reports it caused and by no others.
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

  /// The [DispatchEvent.id] of the dispatch whose worker reported this entry.
  /// Null for an entry called directly (no dispatch), or in a worker whose
  /// dispatcher handed it no token.
  final int? dispatchId;
  const EntryEvent(this.entry, this.isolateId, {this.dispatchId});

  /// The plain, sendable form sent through the audit port.
  List<Object?> toMessage() => <Object?>[entry, isolateId, dispatchId];

  factory EntryEvent.fromMessage(List<dynamic> m) => EntryEvent(
      m[0] as String, m[1] as String,
      dispatchId: m.length > 2 ? m[2] as int? : null);

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

  /// Worker side: the id of the dispatch this isolate runs for. Set by [adopt].
  static int? _dispatchId;

  /// Test side: the last id handed out by [dispatched].
  static int _lastId = 0;

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
  /// otherwise a closure that adopts the audit port (and the dispatch's
  /// [dispatchId], from [dispatched]) in the worker, then runs [work].
  static FutureOr<T> Function() wrap<T>(FutureOr<T> Function() work,
      [int? dispatchId]) {
    final port = auditPort;
    if (port == null) return work;
    return () {
      adopt(port, dispatchId);
      return work();
    };
  }

  /// Worker side: report this isolate's entries to [port], each tagged with
  /// [dispatchId]. A null port does nothing.
  static void adopt(SendPort? port, [int? dispatchId]) {
    if (port == null) return;
    _report = port;
    // 0 is `dispatched`'s "no hook" answer, not a dispatch.
    _dispatchId = dispatchId == 0 ? null : dispatchId;
  }

  /// An approved dispatcher is about to run work on another isolate. Returns the
  /// dispatch's id for the dispatcher to hand to its worker ([wrap] / [adopt]);
  /// 0 when no hook is installed (production), where nothing uses it.
  static int dispatched(Dispatcher kind, String label) {
    final hook = onDispatch;
    if (hook == null) return 0;
    final id = ++_lastId;
    hook(DispatchEvent(kind, label, currentIsolateId, StackTrace.current,
        id: id));
    return id;
  }

  /// A registered worker entry started, in the isolate it runs in.
  static void entered(String entry) {
    final port = _report;
    final hook = onEntry;
    if (port == null && hook == null) return;
    final event =
        EntryEvent(entry, currentIsolateId, dispatchId: _dispatchId);
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
    _dispatchId = null;
    _inbox?.close();
    _inbox = null;
  }
}
