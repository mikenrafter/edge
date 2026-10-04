// 8AJ seam 1: every AppState member that moved into the DeriveCoordinator is
// still there and forwards, with the same notify semantics. The type
// annotations below are compile-time checks of the public surface; the source
// guard pins that the logic lives in the coordinator and AppState only
// delegates.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/compute/derive_outcome.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/artifact_warmer.dart';
import 'package:openstrap_edge/state/recalc_state.dart';

import 'support/derive_harness.dart';

const _db = 'openstrap_split8aj_derive_delegation.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('public surface (compile-time)', () {
    test('every moved member is present with its original type', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final ValueNotifier<int> rev = app.insightsRevision;
      final ValueListenable<RecalcState> recalc = app.recalc;
      final int? ms = app.lastHomeRenderMs;
      app.lastHomeRenderMs = 12;
      app.recordHomeRender(13);
      final Map<String, Object?>? perf = app.lastPassPerf;
      final DeriveRunHook? hook = app.debugDeriveRun;
      app.debugDeriveRun = hook;
      final RescanHook? rescan = app.debugRescanRecent;
      app.debugRescanRecent = rescan;
      final ArtifactSource? source = app.debugArtifactSource;
      app.debugArtifactSource = source;
      final Future<DeriveOutcome> Function({required DeriveJobKind kind})
          scheduled = app.debugRunScheduled;
      final void Function(RecalcState) setRecalc = app.debugSetRecalc;
      final Future<void> Function({bool heavy, bool changedOnly}) afterDrain =
          app.debugAfterDrain;
      final void Function() bump = app.bumpInsights;
      final bool deriving = app.deriving;
      final bool pending = app.derivePending;
      expect([rev, recalc, ms, perf, scheduled, setRecalc, afterDrain, bump,
        deriving, pending], isNotEmpty);
    });
  });

  group('forwarding', () {
    test('insightsRevision and recalc are the coordinator\'s notifiers, the '
        'same objects on every read', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect(identical(app.insightsRevision, app.insightsRevision), isTrue);
      expect(identical(app.recalc, app.recalc), isTrue);
      app.bumpInsights();
      expect(app.insightsRevision.value, 1);
    });

    test('bumpInsights, recordHomeRender and debugSetRecalc never tick '
        'AppState', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final ticks = TickCounter(app);
      app.bumpInsights();
      app.recordHomeRender(5);
      app.debugSetRecalc(RecalcState(days: {'d'}, passStartedAt: DateTime(2026)));
      expect(ticks.ticks, 0);
      expect(app.lastHomeRenderMs, 5);
    });

    test('the lastHomeRenderMs setter writes through', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.lastHomeRenderMs = 77;
      expect(app.lastHomeRenderMs, 77);
    });

    test('the debug fields read back what was set', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final hook = deriveHook(days: ['d1']);
      app.debugDeriveRun = hook;
      expect(identical(app.debugDeriveRun, hook), isTrue);
      Future<int> rescan({onScopeDays, onDayDone}) async => 0;
      app.debugRescanRecent = rescan;
      expect(identical(app.debugRescanRecent, rescan), isTrue);
      app.debugDeriveRun = null;
      expect(app.debugDeriveRun, isNull);
    });
  });

  group('source guard', () {
    final app = File('lib/state/app_state.dart').readAsStringSync();
    final coord = File('lib/state/derive_coordinator.dart').readAsStringSync();

    test('AppState delegates each moved member in one expression', () {
      for (final line in const [
        'void bumpInsights() => _deriveCoordinator.bumpInsights();',
        'void recordHomeRender(int ms) => _deriveCoordinator.recordHomeRender(ms);',
        'ValueListenable<RecalcState> get recalc => _deriveCoordinator.recalc;',
        'Map<String, Object?>? get lastPassPerf => _deriveCoordinator.lastPassPerf;',
        'ValueNotifier<int> get insightsRevision => _deriveCoordinator.insightsRevision;',
        'DeriveScheduler get _deriveScheduler => _deriveCoordinator.scheduler;',
        '_deriveCoordinator.dispose();',
      ]) {
        expect(app, contains(line), reason: 'missing delegate: $line');
      }
      // The manual sync hands its derive to the coordinator; it moved to the
      // sync controller with seam 5.
      final sync = File('lib/state/sync_controller.dart').readAsStringSync();
      expect('$app\n$sync', contains('_deriveCoordinator.afterDrain('));
    });

    test('the derive logic no longer lives in AppState', () {
      for (final gone in const [
        'Future<DeriveOutcome> _afterDrain(',
        'Future<DeriveOutcome> _deriveRun(',
        'Future<int> _rescanRecent(',
        'Future<DeriveOutcome> _runScheduled(',
        'RevisionCoalescer(',
        'ArtifactWarmer(',
        'PeriodicCalculationPolicy(',
        'DeriveScheduler(',
        'int _recalcSeq',
        'ValueNotifier<RecalcState>(',
        "'derive_\$mode'",
      ]) {
        expect(app, isNot(contains(gone)), reason: 'still in AppState: $gone');
      }
    });

    test('the logic is in the coordinator, which has no AppState back '
        'reference', () {
      for (final here in const [
        'Future<DeriveOutcome> afterDrain(',
        'Future<DeriveOutcome> _deriveRun(',
        'Future<int> _rescanRecent(',
        'RevisionCoalescer(',
        'ArtifactWarmer(',
        'DeriveScheduler(',
      ]) {
        expect(coord, contains(here), reason: 'missing: $here');
      }
      expect(coord, isNot(contains('app_state.dart')));
    });
  });
}
