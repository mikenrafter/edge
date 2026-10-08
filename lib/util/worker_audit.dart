// worker_audit.dart — the dispatcher audit hook (design 02, rev 4/5/6).
//
// The derivation engine's dispatchers (`_runIsolateCancellable`, the two
// `Isolate.spawn` sites, the kcal `Isolate.run`) report each dispatch with
// [WorkerAudit.dispatched] (kind, label, and the call stack at the dispatch);
// the registered worker entries in lib/ report that they started with
// [WorkerAudit.entered]. The reader / UI `Isolate.run` sites do not report yet
// (they migrate to persisted artifacts). Both hooks are null in production, so
// this costs one null check.
//
// Tests install the hooks to assert the runtime half of the guard's static
// contract: a background entry (iOS BGTask, headless sync) reaches heavy work
// ONLY through an approved dispatcher, and no registered entry ever runs on the
// isolate that dispatched it. [entered] runs in whatever isolate the entry runs
// in, so on the main isolate it fires only if the entry was called directly.
//
// Pure Dart (resolved by the guard's fixture packages too).

import 'worker_entries.dart';

class DispatchEvent {
  final Dispatcher kind;
  final String label;
  final StackTrace stack;
  const DispatchEvent(this.kind, this.label, this.stack);

  @override
  String toString() => '${kind.name}:$label';
}

class WorkerAudit {
  WorkerAudit._();

  /// Installed by tests; null in production.
  static void Function(DispatchEvent event)? onDispatch;

  /// Installed by tests; null in production.
  static void Function(String entry)? onEntry;

  /// An approved dispatcher is about to run work on another isolate.
  static void dispatched(Dispatcher kind, String label) {
    final hook = onDispatch;
    if (hook != null) hook(DispatchEvent(kind, label, StackTrace.current));
  }

  /// A registered worker entry started, in the isolate it runs in.
  static void entered(String entry) {
    final hook = onEntry;
    if (hook != null) hook(entry);
  }

  /// Clears both hooks.
  static void reset() {
    onDispatch = null;
    onEntry = null;
  }
}
