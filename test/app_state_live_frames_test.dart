// Live-stream area: live frame -> LiveStreamBuffer mapping through
// AppState (keys, values, units, timestamps) and the notify count per frame.
// Frames travel the real engine path (the live rig) except where a test calls
// debugOnLiveFrame / debugAppendLiveHr directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_state_derive_harness.dart' show TickCounter, deriveDbSetUp, deriveDbTearDown, settleMs;
import 'support/app_state_live_harness.dart';

const _db = 'openstrap_app_state_live_frames.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  group('HR append (the one tap for the hr stream)', () {
    test('the sample is stamped at the reading time, keyed by device', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect(app.debugAppendLiveHr(kBandId, 61, 1790000000000), isTrue);
      expect(app.debugAppendLiveHr('polar-1', 120, 1790000000000), isTrue);
      final band = app.liveStreams.retained(kBandId, 'hr');
      expect(band.map((s) => s.value), [61.0]);
      expect(band.single.at,
          DateTime.fromMillisecondsSinceEpoch(1790000000000));
      expect(app.liveStreams.retained('polar-1', 'hr').map((s) => s.value),
          [120.0]);
      expect(app.liveStreams.deviceIds, unorderedEquals([kBandId, 'polar-1']));
    });

    test('a repeated stamp for the same device is refused; a later one is '
        'taken; no hr, hr <= 0 or no stamp is not a sample', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect(app.debugAppendLiveHr(kBandId, 60, 1000), isTrue);
      expect(app.debugAppendLiveHr(kBandId, 61, 1000), isFalse);
      expect(app.debugAppendLiveHr(kBandId, 62, 2000), isTrue);
      expect(app.debugAppendLiveHr(kBandId, null, 3000), isFalse);
      expect(app.debugAppendLiveHr(kBandId, 0, 3000), isFalse);
      expect(app.debugAppendLiveHr(kBandId, 70, null), isFalse);
      expect(app.liveStreams.retained(kBandId, 'hr').map((s) => s.value),
          [60.0, 62.0]);
    });

    test('an accepted reading also lands in the live HR trace; a refused one '
        'does not move it', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final rev = app.liveHrTraceRev;
      app.debugAppendLiveHr(kBandId, 60, 1000);
      expect(app.liveHrTraceRev, rev + 1);
      app.debugAppendLiveHr(kBandId, 60, 1000);
      app.debugAppendLiveHr(kBandId, null, 2000);
      expect(app.liveHrTraceRev, rev + 1);
      expect(app.liveHrTrace(kBandId), [60]);
    });

    test('debugAppendLiveHr itself never notifies (its callers do)', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final ticks = TickCounter(app);
      app.debugAppendLiveHr(kBandId, 60, 1000);
      expect(ticks.ticks, 0);
      ticks.stop();
    });

    test('a frame through the engine: hr (bpm) at the engine\'s stamp', () {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      final ts = nowSec();
      rig.feed(hr28Inner(hr: 62, ts: ts));
      expect(rig.values('hr'), [62.0]);
      // The engine's own stamp carries sub-second precision on top of ts.
      final at = rig.app.liveStreams.retained(kBandId, 'hr').single.at;
      final ms = at.millisecondsSinceEpoch;
      expect(ms, greaterThanOrEqualTo(ts * 1000));
      expect(ms, lessThan(ts * 1000 + 1000));
    });
  });

  group('RR beats (stampLiveBeats)', () {
    test('two beats of one frame: the newest at arrival, the earlier one a '
        'beat interval before it', () {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      final before = DateTime.now();
      rig.feed(hr28Inner(rr: [800, 810]));
      final after = DateTime.now();
      expect(rig.values('rr'), [800.0, 810.0]);
      final at = stamps(rig, 'rr');
      expect(at.last.difference(at.first), const Duration(milliseconds: 810));
      expect(at.last.isBefore(before), isFalse);
      expect(at.last.isAfter(after), isFalse);
    });

    test('a batched second frame never rewinds: every beat lands strictly '
        'after the last stored, none is refused', () {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.feed(hr28Inner(rr: [900, 900, 900]));
      rig.feed(hr28Inner(rr: [900, 900, 900]));
      expect(rig.values('rr'), hasLength(6));
      final at = stamps(rig, 'rr');
      for (var i = 1; i < at.length; i++) {
        expect(at[i].isAfter(at[i - 1]), isTrue, reason: 'beat $i');
      }
    });

    test('a frame with no beats adds no rr stream (no fabricated zero)', () {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.feed(hr28Inner(hr: 60));
      expect(rig.app.liveStreams.streamKeys(kBandId), isNot(contains('rr')));
      expect(rig.values('hr'), [60.0]);
    });

    test('gen4 R10 carries beats too; a rev-21 0x2B envelope carries none',
        () {
      final r10 = G6Rig(band: BandProfile.gen4);
      addTearDown(r10.dispose);
      r10.feed(r10LiveInner(rr: [900]));
      expect(r10.values('rr'), [900.0]);
      BleEngine.resetBandClaimForTest();
      final r21 = G6Rig();
      addTearDown(r21.dispose);
      r21.feed(r21LiveInner());
      expect(r21.app.liveStreams.streamKeys(kBandId), isNot(contains('rr')));
    });
  });

  group('IMU', () {
    test('gen5 R21: accel axes in g and gyro in deg/s, 100 samples at 10 ms '
        'steps, the newest stamped now', () {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      final before = DateTime.now();
      rig.feed(r21LiveInner());
      final after = DateTime.now();
      expect(rig.values('accel_x'), everyElement(closeTo(1.0, 1e-9)));
      expect(rig.values('accel_y'), everyElement(closeTo(0.5, 1e-9)));
      expect(rig.values('accel_z'), everyElement(closeTo(0.0, 1e-9)));
      expect(rig.values('gyro_x'), everyElement(closeTo(1000.0, 1e-6)));
      expect(rig.values('gyro_y'), everyElement(closeTo(-500.0, 1e-6)));
      expect(rig.values('gyro_x'), hasLength(100));
      final at = stamps(rig, 'accel_x');
      for (var i = 1; i < at.length; i++) {
        expect(at[i].difference(at[i - 1]), const Duration(milliseconds: 10));
      }
      expect(at.last.isBefore(before), isFalse);
      expect(at.last.isAfter(after), isFalse);
    });

    test('gen4 0x33: ten samples per axis, in g', () {
      final rig = G6Rig(band: BandProfile.gen4);
      addTearDown(rig.dispose);
      rig.feed(imu33Inner(ax: 4096, ay: 2048));
      expect(rig.values('accel_x'), hasLength(10));
      expect(rig.values('accel_x'), everyElement(closeTo(1.0, 1e-9)));
      expect(rig.values('accel_y'), everyElement(closeTo(0.5, 1e-9)));
      expect(rig.values('gyro_x'), isEmpty, reason: '0x33 carries no gyro');
    });

    test('gen4 R10: hr, rr, accel and gyro from one frame', () {
      final rig = G6Rig(band: BandProfile.gen4);
      addTearDown(rig.dispose);
      rig.feed(r10LiveInner(hr: 64, rr: [900], ax: 4096, gx: 16384));
      expect(rig.values('hr'), [64.0]);
      expect(rig.values('rr'), [900.0]);
      expect(rig.values('accel_x'), hasLength(100));
      expect(rig.values('gyro_x'), everyElement(closeTo(1000.0, 1e-6)));
    });

    test('once a 0x33 stream has been seen, a later 0x2B accel is not '
        'buffered again (gyro, hr and rr still are)', () {
      final rig = G6Rig(band: BandProfile.gen4);
      addTearDown(rig.dispose);
      rig.feed(imu33Inner());
      expect(rig.values('accel_x'), hasLength(10));
      rig.feed(r10LiveInner(hr: 64, rr: [900]));
      expect(rig.values('accel_x'), hasLength(10),
          reason: 'R10 accel is the fallback only while 0x33 is not flowing');
      expect(rig.values('gyro_x'), hasLength(100));
      expect(rig.values('hr'), [64.0]);
      expect(rig.values('rr'), [900.0]);
    });
  });

  group('extras', () {
    test('R17: ecg_uv per sample, ecg_quality, and ecg_band_hr only when the '
        'band reports a rate', () {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.feed(r17LiveInnerWith(liveHr: 71, quality: 3));
      expect(rig.values('ecg_uv'),
          [for (var i = 0; i < 100; i++) ((i - 50) * 10).toDouble()]);
      expect(rig.values('ecg_quality'), [3.0]);
      expect(rig.values('ecg_band_hr'), [71.0]);
      final uv = stamps(rig, 'ecg_uv');
      expect(uv[1].difference(uv[0]), const Duration(milliseconds: 10));
      rig.feed(r17LiveInnerWith(liveHr: 0, quality: 1));
      expect(rig.values('ecg_band_hr'), [71.0],
          reason: '0 is "no reading", not a heart rate');
      expect(rig.values('ecg_quality'), [3.0, 1.0]);
    });

    test('R11: two raw channels, 50 samples each at 20 ms steps', () {
      final rig = G6Rig(band: BandProfile.gen4);
      addTearDown(rig.dispose);
      rig.feed(r11LiveInner(a0: 1000, b0: -2000));
      expect(rig.values('r11_ch1'),
          [for (var i = 0; i < 50; i++) (1000 + i).toDouble()]);
      expect(rig.values('r11_ch2'),
          [for (var i = 0; i < 50; i++) (-2000 + i).toDouble()]);
      final at = stamps(rig, 'r11_ch1');
      expect(at[1].difference(at[0]), const Duration(milliseconds: 20));
    });

    test('a decoded field with no stream name appears under its raw name; '
        'the already-named ones do not repeat', () {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.feed(hr28V2Inner(hr: 70, location: 3));
      expect(rig.values('location'), [3.0]);
      final keys = rig.app.liveStreams.streamKeys(kBandId);
      for (final named in const [
        'rec_type', 'packet_type', 'ts_epoch', 'ts_subsec', 'counter',
        'hr_precise',
      ]) {
        expect(keys, isNot(contains(named)), reason: named);
      }
    });

    test('a frame the packet did not populate adds only what it carries', () {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.feed(r21LiveInner());
      expect(rig.app.liveStreams.streamKeys(kBandId),
          unorderedEquals(
              ['accel_x', 'accel_y', 'accel_z', 'gyro_x', 'gyro_y', 'gyro_z']));
    });

    test('stream keys list in first-seen order: the frame callback (rr) '
        'runs before the engine state (hr)', () {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.feed(hr28Inner(hr: 60, rr: [800]));
      expect(rig.app.liveStreams.streamKeys(kBandId).take(2), ['rr', 'hr']);
    });
  });

  group('garbage in', () {
    test('a frame that does not decode adds nothing and does not throw', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect(() => app.debugOnLiveFrame(0x28, 'zz', 1), returnsNormally);
      expect(() => app.debugOnLiveFrame(0x2B, '', null), returnsNormally);
      expect(() => app.debugOnLiveFrame(0x33, '33', 5), returnsNormally);
      expect(app.liveStreams.streamKeys(kBandId), isEmpty);
    });

    test('debugOnLiveFrame is the same path as the engine: same keys', () {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      final inner = r21LiveInner();
      rig.feed(inner);
      final viaEngine = snapshot(rig).keys.toList();
      BleEngine.resetBandClaimForTest();
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.debugOnLiveFrame(0x2B, hexOf(inner), null);
      expect(app.liveStreams.streamKeys(kBandId), viaEngine);
    });
  });

  group('notifyListeners', () {
    test('heart-rate and ECG frames never tick AppState', () {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      final ticks = TickCounter(rig.app);
      for (var i = 0; i < 5; i++) {
        rig.feed(hr28Inner(hr: 60 + i, rr: [800 + i], ts: nowSec() + i));
        rig.feed(r17LiveInner());
      }
      expect(rig.app.liveStreams.streamKeys(kBandId), isNotEmpty);
      expect(ticks.ticks, 0);
      ticks.stop();
    });

    test('IMU frames tick AppState through the live pedometer, throttled to '
        'one per second of ingest time (the buffer feed itself adds none)', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final ticks = TickCounter(app);
      for (var i = 0; i < 5; i++) {
        app.debugOnLiveFrame(0x2B, hexOf(r21LiveInner()), null);
      }
      expect(ticks.ticks, 1, reason: 'five frames in one instant: one tick');
      ticks.stop();
    });

    test('debugFeedLiveAccel: the pedometer tick follows the supplied clock',
        () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final ticks = TickCounter(app);
      final mags = List<double>.filled(10, 1.0);
      const t0 = 1790000000000;
      app.debugFeedLiveAccel(mags, atMs: t0);
      app.debugFeedLiveAccel(mags, atMs: t0 + 500);
      expect(ticks.ticks, 1);
      app.debugFeedLiveAccel(mags, atMs: t0 + 1000);
      expect(ticks.ticks, 2);
      ticks.stop();
    });

    test('debugFeedLiveAccel never touches the Live devices buffer', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.debugFeedLiveAccel(List<double>.filled(10, 1.0), atMs: 1790000000000);
      expect(app.liveStreams.streamKeys(kBandId), isEmpty);
    });
  });

  group('couplings that stay in AppState', () {
    test('a live 0x33 frame feeds the live pedometer: a gait workout goes '
        'from "unmeasured" to a measured count', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.startWorkout(type: 'running');
      expect(app.workoutStepsMeasured, isNull);
      app.debugOnLiveFrame(0x33, hexOf(imu33Inner(ax: 0, ay: 0, az: 4096)), 1790000000);
      expect(app.workoutStepsMeasured, 0,
          reason: 'accel arrived, no steps in it: measured zero, not null');
      await app.stopWorkout();
      await settleMs(300);
    });

    test('a non-gait workout is never billed pedometer samples', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.startWorkout(type: 'Strength');
      app.debugOnLiveFrame(0x33, hexOf(imu33Inner()), 1790000000);
      expect(app.workoutStepsMeasured, isNull);
      await app.stopWorkout();
      await settleMs(300);
    });
  });
}
