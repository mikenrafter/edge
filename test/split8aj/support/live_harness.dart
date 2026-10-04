// Shared helpers for the 8AJ seam 2 (LiveStreamController) tests. Everything
// goes through AppState's public and @visibleForTesting surface, so the same
// files serve the characterization tests before the move and after it.
//
// Frames travel the real engine path through the 8AI G6 rig (a gen5 or gen4
// fake link whose onLiveFrame / onState / liveOwners are wired the way the
// production AppState constructor wires them).

import 'dart:typed_data';

import '../../fix8ai/support/g6_support.dart';
import '../../support/ecg_trace.dart' show r17;

export '../../fix8ai/support/g6_support.dart';

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
