// Owns the storage encoding of an exact raw frame. LocalDb's live writers and
// the official exporter share this pure encoder; target parity is certified by
// the unchanged tagged receiver. Canonical lowercase hex uses a BLOB, all other
// text stays verbatim. No framing or record decode occurs here.
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

Uint8List? _canonicalHexBytes(String hex) {
    final n = hex.length;
    if (n == 0 || n.isOdd) return null;
    final out = Uint8List(n >> 1);
    int nibble(int c) {
      if (c >= 0x30 && c <= 0x39) return c - 0x30;
      if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
      return -1;
    }

    for (var i = 0; i < n; i += 2) {
      final hi = nibble(hex.codeUnitAt(i)), lo = nibble(hex.codeUnitAt(i + 1));
      if (hi < 0 || lo < 0) return null;
      out[i >> 1] = (hi << 4) | lo;
    }
    return out;
  }

Map<String,Object?> encodeRawArchiveRow({
  required String deviceId, required String hex, required int? counter,
  required int packetType, required int? recTs, required int capturedAt,
  required String reason,
}) {
    final bytes = _canonicalHexBytes(hex);
    return {
      'device_id': deviceId,
      'hash': Uint8List.fromList(
        bytes != null
            ? sha1.convert(bytes).bytes
            : sha1.convert(utf8.encode('text:$hex')).bytes,
      ),
      'counter': counter,
      'packet_type': packetType,
      'rec_ts': recTs,
      'captured_at': capturedAt,
      'reason': reason,
      'hex': bytes == null ? hex : null,
      'frame': bytes,
    };
  }
