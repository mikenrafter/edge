// Test support: a connected-looking band whose live frames travel the
// REAL engine path (BleEngine._processImmediateFrame -> onLiveFrame ->
// AppState -> LiveStreamBuffer), and whose outgoing commands are recorded.
//
// The rig wires the engine the way the production AppState constructor does:
//   onLiveFrame -> AppState.debugOnLiveFrame        (production: _onLiveFrame)
//   onState     -> AppState.debugAppendLiveHr       (production: _onEngineState)
//   liveOwners  -> AppState.debugLiveOwners         (production: _liveOwners)
// `AppState.forTesting`'s own default engine leaves onLiveFrame unwired, which
// is why the rig builds its own and hands it in.
//
// ASSUMED NEW APIS are reached through `dynamic` shims below, so a missing
// symbol fails the one test that uses it (NoSuchMethodError) instead of
// breaking compilation of the whole file:
//   Future<void> AppState.startLiveFeed(String deviceId)
//   Future<void> AppState.stopLiveFeed(String deviceId)
//   bool         AppState.isLiveFeedOn(String deviceId)
//   bool         LiveStreamOwners.developerLiveFeed   (read via debugLiveOwners)
// The band's deviceId is LocalDb.kPrimaryDeviceId ('').

import 'dart:typed_data';

import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart' show LocalDb;
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart' show PairedDevice;
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'ecg_trace.dart' show r17;

typedef G6Write = ({int opcode, List<int> body});

const String kBandId = ''; // LocalDb.kPrimaryDeviceId

int nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

// ── frame builders (synthetic, shape-correct; no real gen5 live capture exists
// in the repo — protocol's own v21/R17 tests are synthetic too) ─────────────

/// 0x28 compact realtime HR: ts@2, hr@8, rr_count@9, rr i16@10.., wearing@18.
Uint8List hr28Inner({int hr = 62, List<int> rr = const [], int? ts}) {
  final b = Uint8List(20);
  final v = ByteData.sublistView(b);
  b[0] = 0x28;
  v.setUint32(2, ts ?? nowSec(), Endian.little);
  b[8] = hr;
  b[9] = rr.length;
  for (var i = 0; i < rr.length; i++) {
    v.setInt16(10 + 2 * i, rr[i], Endian.little);
  }
  b[18] = 1;
  return b;
}

/// 0x28 revision-2 realtime HR: [1]=2, ts@2, subsec@6, hr@8, on-body@18,
/// garment location@19. `decodeFrame` surfaces `location` as a decoded field
/// that has no stream name of its own.
Uint8List hr28V2Inner({int hr = 70, int location = 3, int? ts}) {
  final b = Uint8List(20);
  final v = ByteData.sublistView(b);
  b[0] = 0x28;
  b[1] = 2;
  v.setUint32(2, ts ?? nowSec(), Endian.little);
  b[8] = hr;
  b[18] = 1;
  b[19] = location;
  return b;
}

/// gen5 live IMU: a 0x2B envelope carrying a record-21 buffer (1232 bytes,
/// 100 accel + 100 gyro samples per axis). Raw int16 LSBs: accel 1/4096 g,
/// gyro 2000/32768 deg/s.
Uint8List r21LiveInner({
  int ax = 4096, // 1.0 g
  int ay = 2048, // 0.5 g
  int az = 0,
  int gx = 16384, // 1000 deg/s
  int gy = -8192, // -500 deg/s
  int gz = 0,
  int? unix,
  int recordIndex = 1,
  int accelCount = 100,
  int gyroCount = 100,
}) {
  final b = Uint8List(kGen5V21InnerLen);
  final v = ByteData.sublistView(b);
  b[0] = 0x2B;
  b[1] = 21;
  b[2] = 0x80;
  v.setUint32(3, recordIndex, Endian.little);
  v.setUint32(7, unix ?? nowSec(), Endian.little);
  v.setUint16(16, accelCount, Endian.little);
  v.setUint16(622, gyroCount, Endian.little);
  for (var i = 0; i < 100; i++) {
    v.setInt16(20 + 2 * i, ax, Endian.little);
    v.setInt16(220 + 2 * i, ay, Endian.little);
    v.setInt16(420 + 2 * i, az, Endian.little);
    v.setInt16(632 + 2 * i, gx, Endian.little);
    v.setInt16(832 + 2 * i, gy, Endian.little);
    v.setInt16(1032 + 2 * i, gz, Endian.little);
  }
  return b;
}

