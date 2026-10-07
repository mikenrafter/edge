// The real wiring behind the sweep: the off-isolate beat decode, and what
// AppState does with the live streams and live frames for a sweep.
//
// Frames are synthetic 0x28 compact realtime-HR packets, one per beat, the
// same shape the breathing tests feed AppState.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/explore/resonance/resonance_sweep_controller.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/app_state_live_harness.dart';
import 'support/sweep_fixtures.dart';

const _ts0 = 1790000000;

String _frame(int i, int rr) =>
    hexOf(hr28Inner(rr: [rr], ts: _ts0 + i));

/// One frame per second, each carrying one 1000 ms-ish beat, arriving at
/// [startMs] + i * 1000 on the session clock.
List<({int atMs, String hex})> _frames(
  int count, {
  int startMs = 5000,
  int Function(int i)? rr,
}) =>
    [
      for (var i = 0; i < count; i++)
        (atMs: startMs + i * 1000, hex: _frame(i, rr?.call(i) ?? 1000 + (i % 4) * 10)),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  group('sweepBeatsCompute', () {
    test('no frames, or frames with no beats, give no beats', () {
      expect(sweepBeatsCompute(const []), isEmpty);
      expect(
        sweepBeatsCompute([
          (atMs: 0, hex: hexOf(hr28Inner(rr: const [], ts: _ts0))),
        ]),
        isEmpty,
      );
    });

    test('beat times come from the corrected timeline on the session clock',
        () {
      final beats = sweepBeatsCompute(_frames(40, rr: (_) => 1000));
      expect(beats, hasLength(40));
      // The first packet arrived at 5000 ms; its beat ends there, and each
      // later beat ends one interval after the one before.
      expect(beats.first.tMs, 5000);
      for (var i = 1; i < beats.length; i++) {
        expect(beats[i].tMs - beats[i - 1].tMs, 1000);
      }
      expect(beats.every((b) => b.observed), isTrue);
      expect(beats.every((b) => b.rrMs == 1000), isTrue);
    });

    test('a beat the corrector replaced is not observed; the rest are', () {
      final beats = sweepBeatsCompute(
        _frames(60, rr: (i) => i == 30 ? 1700 : 1000 + (i % 4) * 10),
      );
      expect(beats.where((b) => !b.observed), isNotEmpty,
          reason: 'the outlier must not pass as an observed beat');
      expect(beats.where((b) => b.observed).length, greaterThan(50));
      // The replaced beat is not the 1700 ms reading.
      expect(beats.where((b) => !b.observed).every((b) => b.rrMs != 1700),
          isTrue);
    });

    test('the repository method runs the same decode off the UI isolate',
        () async {
      final repo = LocalRepositoryImpl(getProfileMap: () => const {});
      final frames = _frames(40, rr: (_) => 1000);
      final viaRepo = await repo.sweepBeats(frames);
      final direct = sweepBeatsCompute(frames);
      expect(viaRepo.map((b) => (b.tMs, b.rrMs, b.observed)).toList(),
          direct.map((b) => (b.tMs, b.rrMs, b.observed)).toList());
      expect(await repo.sweepBeats(const []), isEmpty);
    });
  });

  group('AppState.buildResonanceSweep', () {
    test('holds the HR owner while running and releases it on stop', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.device.connection = 'connected';
      final c = app.buildResonanceSweep(plan: planFor([6.0]));
      addTearDown(c.dispose);
      expect(app.debugLiveOwners.breathing, isFalse);

      await c.start();
      expect(c.state, SweepState.running);
      expect(app.debugLiveOwners.breathing, isTrue);

      await c.stop();
      expect(c.state, SweepState.stopped);
      expect(app.debugLiveOwners.breathing, isFalse);
    });

    test('leaving mid-run (dispose) releases the owner too', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.device.connection = 'connected';
      final c = app.buildResonanceSweep(plan: planFor([6.0]));
      await c.start();
      expect(app.debugLiveOwners.breathing, isTrue);
      c.dispose();
      expect(app.debugLiveOwners.breathing, isFalse);
    });

    test('without a band the sweep fails and never takes the owner', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final c = app.buildResonanceSweep(plan: planFor([6.0]));
      addTearDown(c.dispose);
      await c.start();
      expect(c.state, SweepState.failed);
      expect(c.error, 'Connect your band first.');
      expect(app.debugLiveOwners.breathing, isFalse);
    });

    test('live frames reach the sweep, are decoded, and score a block',
        () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.device.connection = 'connected';
      app.repo = LocalRepositoryImpl(getProfileMap: () => const {});
      var clock = DateTime.utc(2026, 10, 7, 12);
      final start = clock;
      // One 60 s block, no settle stretch: every frame is in the measure window.
      final c = app.buildResonanceSweep(
        plan: planFor([6.0], settle: Duration.zero, measure: const Duration(seconds: 60)),
        now: () => clock,
      );
      addTearDown(c.dispose);
      await c.start();
      for (var i = 0; i < 59; i++) {
        clock = start.add(Duration(milliseconds: 500 + i * 1000));
        app.debugOnLiveFrame(0x28, _frame(i, 1000), _ts0 + i);
      }
      clock = start.add(const Duration(seconds: 61));
      await c.stop();

      final result = c.result!;
      expect(result.blocks, hasLength(1));
      final block = result.blocks.single;
      expect(block.rateBpm, 6.0);
      // 59 s of observed beats over a 60 s window: the frames got through the
      // router, the isolate decode and the clock alignment.
      expect(block.coverage, closeTo(59 / 60, 0.01));
      expect(block.observedFraction, 1.0);
      expect(app.debugLiveOwners.breathing, isFalse);
    });
  });
}
