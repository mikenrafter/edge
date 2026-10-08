// heavy_guard.dart — the contract of the heavy-calculation guard engine
// (design 02, revisions 1-7). The types below are the API the tests compile
// against; the engine itself is heavy_guard_engine.dart (package:analyzer,
// resolved AST).
//
// The engine is test support, not app code: it lives under test/ and is not
// imported by lib/.

import 'dart:io';

import 'package:openstrap_edge/util/worker_entries.dart' show Dispatcher;

import 'heavy_guard_engine.dart' as engine;

/// Every finding the guard can raise. The fixture self-tests pin which rule
/// fires for which synthetic source, so the names are the contract.
enum HeavyRule {
  // (a) origin, not names
  /// An invocation whose resolved element comes from a heavy-origin library
  /// (analytics compute APIs, codec libraries) outside an `@heavy` body.
  heavyOriginOutsideHeavy(baselineable: true),

  /// Iterating (for-in, map, fold, forEach, ...) a `RowBatch` outside `@heavy`.
  rowBatchIterationOutsideHeavy(baselineable: true),

  // (b) @heavy <=> ...Heavy
  nameMarkerMismatch(baselineable: false),

  // (c) where heavy functions may be called
  /// Call of a heavy function outside `@heavy` / a direct dispatcher argument.
  /// Includes calls through a base method one of whose overrides is `@heavy`.
  heavyCallOutsideApprovedContext(baselineable: true),

  /// A tear-off of a heavy function that is stored, returned, or handed to a
  /// listener: it does not prove where execution happens.
  heavyReferenceEscapes(baselineable: true),

  /// A dispatcher closure body that is not: bindings, sendable-literal
  /// construction, at most ONE registered-entry call, wrapping its result.
  dispatcherClosureContract(baselineable: true),

  /// Dispatcher closure captures `this`, a non-sendable value, or a banned
  /// type (Database, BuildContext, StreamSubscription, channels).
  captureNotSendable(baselineable: true),

  // call-graph roots and the registry
  /// A heavy root (no heavy caller) that is not in `kWorkerEntries`.
  rootNotRegistered(baselineable: false),
  registryEntryUnresolved(baselineable: false),
  registryEntryAmbiguous(baselineable: false),
  registryEntryDuplicate(baselineable: false),
  registryEntryNotHeavy(baselineable: false),

  /// Entry registered with one `Dispatcher` but reached through another.
  registryDispatcherMismatch(baselineable: false),

  /// A registered, resolved, `@heavy` entry that no approved dispatcher ever
  /// runs: a dead registry entry.
  registryEntryNeverDispatched(baselineable: false),

  // sendable grammar
  /// `dynamic` / `Object` / `Object?` / non-sendable type anywhere (transitively)
  /// in a worker entry's argument or result type, without `@SendableShape`.
  /// Baselineable: the entries that exist today take `Map<String, dynamic>` and
  /// plain classes; new entries must not add to the ledger.
  sendableGrammar(baselineable: true),

  /// A registered entry that is not a top-level or static function.
  workerEntryNotStatic(baselineable: false),

  /// A registered entry whose body does not START with `WorkerInit.ensure(…)`
  /// or `assertWorker()`. Baselineable: the legacy entries cannot be given
  /// their inputs without a behaviour change.
  workerEntryNotInitialised(baselineable: true),

  /// `@SendableShape` type without a `sendable_<entry>_test.dart` round trip.
  sendableShapeTestMissing(baselineable: false),

  // fail closed
  /// Non-heavy invocation the analyzer cannot resolve to a concrete element.
  unresolvedInvocation(baselineable: true),

  /// A `kUnresolvedOk` fingerprint that matches no invocation (rot).
  unresolvedOkStale(baselineable: false),

  // @live
  liveCallsHeavy(baselineable: false),
  liveUnboundedLoop(baselineable: false),
  liveAndHeavy(baselineable: false),

  /// A `@live` function without `test/**/live_<symbol>_budget_test.dart`
  /// (`.` in the symbol becomes `_`).
  liveBudgetTestMissing(baselineable: false),

