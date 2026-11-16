// ignore_for_file: file_names
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
void main(){
  // WHY/CLAIM(pulse-worker): a literal fixture is decoded exactly, and checksum failure refuses it.
  test('compressed evidence and checksum cross decode worker',() async {
    final bytes=gzip.encode(utf8.encode('{"schema":1,"beats":[{"time":1000,"raw":840}],"partial":false}'));
    final hash=sha256.convert(bytes).toString();
    final decoded=await Isolate.run(()=>decodePulseEvidenceHeavy(bytes,hash));
    expect(decoded.document['beats'],[{'time':1000,'raw':840}]);
    expect(decoded.document['partial'],false);
    await expectLater(Isolate.run(()=>decodePulseEvidenceHeavy(bytes,'invalid')),throwsStateError);
  });
}
