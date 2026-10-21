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

/// Registered worker entries: every function lib/ hands DIRECTLY to
/// `Isolate.run` / `compute` / `DerivationEngine._runIsolateCancellable` /
/// `Isolate.spawn`.
///
/// LEGACY: none of them starts with `WorkerInit.ensure(…)` yet (their inputs —
/// clock, zone, locale — are not plumbed through the argument records without a
/// behaviour change) and most take `Map<String, dynamic>` or plain classes, so
/// the guard baselines `workerEntryNotInitialised` and `sendableGrammar` for
/// them. Each row's reason says what is legacy about it. Those baseline rows
/// can only shrink; a NEW entry must satisfy the contract outright.
///
/// Not registered on purpose: `DerivationEngine._cancellableIsolateEntry` is the
/// cancellable dispatcher's own trampoline (it runs an arbitrary closure), and
/// the analytics functions the readers hand to `Isolate.run` (`weekdayEffect`,
/// `journalCorrelations`, `journalNumericCorrelations`, `correctRr`) live in
/// another package; those closures stay in the guard baseline until each
/// reader becomes a persisted artifact.
const List<WorkerEntry> kWorkerEntries = <WorkerEntry>[
  WorkerEntry(
    #deriveDayBundle,
    dispatcher: Dispatcher.cancellable,
    reason: 'per-day pipeline (onehz_pipeline); legacy: Map<String, dynamic> '
        'in/out, DayCalculationState argument, no WorkerInit.ensure',
  ),
  WorkerEntry(
    #buildCrossDayBundle,
    dispatcher: Dispatcher.cancellable,
    reason: 'cross-day pipeline; legacy: JSON maps in/out, no WorkerInit.ensure',
  ),
  WorkerEntry(
    #auditBatchDay,
    dispatcher: Dispatcher.cancellable,
    reason: 'finalization audit: the pure batch re-derive of a finalizing day '
        '(no DayCalculationState); meets the contract (WorkerInit.ensure '
        'first, @SendableShape JSON-map input and result with round-trip '
        'tests)',
  ),
  WorkerEntry(
    #stageSleepCandidateHeavy,
    dispatcher: Dispatcher.cancellable,
    reason: 'one night\'s sleep staging (was the inline sleep-staging closure): '
        're-arms the analytics ambient globals, decodes/merges/cuts/prunes/'
        'encodes the encoded cardio row chunks; meets the contract '
        '(WorkerInit.ensure first, @SendableShape input carrying the '
        'substrate, @sendable result)',
  ),
  WorkerEntry(
    #foldDayCheckpoint,
    dispatcher: Dispatcher.cancellable,
    reason: 'day-checkpoint fold; legacy: no WorkerInit.ensure',
  ),
  WorkerEntry(
    #foldDayTailHeavy,
    dispatcher: Dispatcher.cancellable,
    reason: 'resumed day tail fold (streaming RR screen + day curves); meets '
        'the contract (WorkerInit.ensure first, state resume bytes in, '
        '@SendableShape JSON envelopes out)',
  ),
  WorkerEntry(
    #DerivationEngine.kcalMinutesForDayHeavy,
    dispatcher: Dispatcher.run,
    reason: 'stored-day calorie minutes; legacy: Substrate/Profile arguments, '
        'JSON map result, no WorkerInit.ensure',
  ),
  WorkerEntry(
    #derivationPrepareWorker,
    dispatcher: Dispatcher.spawn,
    reason: 'derivation prepare worker (SendPort protocol); legacy: no '
        'WorkerInit.ensure',
  ),
  WorkerEntry(
    #DerivationEngine._dayBlocksIsolateEntry,
    dispatcher: Dispatcher.spawn,
    reason: 'day-blocks spawn entry; legacy: _DayBlocksInput is not @sendable, '
        'no WorkerInit.ensure',
  ),
  WorkerEntry(
    #_reencodeBatchHeavy,
    dispatcher: Dispatcher.run,
    reason: 'legacy day_result re-encode batch (List<String> in/out); legacy: '
        'no WorkerInit.ensure',
  ),
  WorkerEntry(
    #_spotCheckComputeHeavy,
    dispatcher: Dispatcher.run,
    reason: 'live HRV spot-check decode + HRV; legacy: JSON map result, no '
        'WorkerInit.ensure',
  ),
  WorkerEntry(
    #_breathingCoherenceComputeHeavy,
    dispatcher: Dispatcher.run,
    reason: 'breathing coherence PSD; legacy: JSON map result, no '
        'WorkerInit.ensure',
  ),
  WorkerEntry(
    #ecgFormatPageHeavy,
    dispatcher: Dispatcher.run,
    reason: 'ECG export: formats one page of stored reading rows into log '
        'text; meets the contract (WorkerInit.ensure first, sendable '
        'WorkerInputs + @SendableShape row maps in, String out)',
  ),
  WorkerEntry(
    #_writeZipHeavy,
    dispatcher: Dispatcher.run,
    reason: 'dev-log zip writer (file I/O only); legacy: no WorkerInit.ensure',
  ),
  WorkerEntry(
    #observeNaturalSync,
    dispatcher: Dispatcher.run,
    reason: 'natural-wake stage observation; legacy: NaturalObserveRequest/'
        'Result are not @sendable, no WorkerInit.ensure',
  ),
  WorkerEntry(
    #encryptBackupFile,
    dispatcher: Dispatcher.run,
    reason: 'PBKDF2 backup encrypt; legacy: File/Random parameters, no '
        'WorkerInit.ensure',
  ),
  WorkerEntry(
    #decryptBackupFile,
    dispatcher: Dispatcher.run,
    reason: 'PBKDF2 backup decrypt; legacy: File parameters, no '
        'WorkerInit.ensure',
  ),
  WorkerEntry(
    #encodeSampleSignalsHeavy,
    dispatcher: Dispatcher.run,
    reason: 'sample archive encode (one day-device, all signals); meets the '
        'contract (WorkerInit.ensure first, sendable slots/modes in, '
        'sendable records out)',
  ),
  WorkerEntry(
    #carveSamplePartHeavy,
    dispatcher: Dispatcher.run,
    reason: 'sample archive carve of an incoming part around covered minutes; '
        'meets the contract (WorkerInit.ensure first, sendable in/out)',
  ),
  WorkerEntry(
    #reconstructSamplePartsHeavy,
    dispatcher: Dispatcher.run,
    reason: 'sample archive reconstruction (decode + overlay of the stored '
        'parts); meets the contract (WorkerInit.ensure first, sendable '
        'in/out)',
  ),
  WorkerEntry(
    #decodeJsonPayloadsHeavy,
    dispatcher: Dispatcher.run,
    reason: 'generic stored JSON decode/encode lane; WorkerInit.ensure first, '
        '@SendableShape JSON values in and out with round-trip tests',
  ),
  WorkerEntry(
    #decodeDayPayloadsHeavy,
    dispatcher: Dispatcher.run,
    reason: 'BundleStore decode: stored payload_json texts to frozen compact '
        'graphs or projections, sized in the worker; meets the contract '
        '(WorkerInit.ensure first, sendable texts in, @SendableShape frozen '
        'JSON graphs out)',
  ),
  WorkerEntry(
    #wearableSubstrateHeavy,
    dispatcher: Dispatcher.run,
    reason: 'a wearable\'s day substrate (Colmi/Garmin/Oura/Ultrahuman rows '
        'to channels, the strap overlay, the Colmi temperature slots, the '
        'Ultrahuman records); meets the contract (WorkerInit.ensure first, '
        '@SendableShape row-map input and transfer-map result with a '
        'round-trip test)',
  ),
  WorkerEntry(
    #unionCutHeavy,
    dispatcher: Dispatcher.run,
    reason: 'the cuts and the join of a day\'s cross-day union load (the '
        'per-second arrays of RetainedLoad.windowHeavy / joinHeavy); meets the contract '
        '(WorkerInit.ensure first, @SendableShape RetainedLoad input and '
        'result with a round-trip test)',
  ),
  WorkerEntry(
    #sessionWindowsHeavy,
    dispatcher: Dispatcher.run,
    reason: 'a workout list\'s per-session HR windows with a workout sensor '
        'flagged on (group, window rule, stats, samples); meets the contract '
        '(WorkerInit.ensure first, @SendableShape row-map input, sendable '
        'result with a round-trip test)',
  ),
];

