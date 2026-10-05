// 8AI G6: every stream a WHOOP sends while live lands in LiveStreamBuffer
// under a stable key, in the unit its label states.
//
// Frames travel the real engine path (support/g6_support.dart: engine
// immediate-frame -> onLiveFrame -> AppState -> buffer) on a gen5 (WHOOP 5/MG)
// and a gen4 link separately.
//
// STREAM KEYS (device id '' = the band), unit in the label:
//   hr          bpm   realtime HR byte (0x28 / R10)
//   rr          ms    beat intervals (0x28 / R10)
//   accel_x/y/z g     accelerometer axes. NOTE the protocol returns the axes of
//                     frameAccel / frameAccelGen5Live as RAW int16 LSBs (only
//                     `mags` is in g), so the app must divide by 4096 itself.
//                     Today's code stores the raw LSBs under a "(g)" label.
//   gyro_x/y/z  deg/s gen5 R21: 2000/32768 per LSB; gen4 R10: 0.06103515625
//   ecg_uv      uV    gen5 MG R17 filtered ECG samples (only while ECG runs)
//   <raw name>        any other numeric field `decodeFrame` returns for a live
//                     frame (e.g. `location` of the rev-2 0x28 packet) appears
//                     under that decoded name, unlabelled, with its value.
//
// ASSUMED: gen5 frames the app computes nothing from (no spo2 / skin temp /
// battery in a realtime packet) add no stream: absent stays absent (§3.3).
//
// Fixtures are synthetic but shape-correct; the repo has no real captured gen5
// live IMU frame (protocol's own R21 tests are synthetic too).
//
// Uses only symbols that exist today, so every failure here is behavioural.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ui2/profile/live_devices.dart'
    show liveStreamLabel;
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/live_stream_band_rig.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  group('gen5 / MG', () {
    test('R21 accelerometer axes are stored in g (raw LSB / 4096)', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.feed(r21LiveInner()); // ax 4096, ay 2048, az 0 LSB
      expect(rig.values('accel_x'), hasLength(100));
      expect(rig.values('accel_x'), everyElement(closeTo(1.0, 1e-6)));
      expect(rig.values('accel_y'), everyElement(closeTo(0.5, 1e-6)));
      expect(rig.values('accel_z'), everyElement(closeTo(0.0, 1e-6)));
    });

    test('R21 gyroscope axes become gyro_x/y/z in deg/s', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.feed(r21LiveInner()); // gx 16384, gy -8192 LSB
      expect(rig.values('gyro_x'), hasLength(100));
      expect(rig.values('gyro_x'), everyElement(closeTo(1000.0, 1e-6)));
      expect(rig.values('gyro_y'), everyElement(closeTo(-500.0, 1e-6)));
      expect(rig.values('gyro_z'), everyElement(closeTo(0.0, 1e-6)));
    });

    test('a realtime HR frame gives hr (bpm) and rr (ms)', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.feed(hr28Inner(hr: 62, rr: [800, 810]));
      expect(rig.values('hr'), [62.0]);
      expect(rig.values('rr'), [800.0, 810.0]);
    });

    test('a decoded field with no stream name appears under its raw name',
        () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.feed(hr28V2Inner(hr: 70, location: 3));
      expect(rig.values('hr'), [70.0]);
      expect(rig.app.liveStreams.streamKeys(kBandId), contains('location'));
      expect(rig.values('location'), [3.0]);
      expect(liveStreamLabel('location'), 'location',
          reason: 'unknown keys are shown as-is');
    });

    test('R17 filtered ECG lands as ecg_uv, one value per sample', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.feed(r17LiveInner());
      expect(rig.values('ecg_uv'),
          [for (var i = 0; i < 100; i++) ((i - 50) * 10).toDouble()]);
    });

    test('nothing the packet did not carry is invented', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.feed(r21LiveInner());
      expect(
          rig.app.liveStreams.streamKeys(kBandId),
          unorderedEquals([
            'accel_x',
            'accel_y',
            'accel_z',
            'gyro_x',
            'gyro_y',
            'gyro_z',
          ]));
    });
  });

  group('gen4', () {
    test('0x33 IMU axes are stored in g', () async {
      final rig = G6Rig(band: BandProfile.gen4);
      addTearDown(rig.dispose);
      rig.feed(imu33Inner()); // ax 4096 LSB
      expect(rig.values('accel_x'), hasLength(10));
      expect(rig.values('accel_x'), everyElement(closeTo(1.0, 1e-6)));
      expect(rig.values('accel_y'), everyElement(closeTo(0.0, 1e-6)));
    });

    test('a live R10 gives hr, rr, accel (g) and gyro (deg/s)', () async {
      final rig = G6Rig(band: BandProfile.gen4);
      addTearDown(rig.dispose);
      rig.feed(r10LiveInner(hr: 64, rr: [900], ax: 4096, gx: 16384));
      expect(rig.values('hr'), [64.0]);
      expect(rig.values('rr'), [900.0]);
      expect(rig.values('accel_x'), everyElement(closeTo(1.0, 1e-6)));
      // 16384 LSB * 0.06103515625 deg/s
      expect(rig.values('gyro_x'), hasLength(100));
      expect(rig.values('gyro_x'), everyElement(closeTo(1000.0, 1e-6)));
    });
  });

  group('labels carry units', () {
    const units = {
      'hr': '(bpm)',
      'rr': '(ms)',
      'accel_x': '(g)',
      'accel_y': '(g)',
      'accel_z': '(g)',
      'gyro_x': '(°/s)',
      'gyro_y': '(°/s)',
      'gyro_z': '(°/s)',
      'ecg_uv': '(µV)',
    };
    for (final MapEntry(:key, :value) in units.entries) {
      test('$key is labelled $value', () {
        expect(liveStreamLabel(key), isNot(key), reason: 'a human label');
        expect(liveStreamLabel(key), contains(value));
      });
    }
  });
}
