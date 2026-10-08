# Heavy-guard baseline changelog

`test/guards/heavy_calc_baseline.json` lists legacy occurrences of the
heavy-calculation guard (design 02). It may only SHRINK against the target
branch, with one reviewed exception: extending a rule so that it reports more
than before.

To do that:

1. Raise the rule's version in `kRuleVersions`
   (`test/guards/support/heavy_guard.dart`).
2. Add an entry below: a level-2 heading `## <ruleName> v<newVersion>` (exactly
   that shape; the test reads it) followed by what the rule now catches and why
   the new findings are legacy code that cannot move yet.
3. Regenerate the baseline (see `heavy_calc_guard_test.dart`). It records the
   rule versions it was built with.

`heavy_baseline_test.dart` (CI runs it against `origin/$BASE_REF`) allows growth
only for the keys of a rule whose version is higher than in the target branch's
baseline AND that has its entry here. A new key of any other rule, or of an
unbumped rule, fails. A baseline from before versions existed reads as every
rule at v1.

Newest entries last.

## heavyOriginOutsideHeavy v2 - stored-data iteration

The rule also counts iterating STORED DATA outside `@heavy`: the sample lists of
`Substrate`, `DayBundleInput`, `PreparedDerivationDay` and
`PreparedDerivationPayload`, and the cross-day day-record arrays in
`compute/crossday_pipeline.dart` and `compute/crossday_input.dart`. Before v2
only direct calls into analytics/codec APIs were found, so loops over decoded
samples with no such call were invisible. The new keys are existing loops in
derivation, cross-day and screen code that move into registered workers with the
persisted-artifact migration (design 02, steps 2-3).

## workerEntryNotInitialised v2 - registered entries must start initialised

A registered worker entry must be a block body whose FIRST statement is
`WorkerInit.ensure(...)` or `assertWorker()`. Added when the 13 functions that
`lib/` already hands to `Isolate.run` / `compute` / `_runIsolateCancellable` /
`Isolate.spawn` were registered. All 13 are legacy entries whose clock, zone and
locale inputs are not plumbed through their argument records yet (that is a
behaviour change); a NEW entry must satisfy the contract outright.

## sendableGrammar v2 - nullable map keys; registered entries under the grammar

The closed sendable grammar now rejects `Map<String?, T>` (only non-null
`String` keys), and it is applied to the argument and result types of the 13
registered entries (`Map<String, dynamic>`, `Substrate`/`Profile`, private input
classes such as `_DayBlocksInput`, `NaturalObserveRequest`, ...). Those are
legacy types; the keys shrink as each entry gets a sendable value type.

## rawReaderUnregistered v2 - raw readers are found by what they return

A `LocalDb` method that reaches a raw table (`decoded_onehz`, `decoded_rr`,
`raw_records`, `raw_archive`) and RETURNS ROWS must be in `kRawReaders` and
return `RowBatch`. v2 decides "returns rows" by the return type, never by method
name: a method returning void/int/bool/num is not a reader, a `Map` counts only
when its values are row collections (`Map<String, List<Row>>`; scalar summaries
such as `Map<String, int>` or `Map<String, dynamic>` do not), and a migration
step is exempt only through the explicit `kMigrationMethods` list in the guard
config (empty today: no row-returning migration step exists). The remaining keys
are the existing row-returning readers (stager, sample, batch and day readers);
they become registered `RowBatch` readers or persisted artifacts later.

## Merge into the cumulative branch (2026-10-08) — baseline regenerated, 2,059 → 2,083
The guard landed in the same cumulative merge window as the sample archive
(lib/data/sample_*.dart), which predates the guard on its own branch. Its 24
occurrences (mostly unresolvedInvocation callback calls, plus heavyOriginOutsideHeavy
in the archiver/codec) were baselined instead of being moved into registered
worker entries. FOLLOW-UP: register the archive's encode/carve work as @heavy
entries (it already runs on Isolate.run) so these keys shrink out.

## Shrink (2026-10-08) — _foldTail inline closure → registered foldDayTailHeavy; 17 keys removed (2,083 → 2,066)
`DerivationEngine._foldTail` handed an inline closure to `_runIsolateCancellable`.
It is now the registered cancellable entry `foldDayTailHeavy`
(`lib/compute/day_tail_fold.dart`; the states cross as resume bytes). The 16
legacy `_foldTail` / `DayRrState.irregular24h` keys (dispatcherClosureContract 10,
captureNotSendable 2, heavyOriginOutsideHeavy 4) are gone: `irregular24h` is
folded into `irregular24hDetailedHeavy`, a `@heavy` inner function, so the five
keys the PRV diagnostics rename would have added never enter the baseline. The
17th is a stale `saveLogFile` unresolvedInvocation the writer pruned (the code
it fingerprinted no longer exists). Entries 1,896 → 1,879. No key added.

## rawReaderUnregistered v3 - the element type decides; scalar collections are not readers (2026-10-08)
v2 treated any `List` / `Iterable` / `Set` / `Stream` return as rows, so a method
that read a raw table and returned `List<int>` (timestamps, ids, hr values) was a
reader that had to be registered. v3 decides by the collection's ELEMENT type: a
scalar element (`int`, `double`, `num`, `String`, `bool`, `DateTime`, `Duration`,
an enum, or a nullable of these) is not rows. Everything else still is - a
`Map<String, *>`, a class or record such as `Sample`, `dynamic`, `Object?`,
`RowBatch` - so a typed projection of a raw table is not waved through. A `Map`
return still counts only when its values are such collections. This rule change
only NARROWS what is reported: no key is added; the keys it removes are listed in
the shrink entry that follows.