  // platform ban inside @heavy
  platformInHeavy(baselineable: false),

  // raw-row readers
  /// Baselineable: `LocalDb` has many legacy methods that touch raw tables by
  /// name (migrations, readers). New ones fail; the legacy ones migrate to
  /// registered `RowBatch` readers / persisted artifacts later.
  rawReaderUnregistered(baselineable: true),
  rawReaderWrongReturnType(baselineable: false),

  /// A `kMigrationMethods` entry (explicit exemption of a row-returning
  /// migration step) for a method that no longer needs it: remove the entry.
  migrationAllowStale(baselineable: false);

  const HeavyRule({required this.baselineable});

  /// Only code-site findings in legacy code may be absorbed by the baseline.
  /// Structure findings (registry, naming, grammar, @live) never are.
  final bool baselineable;
}

/// The version of every baselineable rule. The baseline JSON records the
/// versions it was built with (heavy_baseline.dart). The baseline may grow ONLY
/// for the keys of a rule whose version here is higher than in the target
/// branch's baseline, and only when test/guards/BASELINE_CHANGELOG.md has a
/// `## <rule> v<N>` entry for the new version. Raise a version when you EXTEND a
/// rule so that it reports more than before (a new origin, a stricter contract);
/// loosening a rule or fixing code never needs a bump.
///
/// v2: the four rules extended after the first guard commit (stored-data
/// iteration, worker entries must start initialised, `Map<String?, T>` and
/// plain-class entry types, raw readers by what they return). See the changelog.
const Map<HeavyRule, int> kRuleVersions = {
  HeavyRule.heavyOriginOutsideHeavy: 2,
  HeavyRule.rowBatchIterationOutsideHeavy: 1,
  HeavyRule.heavyCallOutsideApprovedContext: 1,
  HeavyRule.heavyReferenceEscapes: 1,
  HeavyRule.dispatcherClosureContract: 1,
  HeavyRule.captureNotSendable: 1,
  HeavyRule.sendableGrammar: 2,
  HeavyRule.workerEntryNotInitialised: 2,
  HeavyRule.unresolvedInvocation: 1,
  HeavyRule.rawReaderUnregistered: 2,
};

/// A `LocalDb` method that reads raw tables and returns rows but is a schema
/// migration / backfill / repair step handing them to its own caller, exempt
/// from the raw-reader registry. The list is EXPLICIT: a method is never exempt
/// because of its name (`ensureRows()` that returns rows is a raw reader), and a
/// method returning void/int/bool/num is never a raw reader at all.
class MigrationMethod {
  /// `LocalDb.method`
  final String symbol;
  final String reason;
  const MigrationMethod(this.symbol, this.reason);
}

/// The real tree's migration exemptions: each entry says why the method may
/// return rows without being a registered `RowBatch` reader. EMPTY today: no
/// `LocalDb` migration/backfill/repair step both touches a raw table and returns
/// rows (they return void/int/bool). An entry that stops needing its exemption
/// fails as `migrationAllowStale`.
const List<MigrationMethod> kMigrationMethods = <MigrationMethod>[];

/// One finding. [file] is relative to the analysed package's `lib/`; [symbol]
/// is the enclosing declaration (`Class.method`, `topLevelFn`, or
/// `Class.method#closure` is NOT used: closures count as their enclosing
/// function, rev 3); [element] the resolved element the finding is about
/// (`readinessCompute`, `RowBatch`, `this`, ...). No line numbers anywhere in
/// identity.
class HeavyViolation {
  final HeavyRule rule;
  final String file;
  final String symbol;
  final String element;
  final String message;
  const HeavyViolation({
    required this.rule,
    required this.file,
    required this.symbol,
    required this.element,
    required this.message,
  });

  @override
  String toString() => '${rule.name} $file :: $symbol -> $element ($message)';
}

class HeavyGuardResult {
  final List<HeavyViolation> violations;
  const HeavyGuardResult(this.violations);

  Set<HeavyRule> get rules => {for (final v in violations) v.rule};

