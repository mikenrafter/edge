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