/// Fingerprinted unresolved invocations. Shrink-only.
const List<UnresolvedOk> kUnresolvedOk = <UnresolvedOk>[
  UnresolvedOk(
    file: 'data/db.dart',
    symbol: 'LocalDb.importFromDbFile',
    source: 'onProgress?.call(const ImportPreparing(ImportPrepStep.inflating))',
    ordinal: 0,
    reason: 'import progress callback: sets one ValueNotifier on the caller side',
  ),
  UnresolvedOk(
    file: 'data/db.dart',
    symbol: 'LocalDb._mergeFromDbFileBody',
    source: 'onProgress?.call(const ImportPreparing(ImportPrepStep.opening))',
    ordinal: 0,
    reason: 'import progress callback: sets one ValueNotifier on the caller side',
  ),
  UnresolvedOk(
    file: 'data/db.dart',
    symbol: 'LocalDb._mergeFromDbFileBody',
    source: 'onProgress?.call(const ImportPreparing(ImportPrepStep.checking))',
    ordinal: 1,
    reason: 'import progress callback: sets one ValueNotifier on the caller side',
  ),
  UnresolvedOk(
    file: 'data/import_copy_plan.dart',
    symbol: 'ImportCopyPlan._report',
    source: '_emit(ImportCopying(run.stage, done, run.total, slot.run, _runs.length))',
    ordinal: 0,
    reason: 'import progress callback: sets one ValueNotifier on the caller side',
  ),
  UnresolvedOk(
    file: 'data/db.dart',
    symbol: 'LocalDb._openReader',
    source: 'readerOpenerForTest?.call(path)',
    ordinal: 0,
    reason: 'test seam replacing the read-connection open; production opens one sqflite connection, no stored-data loop',
  ),
  UnresolvedOk(
    file: 'data/db.dart',
    symbol: 'LocalDb.metricSeriesBundle',
    source: 'body(db)',
    ordinal: 0,
    reason: 'local closure running the bundle\'s three SELECTs on one executor (reader or writer transaction); bounded statements, no row loop of its own',
  ),
  UnresolvedOk(
    file: 'data/db.dart',
    symbol: 'LocalDb.putBaselines',
    source: 'nowMs()',
    ordinal: 0,
    reason: 'injectable clock seam (one scalar), moved here from putBaseline',
  ),
  UnresolvedOk(
    file: 'data/db.dart',
    symbol: 'LocalDb.readerRun',
    source: 'body(db)',
    ordinal: 0,
    reason: 'runs a caller\'s pure-SELECT body on the read connection; the bodies are LocalDb reader methods, each one bounded query',
  ),
  UnresolvedOk(
    file: 'data/db.dart',
    symbol: 'LocalDb.readerRun',
    source: 'body(await instance)',
    ordinal: 1,
    reason: 'the same body retried once on the writer when the reader closed mid-read',
  ),
  UnresolvedOk(
    file: 'compute/derive_perf.dart',
    symbol: 'DerivePerf.addCountLazy',
    source: 'value()',
    ordinal: 0,
    reason: 'perf counter whose value is costly to measure (a node walk, a byte sum): runs only when the instance is enabled, one scalar out, no stored-data loop of its own',
  ),
  UnresolvedOk(
    file: 'ecg/ecg_controller.dart',
    symbol: 'EcgController._asked',
    source: 'provider?.call()',
    ordinal: 0,
    reason: 'injected provider seam: returns the band/device context for one capture; bounded, no stored-data loop',
  ),
  UnresolvedOk(
    file: 'ecg/ecg_controller.dart',
    symbol: 'EcgController._offsetAt',
    source: 'utcOffsetMin?.call(epochMs)',
    ordinal: 0,
    reason: 'injected UTC-offset seam (design 01): one scalar lookup per saved reading',
  ),
  UnresolvedOk(
    file: 'ui2/screens/ecg.dart',
    symbol: '_EcgDetailScreenState._delete',
    source: '(widget.onDelete ?? (x) => LocalDb.deleteEcgReading(x))(id)',
    ordinal: 0,
    reason: 'injected delete seam for tests; production deletes one attempt group in a transaction',
  ),
  UnresolvedOk(
    file: 'ui2/screens/ecg.dart',
    symbol: '_runEcgExport',
    source: 'e.appVersion()',
    ordinal: 1,
    reason: 'injected export environment: app version string',
  ),
  UnresolvedOk(
    file: 'ui2/screens/ecg.dart',
    symbol: '_runEcgExport',
    source: 'e.now()',
    ordinal: 0,
    reason: 'injected export environment: the export clock (no real time in tests)',
  ),
  UnresolvedOk(
    file: 'ui2/screens/ecg.dart',
    symbol: '_runEcgExport',
    source: "saver(logFileName('ecg', at), chunks)",
    ordinal: 2,
    reason: 'injected log saver (saveLogChunksResult in production, invariant 16)',
  ),
  UnresolvedOk(
    file: 'compute/prv_export.dart',
    symbol: 'exportPrvLog',
    source: 'env.now()',
    ordinal: 0,
    reason: 'injected export environment: the export clock (no real time in tests)',
  ),
  UnresolvedOk(
    file: 'compute/prv_export.dart',
    symbol: 'exportPrvLog',
    source: 'env.appVersion()',
    ordinal: 1,
    reason: 'injected export environment: app version string',
  ),
  UnresolvedOk(
    file: 'compute/prv_export.dart',
    symbol: 'exportPrvLog',
    source: "save(logFileName('prv', at), text)",
    ordinal: 2,
    reason: 'injected log saver (saveLogFileResult in production, invariant 16)',
  ),
  UnresolvedOk(
    file: 'util/log_file.dart',
    symbol: 'saveLogChunksResult',
    source: "(share ?? (p) => Share.shareXFiles( [XFile(p, mimeType: 'text/plain')], subject: 'OpenStrap log', sharePositionOrigin: origin ?? const Rect.fromLTWH(0, 0, 1, 1), ))(file.path)",
    ordinal: 0,
    reason: 'injected share seam (the one write path; saveLogFile and saveLogFileResult are thin wrappers); one platform share call',
  ),
  UnresolvedOk(
    file: 'util/worker_audit.dart',
    symbol: 'WorkerAudit.dispatched',
    source: 'hook(DispatchEvent(kind, label, currentIsolateId, StackTrace.current, id: id))',
    ordinal: 0,
    reason: 'test-installed audit hook: a function-typed static, null in '
        'production',
  ),
  UnresolvedOk(
    file: 'util/worker_audit.dart',
    symbol: 'WorkerAudit.entered',
    source: 'hook(event)',
    ordinal: 0,
    reason: 'test-installed audit hook: a function-typed static, null in '
        'production',
  ),
  UnresolvedOk(
    file: 'util/worker_audit.dart',
    symbol: 'WorkerAudit.auditPort',
    source: 'hook(EntryEvent.fromMessage(message))',
    ordinal: 0,
    reason: 'test-installed audit hook: a function-typed static, null in '
        'production (the port only exists when it is installed)',
  ),
  UnresolvedOk(
    file: 'util/worker_audit.dart',
    symbol: 'WorkerAudit.wrap',
    source: 'work()',
    ordinal: 0,
    reason: 'runs the dispatcher\'s own closure after adopting the audit port; '
        'wrap only exists to prefix a closure the dispatcher already runs',
  ),
  UnresolvedOk(
    file: 'compute/derivation_engine.dart',
    symbol: 'DerivationEngine._auditAtFinalization',
    source: 'read()',
    ordinal: 0,
    reason: 'injected power-state reader (a function-typed field the owner '
        'assigns): one platform read at the moment of finalization, no '
        'stored-data loop',
  ),
  UnresolvedOk(
    file: 'compute/derivation_engine.dart',
    symbol: 'DerivationEngine.auditPendingFinalizations',
    source: 'read()',
    ordinal: 0,
    reason: 'injected power-state reader (a function-typed field the owner '
        'assigns): one platform read per audit pass, no stored-data loop',
  ),
  UnresolvedOk(
    file: 'compute/derivation_engine.dart',
    symbol: 'DerivationEngine._auditLog',
    source: 'debugPrint(m)',
    ordinal: 0,
    reason: 'Flutter\'s function-typed debugPrint hook, one log line',
  ),
  UnresolvedOk(
    file: 'compute/derivation_engine.dart',
    symbol: 'DerivationEngine._auditLog',
    source: 'log?.call(m)',
    ordinal: 1,
    reason: 'the engine\'s injected log sink, one log line',
  ),
  UnresolvedOk(
    file: 'compute/derivation_engine.dart',
    symbol: 'DerivationEngine._derivePreparedDay',
    source: 'debugSecondHalfHook?.call(day.date)',
    ordinal: 0,
    reason: 'upstream\'s test-only seam (static, null in production)',
  ),
  UnresolvedOk(
    file: 'compute/derivation_engine.dart',
    symbol: 'DerivationEngine._derivePreparedDay',
    source: 'debugAccumulatorTamper?.call(day.date, bundle)',
    ordinal: 2,
    reason: 'test-only seam (@visibleForTesting), null in production',
  ),
  UnresolvedOk(
    file: 'compute/derivation_engine.dart',
    symbol: 'DerivationEngine._derivePreparedDay',
    source: 'onStaleTonight(day.date)',
    ordinal: 3,
    reason: 'the pass\'s Set.add tear-off: records a day to derive once more '
        'after the pool (D25)',
  ),
  UnresolvedOk(
    file: 'data/db.dart',
    symbol: 'LocalDb.updateFinalizationAudit',
    source: 'change(s)',
    ordinal: 0,
    reason: 'the caller\'s mutation of the one audit-counter row (a handful '
        'of fields), no stored-data loop',
  ),
  UnresolvedOk(
    file: 'data/db.dart',
    symbol: 'LocalDb.updateFinalizationAudit',
    source: 'nowMs()',
    ordinal: 1,
    reason: 'injectable clock seam: one scalar read',
  ),
];