  List<HeavyViolation> of(HeavyRule rule) =>
      [for (final v in violations) if (v.rule == rule) v];

  Set<String> symbolsOf(HeavyRule rule) => {for (final v in of(rule)) v.symbol};

  Set<String> elementsOf(HeavyRule rule) =>
      {for (final v in of(rule)) v.element};
}

/// How the guard recognises an approved dispatcher: the resolved element's
/// library URI starts with [libraryPrefix] and its name (or `Class.name`) is
/// [name].
class DispatcherRef {
  final String libraryPrefix;
  final String name;
  final Dispatcher kind;
  const DispatcherRef(this.libraryPrefix, this.name, this.kind);
}

/// An explicit, reasoned exemption from the heavy-origin rule: [element]
/// (e.g. `resetCardioObservations`, `SleepUserProfile.fromJson`) may be used
/// inside [symbol] (e.g. `WorkerInit.ensure`). Factories and getters-as-compute
/// are exempt ONLY through this list.
class OriginAllow {
  final String symbol;
  final String element;
  final String reason;
  const OriginAllow(this.symbol, this.element, this.reason);
}

/// A reasoned exemption for an analytics API that is bounded scalar math
/// (a "light" API), by element label (`Calories.activeGateHr`, `needBaselineNote`).
class LightApi {
  final String element;
  final String reason;
  const LightApi(this.element, this.reason);
}

class HeavyGuardConfig {
  /// Absolute path of the package under analysis (has `.dart_tool/package_config.json`).
  final String packageRoot;
  final String packageName;

  /// Library URI prefixes whose functions/methods are heavy compute or codec
  /// APIs. Constructors and constant reads from them are exempt (rev 1).
  final List<String> heavyOriginPrefixes;
  final List<DispatcherRef> approvedDispatchers;

  /// Simple type names that must never appear in a dispatcher capture or be
  /// used inside an `@heavy` body.
  final Set<String> bannedPlatformTypes;

  /// The class whose methods are raw-row readers, and the raw table names.
  final String rawReaderClass;
  final Set<String> rawTables;

  final List<OriginAllow> originAllow;

  /// Explicit migration-step exemptions from the raw-reader registry.
  final List<MigrationMethod> migrationMethods;

  /// `…Heavy`-named symbols that are NOT heavy compute (rule (b) exemptions),
  /// each with a reason. Generated files (`l10n/app_localizations*`) are
  /// skipped entirely by [skipFilePrefixes].
  final List<OriginAllow> nameAllow;
  final List<String> skipFilePrefixes;

  /// Types whose List / typed-data sample fields are STORED DATA: iterating them
  /// outside `@heavy` is a `heavyOriginOutsideHeavy` finding.
  final Set<String> storedDataTypes;

  /// Files (relative to lib/) where iterating a `List<Map<…>>` of day records is
  /// stored-data iteration (cross-day arrays).
  final List<String> storedDataFiles;

  /// Analytics APIs that are bounded scalar math: exempt from the origin rule.
  final List<LightApi> lightApi;

  // DESIGN NOTE (step 1, Sol r1 P2): worker-local constructors such as
  // `File(path)` inside a dispatcher closure are deliberately NOT exempted. The
  // closed sendable grammar has no File type, and the clean fix is an entry that
  // takes the PATHS (Strings) and builds its Files inside the worker, which
  // changes the entry signatures (production). Until then the four `File(...)`
  // closure findings (backup encrypt/decrypt call sites) stay in the baseline,
  // where they can only shrink.

  /// When set, all packages under this directory share one analysis collection
  /// (fixture worlds: dozens of tiny packages, one SDK load).
  final String? contextGroup;

  const HeavyGuardConfig({
    required this.packageRoot,
    required this.packageName,
    required this.heavyOriginPrefixes,
    required this.approvedDispatchers,
    required this.bannedPlatformTypes,
    required this.rawReaderClass,
    required this.rawTables,
    this.originAllow = const [],
    this.migrationMethods = const [],
    this.nameAllow = const [],
    this.skipFilePrefixes = const [],
    this.storedDataTypes = const {},
    this.storedDataFiles = const [],
    this.lightApi = const [],
    this.contextGroup,
  });

