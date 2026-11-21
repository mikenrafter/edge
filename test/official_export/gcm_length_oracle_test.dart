// WHY: review r1 F7. pointycastle 3.9 (what every OSBK reader runs) takes the
// ciphertext bit length mod 2^32, so above 512 MiB its GCM tag is not the
// standard one and OsbkGcm.kt has to match it (v0.12.2 refused a standard tag).
// The Kotlin suite pins the same 537,000,123-byte stream against the SHA-256
// recorded below; this test is the repeatable source of that number: it runs
// pointycastle itself over the identical stream (~7 min) and must reproduce it.
// Off by default; run with OSBK_LENGTH_ORACLE=1.
// catches: the recorded hash drifting from what the real reader computes;
// a pointycastle upgrade that fixes (or changes) the length handling.
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

/// The recorded oracle: SHA-256 of header + ciphertext + tag that pointycastle
/// writes for [oracleBytes] of [oraclePlain] under [oracleKey]/[oracleNonce]/[oracleHeader]
/// (recorded 2026-11-21 on Boat, 390 s wall including the compile).
const oracleBytes = 537000123;
const oracleSha256 = 'e80f1467cc408c3797d023c7e39a1bed69506b5dfd65273d6106bb6108f6892e';

final oracleKey = Uint8List.fromList([for (var i = 0; i < 32; i++) i]);
final oracleNonce = Uint8List.fromList([for (var i = 0; i < 12; i++) 0xA0 + i]);
final oracleHeader = Uint8List.fromList([for (var i = 0; i < 38; i++) 0x40 + i]);

/// xorshift64 bytes (13, 7, 17), top byte of each state; the Kotlin test
/// generates the same stream. Seed 0x9E3779B97F4A7C15.
Iterable<Uint8List> oraclePlain({int chunk = 1 << 20}) sync* {
  var x = 0x9E3779B97F4A7C15;
  var left = oracleBytes;
  while (left > 0) {
    final n = left < chunk ? left : chunk;
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      x ^= x << 13;
      x ^= x >>> 7;
      x ^= x << 17;
      out[i] = (x >>> 56) & 0xff;
    }
    left -= n;
    yield out;
  }
}

void main() {
  test('pointycastle over the 537,000,123-byte oracle stream gives the recorded sha256', () {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(oracleKey), 128, oracleNonce, oracleHeader));
    final sink = _Sink();
    final digest = hashes.sha256.startChunkedConversion(sink);
    digest.add(oracleHeader);
    for (final plain in oraclePlain()) {
      final out = Uint8List(plain.length + 16);
      final m = cipher.processBytes(plain, 0, plain.length, out, 0);
      digest.add(Uint8List.sublistView(out, 0, m));
    }
    final tail = Uint8List(32);
    final t = cipher.doFinal(tail, 0);
    digest.add(Uint8List.sublistView(tail, 0, t));
    digest.close();
    final got = sink.value.toString();
    stderr.writeln('ORACLE_SHA256=$got');
    expect(got, oracleSha256);
  }, skip: Platform.environment['OSBK_LENGTH_ORACLE'] == '1' ? false : 'set OSBK_LENGTH_ORACLE=1 (about 7 minutes)',
      timeout: const Timeout(Duration(minutes: 30)));
}

class _Sink implements Sink<hashes.Digest> {
  late hashes.Digest value;
  @override void add(hashes.Digest data) => value = data;
  @override void close() {}
}
