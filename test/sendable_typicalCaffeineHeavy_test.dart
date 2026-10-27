// ignore_for_file: file_names
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/typical_day_source.dart';
import 'package:openstrap_edge/util/worker_init.dart';

void main() {
  test('dose row maps cross worker and produce exact nocturnal residual', () async {
    int ts(int d, int h) => DateTime(2026,10,d,h).millisecondsSinceEpoch ~/ 1000;
    final input = TypicalCaffeineInput([
      {'date':'2026-10-01','sleep':{'wake_ts':ts(1,16),'duration_min':480}},
      {'date':'2026-10-02','sleep':{'onset_ts':ts(2,8),'wake_ts':ts(2,16),
        'duration_min':480,'sol_min':12},'heart':{'resting_hr':55}},
    ], [
      {'date':'2026-10-01','hhmm':'22:00','caffeine_mg':100},
      {'date':'2026-10-02','hhmm':'03:00','caffeine_mg':80},
    ], [
      {'date':'2026-10-01','value':100},
      {'date':'2026-10-02','value':80},
    ], const WorkerInputs(nowEpochMs:0,zoneId:'UTC',localeTag:'en'));
    final result = await Isolate.run(() => typicalCaffeineHeavy(input));
    expect(result.dayCount,1);
    expect(result.latestResidualMg,closeTo(65,1e-9));
    expect(result.pairedCounts['latency'],1);
    expect(result.pairedCounts['rhr'],1);
    expect(result.residualVsLatency,isNull);
  });
}