  static const _banned = {
    'MethodChannel',
    'EventChannel',
    'BasicMessageChannel',
    'LocalDb',
    'Database',
    'BleEngine',
    'SharedPreferences',
    'HeadlessSyncGate',
    'NotificationService',
    'NotificationCenter',
    'BuildContext',
    'StreamSubscription',
  };

  static const _tables = {
    'decoded_onehz',
    'decoded_rr',
    'raw_records',
    'raw_archive',
  };

  static const _lightApi = [
    LightApi('Calories.activeGateHr', 'O(1) scalar math on two numbers'),
    LightApi('Calories.activeKcalPerS', 'O(1) scalar math on a few numbers'),
    LightApi('Calories.restingKcalPerS', 'O(1) scalar math on a few numbers'),
    LightApi('Calories.resolveCoeffs', 'picks a constant coefficient set by sex'),
    LightApi('HeartRateZoneSet.zoneNumber', 'bounded lookup in a 5-zone table'),
    LightApi('HeartRateZones.zonesFromMaxHr', 'builds a fixed 5-zone table'),
    LightApi('HeartRateZones.reserveZones', 'builds a fixed 5-zone table'),
    LightApi('unknownFamilyNote', 'formats one string'),
    LightApi('needBaselineNote', 'formats one string'),
    LightApi('StrainScorer.banisterY', 'O(1) scalar math'),
  ];

  /// The real `lib/` of this repo.
  factory HeavyGuardConfig.edge(String repoRoot) => HeavyGuardConfig(
        packageRoot: repoRoot,
        packageName: 'openstrap_edge',
        heavyOriginPrefixes: const [
          'package:openstrap_analytics/',
          'package:openstrap_edge/data/series_codec.dart',
        ],
        approvedDispatchers: const [
          DispatcherRef('dart:isolate', 'Isolate.run', Dispatcher.run),
          DispatcherRef('dart:isolate', 'Isolate.spawn', Dispatcher.spawn),
          DispatcherRef('package:flutter/', 'compute', Dispatcher.compute),
          DispatcherRef('package:openstrap_edge/compute/derivation_engine.dart',
              'DerivationEngine._runIsolateCancellable', Dispatcher.cancellable),
        ],
        bannedPlatformTypes: _banned,
        rawReaderClass: 'LocalDb',
        rawTables: _tables,
        migrationMethods: kMigrationMethods,
        originAllow: const [
          OriginAllow(
            'WorkerInit.ensure',
            'resetCardioObservations',
            'ensure only re-arms the analytics ambient globals from plain '
                'inputs; clearing the observation buffer is O(1)',
          ),
          OriginAllow(
            'WorkerInit.ensure',
            'SleepUserProfile.fromJson',
            'parses the one profile JSON object handed in as a plain input',
          ),
        ],
        nameAllow: const [
          OriginAllow(
            'DeriveScheduler.pendingHeavy',
            'pendingHeavy',
            'scheduler flag for the user-facing "heavy derive pass" tier; it '
                'queues work, it does not compute (unrelated to @heavy)',
          ),
          OriginAllow(
            'DeriveScheduler.requestHeavy',
            'requestHeavy',
            'asks the scheduler for a heavy derive pass; it enqueues, it does '
                'not compute (unrelated to @heavy)',
          ),
          OriginAllow(
            'deriveDayBundle',
            'deriveDayBundle',
            'registered legacy worker entry: the public name is used by tests, '
                'other libraries or source-text wiring tests; renaming is '
                'production churn',
          ),
          OriginAllow(
            'buildCrossDayBundle',
            'buildCrossDayBundle',
            'registered legacy worker entry: the public name is used by tests, '
                'other libraries or source-text wiring tests; renaming is '
                'production churn',
          ),
          OriginAllow(
            'foldDayCheckpoint',
            'foldDayCheckpoint',
            'registered legacy worker entry: the public name is used by tests, '
                'other libraries or source-text wiring tests; renaming is '
                'production churn',
          ),
          OriginAllow(
            'derivationPrepareWorker',
            'derivationPrepareWorker',
            'registered legacy worker entry: the public name is used by tests, '
                'other libraries or source-text wiring tests; renaming is '
                'production churn',
          ),
          OriginAllow(
            'DerivationEngine._dayBlocksIsolateEntry',
            '_dayBlocksIsolateEntry',
            'registered legacy worker entry: the public name is used by tests, '
                'other libraries or source-text wiring tests; renaming is '
                'production churn',
          ),
          OriginAllow(
            'DerivationEngine._computeDayBlocks',
            '_computeDayBlocks',
            'registered legacy worker entry: the public name is used by tests, '
                'other libraries or source-text wiring tests; renaming is '
                'production churn',
          ),
          OriginAllow(
            'observeNaturalSync',
            'observeNaturalSync',
            'registered legacy worker entry: the public name is used by tests, '
                'other libraries or source-text wiring tests; renaming is '
                'production churn',
          ),
          OriginAllow(
            'encryptBackupFile',
            'encryptBackupFile',
            'registered legacy worker entry: the public name is used by tests, '
                'other libraries or source-text wiring tests; renaming is '
                'production churn',
          ),
          OriginAllow(
            'decryptBackupFile',
            'decryptBackupFile',
            'registered legacy worker entry: the public name is used by tests, '
                'other libraries or source-text wiring tests; renaming is '
                'production churn',
          ),
        ],
        skipFilePrefixes: const ['l10n/app_localizations'],
        storedDataTypes: const {
          'Substrate',
          'DayBundleInput',
          'PreparedDerivationDay',
          'PreparedDerivationPayload',
        },
        storedDataFiles: const [
          'compute/crossday_pipeline.dart',
          'compute/crossday_input.dart',
        ],
        lightApi: _lightApi,
      );

