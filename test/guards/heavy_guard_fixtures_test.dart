// heavy_guard_fixtures_test.dart — the guard's own contract (design 02).
//
// Each rule has at least one failing and one passing synthetic package under
// test/guards/fixtures/<case>/ (sources are `.dart.fixture`, see
// support/fixture_world.dart). The SAME engine that guards lib/ analyses them,
// so these tests are where the rules are specified; heavy_calc_guard_test.dart
// only applies the engine to the real tree.
//
// The "environment" and "table hygiene" groups need no engine; the table below
// runs the engine on every fixture and pins the exact findings.

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_sdk.dart';
import 'support/fixture_world.dart';
import 'support/heavy_guard.dart';

/// What a fixture must produce.
class Expect {
  /// Exact set of rules that fire (empty = the fixture is clean).
  final Set<HeavyRule> rules;

  /// Per-rule enclosing symbols, when the case pins them.
  final Map<HeavyRule, Set<String>> symbols;

  /// Per-rule resolved elements, when the case pins them.
  final Map<HeavyRule, Set<String>> elements;

  /// Per-rule instance counts, when the case pins them.
  final Map<HeavyRule, int> counts;

  /// If true, [rules] only has to be a subset of what fired (cases where the
  /// design leaves collateral findings open, noted at the case).
  final bool subset;

  const Expect(
    this.rules, {
    this.symbols = const {},
    this.elements = const {},
    this.counts = const {},
    this.subset = false,
  });

  const Expect.clean() : this(const {});
}

