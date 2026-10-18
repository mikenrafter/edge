// The six-axis packet path must hand the live graphs and the pedometer exactly
// what the per-consumer decodes it replaced handed them. The expectations
// below are computed the old way: protocol's frameAccelForBand into
// bufferLiveImu for accel, and parseGen5ImuBuffer / decodeR10Imu gyro axes for
// the gyro graphs.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/imu_packet.dart';
import 'package:openstrap_edge/state/live_stream_buffer.dart';
import 'package:openstrap_edge/state/live_stream_controller.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_state_derive_harness.dart' show deriveDbSetUp, deriveDbTearDown;
import 'support/app_state_live_harness.dart';

const _db = 'openstrap_imu_packet_parity.db';

void randomise(Uint8List b, List<int> starts, math.Random rng) {
  final v = ByteData.sublistView(b);
  for (final start in starts) {
    for (var i = 0; i < 100; i++) {
      v.setInt16(start + 2 * i, rng.nextInt(65536) - 32768, Endian.little);
    }
  }
}

Uint8List randomR21(math.Random rng,
    {int accelCount = 100, int gyroCount = 100, int? unix}) {
  final b = r21LiveInner(
      accelCount: accelCount, gyroCount: gyroCount, unix: unix, recordIndex: 9);
  randomise(b, [20, 220, 420, 632, 832, 1032], rng);
  return b;
}

Uint8List randomR10(math.Random rng, {int ts = 1790000000}) {
  final b = r10LiveInner(ts: ts);
  randomise(b, [85, 285, 485, 688, 888, 1088], rng);
  return b;
}

/// A gen4 R10 shorter than the gyro block: protocol's accel decode takes it,
/// the six-axis decode does not.
Uint8List shortR10(math.Random rng) {
  final full = randomR10(rng);
  return Uint8List.sublistView(full, 0, 700);
}

LiveStreamController controllerFor(LiveStreamBuffer buffer) =>
    LiveStreamController(
      buffer: buffer,
      isBackground: () => false,
      activeWorkoutType: () => null,
      breathing: () => false,
      reconcile: () async {},
      clearRadioFallbackAndReconcile: () async {},
      notify: () {},
    );

/// The graph series the replaced code produced for [hex].
Map<String, List<double>> oldGraphs(String hex) {
  final buffer = LiveStreamBuffer();
  final c = controllerFor(buffer);
  final f = proto.frameAccelForBand(hex);
  if (f != null) c.bufferLiveImu(f);
  final bytes = proto.hexToBytes(hex);
  final g5 = proto.parseGen5ImuBuffer(bytes);
  final r10 = g5 == null && bytes[1] == 10 ? proto.decodeR10Imu(hex) : null;
  final gyro = g5 != null
      ? [g5.gyroXdps, g5.gyroYdps, g5.gyroZdps]
      : r10 != null
          ? [r10.gyroX, r10.gyroY, r10.gyroZ]
          : null;
  if (gyro != null) {
    final out = buffer;
    for (var a = 0; a < 3; a++) {
      final key = ['gyro_x', 'gyro_y', 'gyro_z'][a];
      final end = DateTime.now();
      for (var i = 0; i < gyro[a].length; i++) {
        out.add('', key,
            end.subtract(Duration(milliseconds: (gyro[a].length - 1 - i) * 10)),
            gyro[a][i]);
      }
    }
  }
  return {
    for (final k in ['accel_x', 'accel_y', 'accel_z', 'gyro_x', 'gyro_y', 'gyro_z'])
      k: [for (final s in buffer.retained('', k)) s.value],
  };
}

Map<String, List<double>> newGraphs(AppState app) => {
      for (final k in ['accel_x', 'accel_y', 'accel_z', 'gyro_x', 'gyro_y', 'gyro_z'])
        k: [for (final s in app.liveStreams.retained('', k)) s.value],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  final rng = math.Random(20261005);
  final cases = <String, Uint8List>{
    'gen5 full': randomR21(rng),
    'gen5 unequal counts, stale bytes past the counts': randomR21(rng,
        accelCount: 37, gyroCount: 12),
    'gen5 unset device clock': randomR21(rng, unix: 0),
    'gen4 full R10': randomR10(rng),
    'gen4 R10 with unset device clock': randomR10(rng, ts: 0),
    'gen4 R10 shorter than the gyro block': shortR10(rng),
  };

  for (final entry in cases.entries) {
    test('graphs match the replaced decode: ${entry.key}', () {
      final hex = hexOf(entry.value);
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.debugOnLiveFrame(0x2B, hex, null);
      expect(newGraphs(app), oldGraphs(hex));
    });

    test('pedometer input is bit-identical to frameAccelForBand: ${entry.key}',
        () {
      final hex = hexOf(entry.value);
      final old = proto.frameAccelForBand(hex);
      final packet = ImuPacketAdapter().decode(
          packetType: 0x2B, hex: hex, deviceId: '', connectionGeneration: 1);
      final fed = packet == null
          ? proto.frameAccel(hex)
          : (packet.feedsAccelConsumers ? packet.toAccelFrame() : null);
      if (old == null) {
        expect(fed, isNull);
        return;
      }
      expect(fed, isNotNull);
      expect(fed!.mags, old.mags);
      expect(fed.ts, old.ts);
      expect(fed.idx, old.idx);
      if (packet != null) {
        // Axes differ only by the exact 1/4096 scale.
        const s = proto.kGen5AccelScaleG;
        expect(fed.xs, [for (final v in old.xs!) v * s]);
        expect(fed.ys, [for (final v in old.ys!) v * s]);
        expect(fed.zs, [for (final v in old.zs!) v * s]);
      }
    });
  }

  test('each 0x2B frame is decoded once, whichever consumers read it', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final seen = <ImuPacket>[];
    final sub = app.imuPackets.listen(seen.add);
    addTearDown(sub.cancel);
    final frames = [
      hexOf(randomR21(rng)),
      hexOf(randomR10(rng)),
      hexOf(randomR21(rng, accelCount: 5, gyroCount: 6)),
    ];
    for (final f in frames) {
      app.debugOnLiveFrame(0x2B, f, null);
    }
    app.debugOnLiveFrame(0x28, hexOf(hr28Inner()), null);
    app.debugOnLiveFrame(0x33, hexOf(imu33Inner()), null);
    expect(app.debugImuDecodeCount, frames.length);
    return Future<void>.delayed(Duration.zero)
        .then((_) => expect(seen, hasLength(frames.length)));
  });

  test('a seen 0x33 stream keeps gen4 accel on the dedicated stream only', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.debugOnLiveFrame(0x33, hexOf(imu33Inner()), null);
    final before = [for (final s in app.liveStreams.retained('', 'accel_x')) s];
    app.debugOnLiveFrame(0x2B, hexOf(randomR10(rng)), null);
    expect(app.liveStreams.retained('', 'accel_x'), hasLength(before.length));
    expect(app.liveStreams.retained('', 'gyro_x'), hasLength(100),
        reason: 'R10 gyro still reaches the graph');
  });
}
