// WHY: CLAIM(official-export-saved-bytes), authenticate the provider stream,
// never a cached ciphertext or verification plaintext. No destination-file API.
// catches: skip authentication; hash ciphertext; ignore final tag; lose chunks.
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/import/backup_crypto.dart';
import 'package:openstrap_edge/import/backup_stream.dart';

void main() {
  test('independent Python AESGCM fixture authenticates literal OSBK bytes',()async {
    // Oracle: Python cryptography AESGCM, hashlib.pbkdf2_hmac SHA256, 1000
    // rounds, 16 zero salt bytes, 12 zero nonce bytes. Plaintext ends 00 ff.
    const hex='4f53424b0101000003e800000000000000000000000000000000000000000000000000000000740d5a1462514d1886a8014ec2754962680f4ed0a1580ad028954b13f47d816fe2f7cbecc031683ff1ba';
    final bytes=[for(var i=0;i<hex.length;i+=2)int.parse(hex.substring(i,i+2),radix:16)];
    expect(await verifyBackupStream(Stream.value(bytes),'fixture pass'),
      'a0d43cd3f2f558d6015523a7d1de963c9180c66b0589a556f58d9edb05e9e7e7');
  });
  test('OSBK stream authenticates actual bytes and matches legacy reader', () async {
    final root=await Directory.systemTemp.createTemp('stream_');
    try {
      final plain=File('${root.path}/plain.db');
      final bytes=List<int>.generate(2*1024*1024+29,(i)=>(i*17)%251);
      await plain.writeAsBytes(bytes);
      final cipher=<int>[]; final progress=<int>[];
      final digest=await encryptBackupStream(plain,'one password',
        (chunk) async { cipher.addAll(chunk); }, iterations:1000,onBytes:progress.add);
      expect(digest,sha256.convert(bytes).toString());
      expect(progress.last,bytes.length); expect(progress,orderedEquals(progress.toList()..sort()));
      expect(cipher.take(4),[79,83,66,75]); expect(cipher.length,bytes.length+54);
      final verifyProgress=<int>[];
      Stream<List<int>> saved() async* { for(var i=0;i<cipher.length;i+=113) { yield cipher.sublist(i, i+113>cipher.length?cipher.length:i+113); } }
      expect(await verifyBackupStream(saved(),'one password',onBytes:verifyProgress.add),digest);
      expect(verifyProgress.last,cipher.length);
      await File('${root.path}/legacy.osbk').writeAsBytes(cipher);
      await decryptBackupFile(File('${root.path}/legacy.osbk'),File('${root.path}/legacy.db'),'one password');
      expect(await File('${root.path}/legacy.db').readAsBytes(),bytes);
      cipher[cipher.length-1]^=1;
      await expectLater(verifyBackupStream(saved(),'one password'),throwsA(isA<BackupFormatException>()));
      expect(root.listSync().map((e)=>e.path.split('/').last).toSet(),{'plain.db','legacy.osbk','legacy.db'});
    } finally { await root.delete(recursive:true); }
  });
  test('cancellation stops before another encrypted chunk is written', () async {
    final root=await Directory.systemTemp.createTemp('stream_cancel_');
    try {
      final plain=File('${root.path}/plain')..writeAsBytesSync(List.filled(600000,7));
      var writes=0;
      await expectLater(encryptBackupStream(plain,'pw',(chunk) async { writes++; }, iterations:1000,
        checkCancelled:(){ if(writes>=2) throw StateError('cancelled'); }),throwsStateError);
      expect(writes,2);
    } finally { await root.delete(recursive:true); }
  });
}