/// gen4 live R10 (0x2B, rec 10, 1920 bytes): ts@7, hr@17, rr_count@18, rr@19,
/// accel X/Y/Z@85/285/485, gyro X/Y/Z@688/888/1088 (100 int16 each).
Uint8List r10LiveInner({
  int hr = 64,
  List<int> rr = const [900],
  int ax = 4096,
  int gx = 16384,
  int? ts,
}) {
  final b = Uint8List(1920);
  final v = ByteData.sublistView(b);
  b[0] = 0x2B;
  b[1] = 10;
  v.setUint32(3, 7, Endian.little);
  v.setUint32(7, ts ?? nowSec(), Endian.little);
  b[17] = hr;
  b[18] = rr.length;
  for (var i = 0; i < rr.length; i++) {
    v.setInt16(19 + 2 * i, rr[i], Endian.little);
  }
  for (var i = 0; i < 100; i++) {
    v.setInt16(85 + 2 * i, ax, Endian.little);
    v.setInt16(285 + 2 * i, 0, Endian.little);
    v.setInt16(485 + 2 * i, 0, Endian.little);
    v.setInt16(688 + 2 * i, gx, Endian.little);
    v.setInt16(888 + 2 * i, 0, Endian.little);
    v.setInt16(1088 + 2 * i, 0, Endian.little);
  }
  return b;
}

/// gen4 0x33 IMU stream: ts@4, idx@14, 10 samples each of X,Y,Z int16 from 24.
Uint8List imu33Inner({int ax = 4096, int ay = 0, int az = 0, int? ts}) {
  final b = Uint8List(84);
  final v = ByteData.sublistView(b);
  b[0] = 0x33;
  v.setUint32(4, ts ?? nowSec(), Endian.little);
  v.setUint16(14, 1, Endian.little);
  for (var i = 0; i < 10; i++) {
    v.setInt16(24 + 2 * i, ax, Endian.little);
    v.setInt16(24 + 2 * (10 + i), ay, Endian.little);
    v.setInt16(24 + 2 * (20 + i), az, Endian.little);
  }
  return b;
}

/// A live R17 (MG filtered ECG) packet's inner bytes, 100 samples of i*10 uV.
Uint8List r17LiveInner() => r17(
      strapSeconds: nowSec(),
      samples: [for (var i = 0; i < 100; i++) (i - 50) * 10],
    ).inner;

// ── the rig ────────────────────────────────────────────────────────────────

class G6Rig {
  G6Rig({this.band = BandProfile.gen5, bool connected = true}) {
    engine = BleEngine(
      onRecord: (_, _) async {},
      onState: (s) =>
          app.debugAppendLiveHr(LocalDb.kPrimaryDeviceId, s.liveHr, s.liveHrAt),
      log: logs.add,
      onLiveFrame: (pt, hex, ts) => app.debugOnLiveFrame(pt, hex, ts),
      liveOwners: () => app.debugLiveOwners,
    );
    app = AppState.forTesting(engine: engine);
    engine.debugInstallFakeLink(
      band: band,
      listening: true,
      onWrite: (Uint8List frame) async {
        final inner = parseFrame(frame, profile: band)!.inner;
        final w = (opcode: inner[2], body: inner.sublist(3));
        if (throwing.contains(w.opcode)) {
          throw StateError('write 0x${w.opcode.toRadixString(16)} blew up');
        }
        writes.add(w);
        return !failing.contains(w.opcode);
      },
    );
    app.paired = PairedDevice('AA:BB:CC:DD:EE:FF', 'SER1');
    engine.state.generation = band.isGen5 ? 'gen5' : 'gen4';
    engine.state.connection = connected ? 'connected' : 'disconnected';
  }

  final BandProfile band;
  late final BleEngine engine;
  late final AppState app;
  final logs = <String>[];

  /// Every write that reached the (fake) radio, in order.
  final writes = <G6Write>[];

  /// Opcodes whose write reports failure / throws.
  final failing = <int>{};
  final throwing = <int>{};

  List<int> get opcodes => [for (final w in writes) w.opcode];

  /// `(opcode, on/off)`. The gen5 IMU toggle and both optical toggles carry
  /// `[rev1, on]`; everything else a bare `[on]`.
  List<(int, int)> get ops => [
        for (final w in writes)
          (
            w.opcode,
            w.opcode == Cmd.enableOpticalData ||
                    w.opcode == Cmd.toggleOpticalMode ||
                    (w.opcode == Cmd.toggleImuMode && band.isGen5)
                ? w.body[1]
                : w.body[0],
          ),
      ];

  /// One inbound live frame through the real engine immediate-frame path.
  void feed(Uint8List inner) =>
      engine.debugProcessImmediateFrame(Frame(inner, true, true));

  List<double> values(String key) => [
        for (final s in app.liveStreams.retained(kBandId, key)) s.value,
      ];

  /// Let a started/stopped reconcile (100 ms / 60 ms gaps between writes) run.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 700));

  Future<void> dispose() async {
    app.dispose();
    BleEngine.resetBandClaimForTest();
  }
}

// ── dynamic shims for the assumed API ──────────────────────────────────────

Future<void> startFeed(AppState app, [String id = kBandId]) async =>
    await (app as dynamic).startLiveFeed(id);

Future<void> stopFeed(AppState app, [String id = kBandId]) async =>
    await (app as dynamic).stopLiveFeed(id);

bool feedOn(AppState app, [String id = kBandId]) =>
    (app as dynamic).isLiveFeedOn(id) as bool;

bool developerOwnerSet(AppState app) =>
    ((app.debugLiveOwners as dynamic).developerLiveFeed) as bool;
