// Shared helpers for the LiveStreamController tests. Everything
// goes through AppState's public and @visibleForTesting surface, so the same
// files serve the AppState-level tests and the controller's own tests.
//
// Frames travel the real engine path through the live-stream band rig (a gen5 or gen4
// fake link whose onLiveFrame / onState / liveOwners are wired the way the
// production AppState constructor wires them).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart' show PairedDevice;
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app_state_derive_harness.dart' show settleMs;
import 'live_stream_band_rig.dart';
import 'ecg_trace.dart' show r17;

export 'app_state_derive_harness.dart' show settleMs, TickCounter;
export 'live_stream_band_rig.dart';

/// A live R17 packet's inner bytes with the band's own live HR (inner[20]) and
/// signal quality (inner[13]) set; the samples are i * 10 uV like
/// [r17LiveInner].
Uint8List r17LiveInnerWith({int liveHr = 0, int quality = 0}) {
  final inner = r17(
    strapSeconds: nowSec(),
    samples: [for (var i = 0; i < 100; i++) (i - 50) * 10],
    quality: quality,
  ).inner;
  inner[20] = liveHr;
  return inner;
}

/// A live R11 (0x2B, rec 11) packet: two raw int32 channels of 50 samples at
/// offsets 36 and 236, channel A = a0 + i, channel B = b0 + i.
Uint8List r11LiveInner({int a0 = 1000, int b0 = -2000, int? ts}) {
  final b = Uint8List(440);
  final v = ByteData.sublistView(b);
  b[0] = 0x2B;
  b[1] = 11;
  v.setUint32(7, ts ?? nowSec(), Endian.little);
  for (var i = 0; i < 50; i++) {
    v.setInt32(36 + 4 * i, a0 + i, Endian.little);
    v.setInt32(236 + 4 * i, b0 + i, Endian.little);
  }
  return b;
}

/// Hex of an inner packet, the way the engine hands it to onLiveFrame.
String hexOf(Uint8List inner) =>
    inner.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Every stream the band has in the buffer, as key -> values (oldest first).
Map<String, List<double>> snapshot(G6Rig rig) => {
      for (final k in rig.app.liveStreams.streamKeys(kBandId)) k: rig.values(k),
    };

/// The sample times of one stream, oldest first.
List<DateTime> stamps(G6Rig rig, String key) => [
      for (final s in rig.app.liveStreams.retained(kBandId, key)) s.at,
    ];

// ── from upstream's copy of this harness (merge: union of both sides) ──

// Shared helpers for the AppState live-stream tests. Everything goes through
// AppState's public and @visibleForTesting surface, so the same files keep
// passing wherever the live-stream ownership code lives.
//
// LiveRig is an AppState over an engine wired the way the production
// constructor wires it for the live path (onLiveFrame, liveOwners) with a fake
// gen5/gen4 link that records every command the engine writes. The engine's
// owner callback is counted, which is how a test sees that AppState nudged the
// engine (the engine reads the owner set once per reconcile pass).



typedef LiveWrite = ({int opcode, List<int> body});

Future<void> liveDbSetUp(String name) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await LocalDb.close();
  LocalDb.dbName = name;
  await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name));
  SharedPreferences.setMockInitialValues({});
}

Future<void> liveDbTearDown(String name) async {
  // Fire-and-forget writes from the last test (workout teardown, device rows)
  // must land before the handle closes under them.
  await settleMs(400);
  await LocalDb.close();
  await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name));
}

/// SQLite's total_changes() on the app's own connection: any INSERT, UPDATE or
/// DELETE moves it.
Future<int> dbChanges() async {
  final db = await LocalDb.instance;
  final r = await db.rawQuery('SELECT total_changes() AS n');
  return (r.single['n'] as num).toInt();
}

// ── the rig ──────────────────────────────────────────────────────────────────

class LiveRig {
  LiveRig({this.band = BandProfile.gen5}) {
    engine = BleEngine(
      onRecord: (_, _) async {},
      onState: (_) {},
      log: logs.add,
      onLiveFrame: (pt, hex, ts) => app.debugOnLiveFrame(pt, hex, ts),
      liveOwners: () {
        ownerReads++;
        return app.debugLiveOwners;
      },
    );
    app = AppState.forTesting(engine: engine);
    engine.debugInstallFakeLink(
      band: band,
      listening: true,
      onWrite: (Uint8List frame) async {
        final inner = parseFrame(frame, profile: band)!.inner;
        writes.add((opcode: inner[2], body: inner.sublist(3)));
        return true;
      },
    );
    app.paired = PairedDevice('AA:BB:CC:DD:EE:FF', 'SER1');
    engine.state.generation = band.isGen5 ? 'gen5' : 'gen4';
    engine.state.connection = 'connected';
  }

  final BandProfile band;
  late final BleEngine engine;
  late final AppState app;
  final logs = <String>[];

  /// Every write that reached the (fake) radio, in order.
  final writes = <LiveWrite>[];

  /// How many times the engine asked for the owner set.
  int ownerReads = 0;

  /// `(opcode, on/off)`. The gen5 IMU toggle carries `[rev1, on]`; HR a bare
  /// `[on]`.
  List<(int, int)> get ops => [
        for (final w in writes)
          (
            w.opcode,
            w.opcode == Cmd.toggleImuMode && band.isGen5 ? w.body[1] : w.body[0],
          ),
      ];

  /// One inbound live frame through the real engine immediate-frame path.
  void feed(Uint8List inner) =>
      engine.debugProcessImmediateFrame(Frame(inner, true, true));

  /// Wait for the engine's coalesced reconcile pass, write gaps included: a
  /// caller that arrives mid-pass is a barrier for the pass that sees it.
  Future<void> settle() => engine.reconcileLiveStreams();

  Future<void> dispose() async {
    app.dispose();
    BleEngine.resetBandClaimForTest();
  }
}
