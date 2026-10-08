// entry_samples.dart — one sample of argument/result per registered worker
// entry, used by the per-entry sendability and determinism tests (design 02).
// Adding a `WorkerEntry` without adding its sample here fails
// heavy_sendability_helper_test ("every kWorkerEntries symbol has a sample").
//
// Step 1 registers no entries, so this is empty.

typedef EntrySample = ({
  Future<void> Function() roundTrip,
});

final Map<Symbol, EntrySample> kEntrySamples = <Symbol, EntrySample>{};
