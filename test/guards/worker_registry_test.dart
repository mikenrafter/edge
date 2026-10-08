// worker_registry_test.dart — the EXISTING worker entries are registered
// (design 02 migration step 1). Every function that lib/ hands directly to
// Isolate.run / compute / DerivationEngine._runIsolateCancellable /
// Isolate.spawn is a `kWorkerEntries` row.
//
// Whether each row resolves, is @heavy, is static, is dispatched through the
// kind it names, and obeys the sendable grammar is the guard's job
// (heavy_calc_guard_test.dart); this test pins WHICH functions are registered,
// so dropping one is a deliberate act.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/util/worker_entries.dart';

/// Substring of `Symbol.toString()` -> expected dispatcher.
const kExpected = <String, Dispatcher>{
  'deriveDayBundle': Dispatcher.cancellable,
  'buildCrossDayBundle': Dispatcher.cancellable,
  'foldDayCheckpoint': Dispatcher.cancellable,
  'foldDayTailHeavy': Dispatcher.cancellable,
  'kcalMinutesForDayHeavy': Dispatcher.run,
  'derivationPrepareWorker': Dispatcher.spawn,
  '_dayBlocksIsolateEntry': Dispatcher.spawn,
  '_reencodeBatchHeavy': Dispatcher.run,
  '_spotCheckComputeHeavy': Dispatcher.run,
  '_breathingCoherenceComputeHeavy': Dispatcher.run,
  'ecgFormatPageHeavy': Dispatcher.run,
  '_writeZipHeavy': Dispatcher.run,
  'observeNaturalSync': Dispatcher.run,
  'encryptBackupFile': Dispatcher.run,
  'decryptBackupFile': Dispatcher.run,
  // The sample archive (lib/data/sample_heavy.dart): encode / carve / reconstruct
  // were inline `Isolate.run` closures (baselined as dispatcherClosureContract).
  'encodeSampleSignalsHeavy': Dispatcher.run,
  'carveSamplePartHeavy': Dispatcher.run,
  'reconstructSamplePartsHeavy': Dispatcher.run,
};

void main() {
  for (final e in kExpected.entries) {
    test('${e.key} is registered with dispatcher ${e.value.name}', () {
      final hit = kWorkerEntries
          .where((w) => w.symbol.toString().contains(e.key))
          .toList();
      expect(hit, hasLength(1), reason: 'registered exactly once');
      expect(hit.single.dispatcher, e.value);
      expect(hit.single.reason, isNotEmpty);
    });
  }

  test('nothing else is registered', () {
    expect(kWorkerEntries, hasLength(kExpected.length));
  });
}