final Map<String, Expect> kExpectations = {
  // ---- (a) origin, not names -------------------------------------------
  'a_bad_analytics_in_widget_build': const Expect(
    {HeavyRule.heavyOriginOutsideHeavy},
    symbols: {HeavyRule.heavyOriginOutsideHeavy: {'FakeWidget.build'}},
    elements: {HeavyRule.heavyOriginOutsideHeavy: {'readinessCompute'}},
  ),
  'a_ok_heavy_reached_via_run': const Expect.clean(),
  'a_bad_aliased_import_origin': const Expect(
    {HeavyRule.heavyOriginOutsideHeavy},
    elements: {HeavyRule.heavyOriginOutsideHeavy: {'readinessCompute'}},
  ),
  'a_ok_same_name_different_origin': const Expect.clean(),
  'a_bad_rowbatch_iteration': const Expect(
    {HeavyRule.rowBatchIterationOutsideHeavy},
    symbols: {
      HeavyRule.rowBatchIterationOutsideHeavy: {'Screen.mean', 'Screen.hrs'},
    },
    counts: {HeavyRule.rowBatchIterationOutsideHeavy: 2},
  ),
  'a_ok_rowbatch_iteration_in_heavy': const Expect.clean(),
  'a_bad_codec_outside_heavy': const Expect(
    {HeavyRule.heavyOriginOutsideHeavy},
    elements: {HeavyRule.heavyOriginOutsideHeavy: {'decodeSeries'}},
  ),
  'a_ok_value_reads_exempt': const Expect.clean(),
  // Factories compute; only an explicit allow-list entry exempts them.
  'a_bad_factory_constructor_outside_heavy': const Expect(
    {HeavyRule.heavyOriginOutsideHeavy},
    elements: {HeavyRule.heavyOriginOutsideHeavy: {'Metric.fromSamples'}},
  ),
  'a_ok_allow_listed_origin': const Expect.clean(),
  // Bounded scalar analytics helpers (config lightApi) need no @heavy.
  'a_ok_light_api_allow_list': const Expect.clean(),
  // Stored-data collections: Substrate-like types' sample lists, and cross-day
  // day-record arrays in the configured files.
  'a_bad_stored_data_iteration': const Expect(
    {HeavyRule.heavyOriginOutsideHeavy},
    symbols: {
      HeavyRule.heavyOriginOutsideHeavy: {'Screen.sum', 'Screen.mean', 'Screen.count'},
    },
    elements: {
      HeavyRule.heavyOriginOutsideHeavy: {'Substrate.tsSec', 'Substrate.rrMs'},
    },
    counts: {HeavyRule.heavyOriginOutsideHeavy: 3},
  ),
  'a_ok_stored_data_in_heavy': const Expect.clean(),
  'a_bad_crossday_records_iteration': const Expect(
    {HeavyRule.heavyOriginOutsideHeavy},
    symbols: {HeavyRule.heavyOriginOutsideHeavy: {'meanOf'}},
    counts: {HeavyRule.heavyOriginOutsideHeavy: 1},
  ),
  'a_ok_heavy_calls_inner_heavy': const Expect.clean(),

  // ---- (b) @heavy <=> ...Heavy -----------------------------------------
  'b_bad_marker_without_suffix': const Expect(
    {HeavyRule.nameMarkerMismatch},
    symbols: {HeavyRule.nameMarkerMismatch: {'derive'}},
  ),
  'b_bad_suffix_without_marker': const Expect(
    {HeavyRule.nameMarkerMismatch},
    symbols: {HeavyRule.nameMarkerMismatch: {'deriveHeavy'}},
  ),
  'b_ok_static_method_entry': const Expect.clean(),

  // ---- (c) where heavy functions may be called -------------------------
  'c_bad_direct_call': const Expect(
    {HeavyRule.heavyCallOutsideApprovedContext},
    symbols: {HeavyRule.heavyCallOutsideApprovedContext: {'Repo.now'}},
  ),
  'c_bad_tearoff_escapes': const Expect(
    {HeavyRule.heavyReferenceEscapes},
    symbols: {
      HeavyRule.heavyReferenceEscapes: {'Holder.fn', 'pick', 'wire'},
    },
    counts: {HeavyRule.heavyReferenceEscapes: 3},
  ),
  'c_ok_compute_tearoff': const Expect.clean(),
  'c_bad_unapproved_dispatchers': const Expect(
    {HeavyRule.heavyCallOutsideApprovedContext},
    symbols: {
      HeavyRule.heavyCallOutsideApprovedContext: {
        'Later.later',
        'Later.micro',
        'Later.timer',
      },
    },
  ),
  // A call to an unregistered heavy function counts as the closure's ONE entry
  // call; whether it is registered is a separate finding (rootNotRegistered).
  'c_bad_root_unregistered': const Expect(
    {HeavyRule.rootNotRegistered},
    elements: {HeavyRule.rootNotRegistered: {'orphanHeavy'}},
  ),
  'c_bad_root_unreferenced': const Expect(
    {HeavyRule.rootNotRegistered},
    elements: {HeavyRule.rootNotRegistered: {'lonelyHeavy'}},
  ),
  'c_bad_inner_also_dispatched': const Expect(
    {HeavyRule.rootNotRegistered},
    elements: {HeavyRule.rootNotRegistered: {'innerHeavy'}},
  ),
  'c_ok_closure_setup_and_wrap': const Expect.clean(),
  'c_bad_closure_two_entries': const Expect(
    {HeavyRule.dispatcherClosureContract},
    symbols: {HeavyRule.dispatcherClosureContract: {'Both.go'}},
  ),
  // The legacy reader pattern: analytics straight in the dispatcher closure.
  // Both the origin rule and the closure contract fire; both are baselineable.
  'c_bad_closure_inline_analytics': const Expect(
    {HeavyRule.heavyOriginOutsideHeavy, HeavyRule.dispatcherClosureContract},
    symbols: {
      HeavyRule.heavyOriginOutsideHeavy: {'Reader.weekday'},
      HeavyRule.dispatcherClosureContract: {'Reader.weekday'},
    },
  ),
  'c_bad_closure_plain_helper': const Expect(
    {HeavyRule.dispatcherClosureContract},
    symbols: {HeavyRule.dispatcherClosureContract: {'Reader.go'}},
  ),

  // ---- worker contract: static, and initialised before anything else -------
  'entry_bad_no_init': const Expect(
    {HeavyRule.workerEntryNotInitialised},
    symbols: {HeavyRule.workerEntryNotInitialised: {'deriveHeavy'}},
  ),
  'entry_bad_init_not_first': const Expect(
    {HeavyRule.workerEntryNotInitialised},
    symbols: {HeavyRule.workerEntryNotInitialised: {'deriveHeavy'}},
  ),
  'entry_bad_expression_body': const Expect(
    {HeavyRule.workerEntryNotInitialised},
    symbols: {HeavyRule.workerEntryNotInitialised: {'deriveHeavy'}},
  ),
  'entry_ok_ensure_first': const Expect.clean(),
  'entry_bad_instance_method': const Expect(
    {HeavyRule.workerEntryNotStatic},
    symbols: {HeavyRule.workerEntryNotStatic: {'Worker.runHeavy'}},
  ),
  // A reasoned naming exception (config nameAllow) instead of renaming.
  'b_ok_heavy_name_exception': const Expect.clean(),

  // ---- registry ----------------------------------------------------------
  'registry_bad_symbol_unresolved': const Expect(
    {HeavyRule.registryEntryUnresolved},
    elements: {HeavyRule.registryEntryUnresolved: {'missingHeavy'}},
  ),
  // Two top-level `deriveHeavy` in different libraries; a Symbol literal has no
  // library. Other collateral findings (the second copy is an unregistered
  // root) are left to the engine.
  'registry_bad_ambiguous': const Expect(
    {HeavyRule.registryEntryAmbiguous},
    subset: true,
  ),
  'registry_bad_duplicate': const Expect(
    {HeavyRule.registryEntryDuplicate},
    elements: {HeavyRule.registryEntryDuplicate: {'deriveHeavy'}},
  ),
  'registry_bad_not_heavy': const Expect(
    {HeavyRule.registryEntryNotHeavy},
    elements: {HeavyRule.registryEntryNotHeavy: {'plainWorker'}},
  ),
  'registry_bad_dispatcher_mismatch': const Expect(
    {HeavyRule.registryDispatcherMismatch},
    elements: {HeavyRule.registryDispatcherMismatch: {'deriveHeavy'}},
  ),
  'registry_bad_never_dispatched': const Expect(
    {HeavyRule.registryEntryNeverDispatched},
    elements: {HeavyRule.registryEntryNeverDispatched: {'deriveHeavy'}},
  ),
  'registry_ok_entry_called_by_heavy': const Expect.clean(),
  'registry_ok_cancellable': const Expect.clean(),
  'registry_ok_spawn': const Expect.clean(),

  // ---- captures ----------------------------------------------------------
  'capture_bad_this': const Expect(
    {HeavyRule.captureNotSendable},
    elements: {HeavyRule.captureNotSendable: {'this'}},
  ),
  'capture_bad_this_cancellable': const Expect(
    {HeavyRule.captureNotSendable},
    elements: {HeavyRule.captureNotSendable: {'this'}},
  ),
  'capture_bad_banned_types': const Expect(
    {HeavyRule.captureNotSendable},
    elements: {
      HeavyRule.captureNotSendable: {'ctx', 'sub', 'db', 'ch'},
    },
    counts: {HeavyRule.captureNotSendable: 4},
  ),
  'capture_ok_sendables': const Expect.clean(),
  'capture_bad_unsendable_class': const Expect(
    {HeavyRule.captureNotSendable},
    elements: {HeavyRule.captureNotSendable: {'p'}},
  ),

  // ---- sendable grammar --------------------------------------------------
  'sendable_bad_sendable_class_field': const Expect(
    {HeavyRule.sendableGrammar},
    symbols: {HeavyRule.sendableGrammar: {'leakyHeavy'}},
  ),
  'sendable_bad_nested_shapes': const Expect(
    {HeavyRule.sendableGrammar},
    symbols: {
      HeavyRule.sendableGrammar: {
        'mapHeavy',
        'listHeavy',
        'recordHeavy',
        'objectResultHeavy',
        'deepHeavy',
      },
    },
    counts: {HeavyRule.sendableGrammar: 5},
  ),
  'sendable_ok_shape_with_roundtrip_test': const Expect.clean(),
  // Nullable map keys are outside Map<String, S>.
  'sendable_bad_nullable_map_key': const Expect(
    {HeavyRule.sendableGrammar},
    symbols: {HeavyRule.sendableGrammar: {'keyHeavy'}},
  ),
  'sendable_ok_rowbatch_arg': const Expect.clean(),
  'sendable_bad_shape_without_test': const Expect(
    {HeavyRule.sendableShapeTestMissing},
    symbols: {HeavyRule.sendableShapeTestMissing: {'payloadHeavy'}},
  ),

  // ---- fail closed -------------------------------------------------------
  'unresolved_bad_dynamic_call': const Expect(
    {HeavyRule.unresolvedInvocation},
    symbols: {HeavyRule.unresolvedInvocation: {'probe'}},
    elements: {HeavyRule.unresolvedInvocation: {'x.compute()'}},
  ),
  'unresolved_bad_function_value': const Expect(
    {HeavyRule.unresolvedInvocation},
    symbols: {HeavyRule.unresolvedInvocation: {'run'}},
    elements: {HeavyRule.unresolvedInvocation: {'cb()'}},
  ),
  'unresolved_ok_fingerprinted': const Expect.clean(),
  'unresolved_bad_second_in_same_symbol': const Expect(
    {HeavyRule.unresolvedInvocation},
    elements: {HeavyRule.unresolvedInvocation: {'x.again()'}},
    counts: {HeavyRule.unresolvedInvocation: 1},
  ),
  // The fingerprint text is whitespace-normalised (runs collapse to one space).
  'unresolved_ok_whitespace_normalised': const Expect.clean(),
  'unresolved_bad_stale_fingerprint': const Expect(
    {HeavyRule.unresolvedOkStale},
  ),
  'unresolved_bad_wrong_ordinal': const Expect(
    {HeavyRule.unresolvedInvocation, HeavyRule.unresolvedOkStale},
  ),
  'unresolved_ok_inside_heavy': const Expect.clean(),

  // ---- overrides ---------------------------------------------------------
  'override_bad_base_call_outside_heavy': const Expect(
    {HeavyRule.heavyCallOutsideApprovedContext},
    symbols: {HeavyRule.heavyCallOutsideApprovedContext: {'Screen.now'}},
  ),
  'override_ok_base_call_inside_heavy': const Expect.clean(),

  // ---- platform ban ------------------------------------------------------
  'platform_bad_in_heavy': const Expect(
    {HeavyRule.platformInHeavy},
    symbols: {
      HeavyRule.platformInHeavy: {
        'methodChannelHeavy',
        'eventChannelHeavy',
        'localDbHeavy',
        'prefsHeavy',
        'gateHeavy',
        'notifyHeavy',
      },
    },
    counts: {HeavyRule.platformInHeavy: 6},
  ),

  // ---- @live ---------------------------------------------------------------
  // The specific @live finding replaces the generic one for the same call.
  'live_bad_calls_heavy': const Expect(
    {HeavyRule.liveCallsHeavy},
    symbols: {HeavyRule.liveCallsHeavy: {'tick'}},
  ),
  'live_bad_no_budget_test': const Expect(
    {HeavyRule.liveBudgetTestMissing},
    symbols: {HeavyRule.liveBudgetTestMissing: {'cheapTick'}},
  ),
  'live_bad_unbounded_loops': const Expect(
    {HeavyRule.liveUnboundedLoop},
    symbols: {
      HeavyRule.liveUnboundedLoop: {'sumFor', 'whileLoop', 'countFor'},
    },
    counts: {HeavyRule.liveUnboundedLoop: 3},
  ),
  'live_ok_bounded': const Expect.clean(),
  'live_and_heavy_conflict': const Expect(
    {HeavyRule.liveAndHeavy},
    symbols: {HeavyRule.liveAndHeavy: {'bothHeavy'}},
  ),

  // ---- raw-row readers ---------------------------------------------------
  'rawreader_bad_unregistered': const Expect(
    {HeavyRule.rawReaderUnregistered},
    symbols: {HeavyRule.rawReaderUnregistered: {'LocalDb.getOnehz'}},
  ),
  'rawreader_ok_registered': const Expect.clean(),
  'rawreader_bad_wrong_return_type': const Expect(
    {HeavyRule.rawReaderWrongReturnType},
    symbols: {HeavyRule.rawReaderWrongReturnType: {'LocalDb.getOnehz'}},
  ),
  'rawreader_bad_const_table_name': const Expect(
    {HeavyRule.rawReaderUnregistered},
    symbols: {HeavyRule.rawReaderUnregistered: {'LocalDb.beats'}},
  ),
  'rawreader_bad_wrapper_of_registered': const Expect(
    {HeavyRule.rawReaderUnregistered},
    symbols: {HeavyRule.rawReaderUnregistered: {'LocalDb.latest'}},
  ),
  'rawreader_ok_unrelated_method': const Expect.clean(),
  // Migrations / scalar accessors are not raw-row readers: only methods whose
  // return type exposes rows count, and backfill/repair/ensure/migrate names
  // are exempt by name.
  'rawreader_ok_void_backfill_and_scalars': const Expect.clean(),
  'rawreader_bad_exposes_rows_variants': const Expect(
    {HeavyRule.rawReaderUnregistered},
    symbols: {
      HeavyRule.rawReaderUnregistered: {
        'LocalDb.beats',
        'LocalDb.firstRow',
        'LocalDb.stream',
      },
    },
    counts: {HeavyRule.rawReaderUnregistered: 3},
  ),
};

