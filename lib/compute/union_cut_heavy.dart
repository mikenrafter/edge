// union_cut_heavy.dart — the cuts and the join of a day's cross-day union
// (see `DerivationEngine._loadUnion`) run in a worker, never on the UI isolate.
//
// OWNER: none; pure functions of their input. Every loop over the union's
// arrays (`RetainedLoad.windowHeavy`, `RetainedLoad.joinHeavy`) is reached only through
// [unionCutHeavy].
//
// COST. A union is up to ~140k 1 Hz samples (a dozen typed columns, ~15 MB).
// Isolate.run copies the input in and hands the result back without a copy, so
// a cut costs one copy of the load it cuts from. A day takes at most four
// round trips: all borrowed stretches in one (the bases are sent once, however
// many stretches they supply), the join in one, and one per window cut.
import 'dart:isolate';

import '../data/coverage_resolver.dart';
import '../ble/adapters/signals.dart';
import '../util/heavy.dart';
import '../util/worker_audit.dart';
import '../util/worker_entries.dart';
import '../util/worker_init.dart';
import 'substrate_retention.dart';

/// What [unionCutHeavy] does.
enum UnionCutKind {
  /// [UnionCutInput.stretches] cut out of [UnionCutInput.loads] (the bases).
  borrow,

  /// One window `[a, b]` of the single load in [UnionCutInput.loads].
  window,

  /// [UnionCutInput.loads] (the parts, in time order) joined as one load.
  join,
}

/// One stretch to borrow: `[a, b]` of `loads[base]`.
typedef UnionStretch = ({int base, int a, int b});

@SendableShape('carries RetainedLoad objects (typed-data columns, maps keyed '
    'by an enum, records and strings); round trip in '
    'test/sendable_unionCutHeavy_test.dart')
class UnionCutInput {
  const UnionCutInput({
    required this.kind,
    required this.loads,
    required this.ownership,
    required this.multiOwner,
    this.stretches = const [],
    this.a = 0,
    this.b = 0,
    this.revs = const {},
    this.generation = (wipeEpoch: 0, openCount: 0),
  });

  final UnionCutKind kind;
  final List<RetainedLoad> loads;
  final Map<InputSignal, List<OwnedSpan>> ownership;
  final bool multiOwner;
  final List<UnionStretch> stretches;
  final int a, b;

  /// [UnionCutKind.join] only: what the parts were validated under.
  final Map<int, int> revs;
  final ({int wipeEpoch, int openCount}) generation;
}

@SendableShape('RetainedLoad objects (typed-data columns, maps keyed by an '
    'enum, records) in a list, nulls where a cut was refused; round trip in '
    'test/sendable_unionCutHeavy_test.dart')
class UnionCutResult {
  const UnionCutResult(this.loads);

  /// One per stretch (borrow), or a single entry; null where the load refuses.
  final List<RetainedLoad?> loads;
}

/// The entries read no clock, zone or locale.
const WorkerInputs unionCutWorkerInputs =
    WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en');

/// WORKER ENTRY: the cuts and the join of a day's union. The same code, on the
/// same arrays, as the UI-isolate calls it replaced, so the output is
/// identical.
@heavy
UnionCutResult unionCutHeavy(WorkerInputs inputs, UnionCutInput input) {
  WorkerInit.ensure(inputs);
  assertWorker();
  WorkerAudit.entered('unionCutHeavy');
  switch (input.kind) {
    case UnionCutKind.borrow:
      return UnionCutResult([
        for (final st in input.stretches)
          input.loads[st.base].windowHeavy(st.a, st.b,
              ownership: input.ownership, multiOwner: input.multiOwner),
      ]);
    case UnionCutKind.window:
      return UnionCutResult([
        input.loads.single.windowHeavy(input.a, input.b,
            ownership: input.ownership, multiOwner: input.multiOwner),
      ]);
    case UnionCutKind.join:
      return UnionCutResult([
        RetainedLoad.joinHeavy(input.loads,
            revs: input.revs,
            ownership: input.ownership,
            multiOwner: input.multiOwner,
            generation: input.generation),
      ]);
  }
}

/// `Isolate.run(unionCutHeavy)`, audited as 'union cut'.
Future<UnionCutResult> runUnionCut(UnionCutInput input) {
  final dispatchId = WorkerAudit.dispatched(Dispatcher.run, 'union cut');
  final auditPort = WorkerAudit.auditPort; // null in production
  return Isolate.run(() {
    WorkerAudit.adopt(auditPort, dispatchId);
    return unionCutHeavy(unionCutWorkerInputs, input);
  });
}
