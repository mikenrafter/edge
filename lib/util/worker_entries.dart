// worker_entries.dart — the one registry of heavy worker entry points
// (design 02). Adding an entry is reviewed like a schema change: the diff to
// this file is the review.
//
// Pure Dart: resolved by the guard in fixture packages too.

/// How an entry is dispatched off the UI isolate.
enum Dispatcher {
  /// `Isolate.run`
  run,

  /// Flutter `compute`
  compute,

  /// `DerivationEngine._runIsolateCancellable` (timeout kills the isolate)
  cancellable,

  /// A named `Isolate.spawn` entry point
  spawn,
}

/// One registered heavy worker entry.
///
/// [symbol] is a Symbol literal naming the function: `#deriveDayHeavy` for a
/// top-level function, `#DayWorker.deriveHeavy` for a static method. It carries
/// no library, so the guard fails on an ambiguous name.
class WorkerEntry {
  final Symbol symbol;
  final Dispatcher dispatcher;
  final String reason;
  const WorkerEntry(this.symbol, {required this.dispatcher, required this.reason});
}

/// An unresolved invocation (dynamic receiver, function-typed value) that is
/// allowed in non-heavy code. An exact fingerprint, not a pattern: [file] is
/// relative to `lib/`, [symbol] the enclosing declaration, [source] the
/// invocation source with every whitespace run collapsed to one space, and
/// [ordinal] its zero-based position among the unresolved invocations of that
/// symbol. A second unresolved invocation in the same symbol fails.
class UnresolvedOk {
  final String file;
  final String symbol;
  final String source;
  final int ordinal;
  final String reason;
  const UnresolvedOk({
    required this.file,
    required this.symbol,
    required this.source,
    required this.ordinal,
    required this.reason,
  });
}

/// Registered worker entries. Step 1 (RED): empty; GREEN registers the
/// existing isolate entries.
const List<WorkerEntry> kWorkerEntries = <WorkerEntry>[];

/// Fingerprinted unresolved invocations. Shrink-only.
const List<UnresolvedOk> kUnresolvedOk = <UnresolvedOk>[];
