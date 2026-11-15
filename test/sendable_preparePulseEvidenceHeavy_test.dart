// ignore_for_file: file_names
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'pulse_episode_store_test.dart' show detection;
void main(){
  // WHY/CLAIM(pulse-worker): prepared episode bytes and summary survive the send boundary.
  test('immutable analytics evidence becomes a bounded retained recording',() async {
    final input=PulsePreparationInput(detection(),const []);
    final result=await Isolate.run(()=>preparePulseEvidenceHeavy(input));
    expect(result.episodes.keys,['strap:0']);
    final recording=result.episodes['strap:0']!;
    expect((recording['payload'] as List).length,lessThanOrEqualTo(1024*1024));
    final bytes=(recording['payload'] as List).cast<int>();
    final checksum=recording['checksum'] as String;
    final decoded=await Isolate.run(()=>decodePulseEvidenceHeavy(bytes,checksum));
    expect(decoded.document['start'],0);
    expect(decoded.document['end'],900000);
    expect(decoded.document['beats'],isNotEmpty);
  });
}
