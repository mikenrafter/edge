// ignore_for_file: file_names
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/pulse_episode_worker.dart';
void main(){
  // WHY/CLAIM(pulse-worker): literal committed rows cross the real worker boundary
  // with their source/time/interval unchanged, and thin input explicitly refuses.
  test('pulse detection row maps cross isolates with exact evidence',() async {
    final input=PulseDetectionInput([
      {'device_id':'strap','ts_ms':1000,'rec_ts':1,'beat_index':0,'beat_ts_ms':1000,'rr_ms':1000},
      {'device_id':'strap','ts_ms':2000,'rec_ts':2,'beat_index':0,'beat_ts_ms':2000,'rr_ms':1000},
    ],600000,0);
    final result=await Isolate.run(()=>detectPulseEpisodesHeavy(input));
    final window=result.detection.windows.first;
    expect(window.beats.first.id,'strap:1000:0');
    expect(window.beats.first.timeMs,1000);
    expect(window.beats.first.rawMs,1000);
    expect(window.reasons,contains('coverage'));
    expect(result.detection.episodes,isEmpty);
  });
}