  /// A synthetic fixture package materialised by `FixtureWorld`.
  factory HeavyGuardConfig.fixture(String fixtureRoot) => HeavyGuardConfig(
        packageRoot: fixtureRoot,
        packageName: 'fixture_app',
        heavyOriginPrefixes: const [
          'package:openstrap_analytics/',
          'package:fixture_app/series_codec.dart',
        ],
        approvedDispatchers: const [
          DispatcherRef('dart:isolate', 'Isolate.run', Dispatcher.run),
          DispatcherRef('dart:isolate', 'Isolate.spawn', Dispatcher.spawn),
          DispatcherRef('package:fixture_dispatch/', 'compute', Dispatcher.compute),
          DispatcherRef('package:fixture_dispatch/', 'runCancellable',
              Dispatcher.cancellable),
        ],
        bannedPlatformTypes: _banned,
        rawReaderClass: 'LocalDb',
        rawTables: _tables,
        migrationMethods: const [
          MigrationMethod('LocalDb.upgradeRows', 'fixture: a migration step'),
        ],
        originAllow: const [
          OriginAllow('Arm.arm', 'resetCardioObservations', 'fixture allow-list'),
        ],
        nameAllow: const [
          OriginAllow('legacyDerive', 'legacyDerive', 'fixture: widely used name'),
        ],
        storedDataTypes: const {'Substrate'},
        storedDataFiles: const ['crossday.dart'],
        lightApi: const [LightApi('Calories.activeGateHr', 'fixture: scalar math')],
        contextGroup: Directory(fixtureRoot).parent.path,
      );
}

/// Resolves every library under `<packageRoot>/lib` with package:analyzer and
/// returns all findings (before the baseline is applied). The engine lives in
/// heavy_guard_engine.dart; see [HeavyRule] for the rules.
Future<HeavyGuardResult> analyzeHeavyGuard(HeavyGuardConfig config) =>
    engine.analyze(config);

/// Releases the shared analysis collections (call from `tearDownAll`).
Future<void> disposeHeavyGuardCaches() => engine.disposeCaches();