## Shrink (2026-10-08) — sample archive encode / reconstruct / carve → registered entries; 7 keys removed (2,066 → 2,059)
The archive's three inline `Isolate.run` closures are registered `Dispatcher.run`
entries in `lib/data/sample_heavy.dart` (`encodeSampleSignalsHeavy`,
`reconstructSamplePartsHeavy`, `carveSamplePartHeavy`), each dispatched with
`WorkerAudit.dispatched` ('sample encode' / 'sample reconstruct' / 'sample
carve'). Entries 1,879 → 1,872. Removed, no key added, no count raised:
- dispatcherClosureContract `SampleArchiver._archiveDevice`: `SampleCodec.encode`
- dispatcherClosureContract `SampleArchiver.reconstructWithOrigin`: `List.filled`,
  `SampleCodec.decode`, `SampleCodec.decodeCoarse`, `max`, `min`
- unresolvedInvocation `carveSamplePart`: `sampleCarveRunner(() => carveSamplePartSync(...))`
  (the function-typed `sampleCarveRunner` test seam is gone; the guard could not
  see through it, so it could not know the carve entry was dispatched. Tests record
  the hand-off through the audit hook instead.)

The `rawReaderUnregistered` v3 narrowing removed nothing from the real tree: the 9
baselined readers return `Map` rows, or `List<Sample>` (`samplesInRange`), which v3
still treats as rows. (The worker_audit hook fingerprint in `kUnresolvedOk` was
refreshed for the new `id:` argument; it is not a baseline key.)

## legacyInlineDispatch sleep-staging
`DerivationEngine` hands the sleep-staging closure (label `sleep-staging
<yyyy-mm-dd>`) to `_runIsolateCancellable`. It runs inline code, not a registered
entry (baselined `dispatcherClosureContract`), so the dispatcher audit cannot
require an entry report for it. The exception is the anchored pattern in
`test/guards/support/legacy_inline_dispatches.dart`; nothing may report under its
token. Delete the entry when the closure becomes a registered entry.

## legacyInlineDispatch crossday-input
The same for the cross-day input closure (exact label `crossday-input`).

## storedPayloadDecodeOutsideHeavy v1 - stored payloads decoded or encoded outside @heavy (2026-10-08)
New rule (design 02 step 2, P2.0b). `heavyOriginOutsideHeavy` only counts
`SeriesCodec.*` and analytics calls, so a plain `jsonDecode` of a stored
`payload_json` was invisible although it is the same UI-isolate cost. The rule
reports, in a non-`@heavy` function (inside `LocalDb` too), every `jsonDecode` /
`jsonEncode` / `json.decode` / `json.encode` call and every call into a payload
codec library (`SeriesCodec`, `HeavyGuardConfig.payloadCodecPrefixes`) when the
same function (a closure counts as its enclosing function) either names a
payload column in a string literal or const (`payload_json`, `window_json`,
`trace_json`, `meta_json`, `payload`, as a whole word) or calls a registered
payload reader (`kRawReaders`). One finding per call; the element is the called
function. A new rule has no earlier version to raise: the base baseline does not
list it, and this entry licenses its first keys (see the header). The keys are
the existing readers and writers of stored payloads in derivation, cross-day,
`LocalDb` and the repository read seam; P2.2 to P2.10 move them behind the
`BundleStore` lane and the write-path entries, and each phase removes the keys
in its scope.

Detection is by literal, not by data flow, so it can miss a decode whose
column name is not spelled in the same function. Known and left unflagged for
now: `getDayCalorieCurve` (key `kcal_minutes|...`, no column literal) and
`HealthExporter._decode`; both are scheduled in P2.5 and become visible if the
rule is later widened.

## rawTableRowLoopOutsideHeavy v1 - row loops over raw-table queries outside LocalDb (2026-10-08)
New rule (design 02 step 2, P2.0b). `rawReaderUnregistered` only looks at
methods of `LocalDb`, so a screen or archiver that runs `Database.query` /
`rawQuery` on `decoded_onehz`, `decoded_rr`, `raw_records` or `raw_archive` and
loops over the rows itself was invisible. The rule reports, in a non-`@heavy`
function outside `LocalDb`, each row loop (a `for-in`, or `map` / `forEach` /
`fold` / `where` / `any` / `every` / `expand` / `reduce` / `toList`) over the
result of such a call, where the table is named in that call's own literal or
const arguments (decided per call: a loop over another table's rows next to a
raw query in the same function is not a finding). The result may be iterated
directly or through a local variable initialised from the call. Reading
`length` / `isEmpty` / `isNotEmpty` / `first` / `firstOrNull` / `last` / `single`
is not a loop. One finding per loop; the element is the table. The keys are
`getDeviceChart` and the `SampleArchiver` day/device fill loops, which move to
registered chunk readers and `@heavy` fill entries in P2.12.

## rowBatchIterationOutsideHeavy (no version change) - first and last are cheap
`RowBatch.first` and `RowBatch.last` join `length` / `isEmpty` / `isNotEmpty`
as members that are not iteration (both are O(1)). This only NARROWS what the
rule reports, so it adds no key, raises no count and needs no version bump or
entry; this note records the widening of the cheap-member set. `single`,
`elementAt`, `toList`, `firstWhere` and every other member stay findings.