void main() {
  // Each fixture resolves a small package; the first one loads the SDK.
  const slow = Timeout(Duration(minutes: 5));
  late FixtureWorld world;

  setUpAll(() async {
    world = await FixtureWorld.materialize();
  });

  tearDownAll(() async {
    await disposeHeavyGuardCaches();
    await world.dispose();
  });

  // ------------------------------------------------------------------------
  // These need no engine: they pin the harness and the analyzer environment so
  // a GREEN failure is about the engine, not about SDK discovery or fixture rot.
  group('fixture hygiene (no engine)', () {
    test('every fixture case has an expectation and vice versa', () {
      expect(kExpectations.keys.toSet(), world.cases.toSet());
    });

    test('every guard rule is exercised by at least one failing fixture', () {
      final fired = {
        for (final e in kExpectations.values) ...e.rules,
      };
      expect(
        HeavyRule.values.toSet().difference(fired),
        isEmpty,
        reason: 'a rule with no failing fixture is a rule nobody specified',
      );
    });

    test('every rule that matters has a passing fixture next to it', () {
      expect(
        kExpectations.values.where((e) => e.rules.isEmpty).length,
        greaterThanOrEqualTo(15),
      );
    });

    test('clean fixtures never pin findings; bad fixtures name their rules', () {
      for (final e in kExpectations.entries) {
        final isOk = e.key.contains('_ok_');
        expect(e.value.rules.isEmpty, isOk, reason: e.key);
      }
    });

    test('materialised packages carry a package_config and plain .dart files', () {
      for (final c in world.cases) {
        final dir = Directory(world.casePath(c));
        expect(File('${dir.path}/.dart_tool/package_config.json').existsSync(),
            isTrue,
            reason: c);
        expect(File('${dir.path}/lib/main.dart').existsSync(), isTrue, reason: c);
        final leftovers = dir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.fixture'));
        expect(leftovers, isEmpty, reason: c);
      }
    });
  });

  group('analyzer environment (no engine)', () {
    // Resolves one fixture with package:analyzer exactly as the engine will:
    // proves the SDK is found under `flutter test`, that dart:isolate, the
    // stub analytics package and the REAL util/heavy.dart markers resolve, and
    // that `Isolate.run` is identifiable by library + name.
    test('resolves dart:isolate, openstrap_analytics and the @heavy marker', () async {
      final path = '${world.casePath('a_ok_heavy_reached_via_run')}/lib/main.dart';
      final collection = AnalysisContextCollection(
        includedPaths: [world.casePath('a_ok_heavy_reached_via_run')],
        sdkPath: dartSdkPath(),
      );
      addTearDown(collection.dispose);
      final result = await collection
          .contextFor(path)
          .currentSession
          .getResolvedLibrary(path);
      expect(result, isA<ResolvedLibraryResult>());
      final unit = (result as ResolvedLibraryResult).units.first.unit;
      final seen = _Seen();
      unit.accept(seen);

      expect(seen.invocations['run'], 'dart:isolate');
      expect(seen.invocations['readinessCompute'],
          startsWith('package:openstrap_analytics/'));
      expect(seen.annotations['deriveDayHeavy'],
          contains('package:openstrap_edge/util/heavy.dart'));
      expect(seen.unresolved, isEmpty,
          reason: 'the fixture must resolve completely');
    });
  });

  // ------------------------------------------------------------------------
  group('guard rules over synthetic packages', () {
    for (final entry in kExpectations.entries) {
      test(entry.key, timeout: slow, () async {
        final r = await world.analyze(entry.key);
        final want = entry.value;
        final dump = r.violations.join('\n');

        if (want.subset) {
          expect(r.rules, containsAll(want.rules), reason: dump);
        } else {
          expect(r.rules, want.rules, reason: dump);
        }
        for (final e in want.symbols.entries) {
          expect(r.symbolsOf(e.key), e.value,
              reason: '${e.key.name} symbols\n$dump');
        }
        for (final e in want.elements.entries) {
          expect(r.elementsOf(e.key), e.value,
              reason: '${e.key.name} elements\n$dump');
        }
        for (final e in want.counts.entries) {
          expect(r.of(e.key).length, e.value,
              reason: '${e.key.name} count\n$dump');
        }
      });
    }
  });

  group('guard behaviour across edits', () {
    test('findings carry no line numbers: shifting the source changes nothing',
        timeout: slow, () async {
      const c = 'c_bad_closure_inline_analytics';
      final before = (await world.analyze(c)).violations.map((v) => '$v').toList()
        ..sort();
      expect(before, isNotEmpty);

      final src = world.read(c, 'lib/main.dart');
      world.write(c, 'lib/main.dart', '${'\n// padding\n' * 40}$src');
      final after = (await world.analyze(c)).violations.map((v) => '$v').toList()
        ..sort();
      expect(after, before);
    });

    test('closures count as the enclosing function: no separate symbol',
        timeout: slow, () async {
      final r = await world.analyze('c_bad_closure_inline_analytics');
      for (final v in r.violations) {
        expect(v.symbol, isNot(contains('closure')), reason: '$v');
        expect(v.symbol, isNot(contains('<anonymous')), reason: '$v');
      }
    });
  });
}

/// Collects (invoked name -> library uri), (annotated function -> annotation
/// libraries) and unresolved invocation targets from one resolved unit.
class _Seen extends RecursiveAstVisitor<void> {
  final Map<String, String> invocations = {};
  final Map<String, String> annotations = {};
  final List<String> unresolved = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final el = node.methodName.element;
    final uri = el?.library?.uri.toString();
    if (uri == null) {
      unresolved.add(node.toSource());
    } else {
      invocations[node.methodName.name] = uri;
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final libs = <String>[];
    for (final a in node.metadata) {
      final u = a.elementAnnotation?.element?.library?.uri.toString();
      if (u != null) libs.add(u);
    }
    annotations[node.name.lexeme] = libs.join(',');
    super.visitFunctionDeclaration(node);
  }
}
