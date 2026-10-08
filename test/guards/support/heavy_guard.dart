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
  sendableGrammar(baselineable: false),

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
  rawReaderWrongReturnType(baselineable: false);

  const HeavyRule({required this.baselineable});

  /// Only code-site findings in legacy code may be absorbed by the baseline.
  /// Structure findings (registry, naming, grammar, @live) never are.
  final bool baselineable;
}

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

  /// `…Heavy`-named symbols that are NOT heavy compute (rule (b) exemptions),
  /// each with a reason. Generated files (`l10n/app_localizations*`) are
  /// skipped entirely by [skipFilePrefixes].
  final List<OriginAllow> nameAllow;
  final List<String> skipFilePrefixes;

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
    this.nameAllow = const [],
    this.skipFilePrefixes = const [],
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
        ],
        skipFilePrefixes: const ['l10n/app_localizations'],
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
        originAllow: const [
          OriginAllow('Arm.arm', 'resetCardioObservations', 'fixture allow-list'),
        ],
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
