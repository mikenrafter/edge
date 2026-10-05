// 8AJ seam 1: every AppState member that moved into the DeriveCoordinator is
// still there and forwards, with the same notify semantics. The type
// annotations below are compile-time checks of the public surface.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/compute/derive_outcome.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/artifact_warmer.dart';
import 'package:openstrap_edge/state/recalc_state.dart';

import 'support/app_state_derive_harness.dart';

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
}
