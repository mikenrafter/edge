import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/nap_edits.dart';
import 'package:openstrap_edge/compute/substrate.dart';

final dayStart = DateTime.utc(2026, 10, 1).millisecondsSinceEpoch ~/ 1000;
final noon = dayStart + 12 * 3600;

Substrate fixture({bool missingMotion = false}) {
  const n = 85 * 60;
  return Substrate(tsSec: [for (var i = 0; i < n; i++) noon - 3600 + i],
    hr: [for (var i = 0; i < n; i++) i < 3600 ? 60 : 70],
    rrTsMs: [], rrMs: [], ax: List.filled(n, 0), ay: List.filled(n, 0),
    az: List.filled(n, missingMotion ? 0 : 1), spo2Red: List.filled(n, 0),
    spo2Ir: List.filled(n, 0), skinTemp: List.filled(n, 0),
    skinContact: List.filled(n, 0));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real registered day-block worker proposes meal from substrate minutes', () async {
    final input = DerivationEngine.dayBlocksInputForTest(daySub: fixture(),
        date: '2026-10-01', dayStartSec: dayStart, dataNowSec: dayStart + 86400);
    final dynamic output = await DerivationEngine.runDayBlocksForTest(input);
    final rows = output.mealSuggestions as List;
    expect(rows, hasLength(1));
    expect(rows.single['start_ts'], noon);
    expect(rows.single['end_ts'], noon + 25 * 60);
  });
  for (final exclude in ['motion', 'off_wrist', 'charging', 'nap', 'workout', 'tonight_sleep']) {
    test('day-block worker excludes $exclude from meal candidates', () async {
      final input = DerivationEngine.dayBlocksInputForTest(
          daySub: fixture(missingMotion: exclude == 'motion'),
          date: '2026-10-01', dayStartSec: dayStart, dataNowSec: dayStart + 86400,
          wristOffSpans: exclude == 'off_wrist' ? [[noon, noon + 1800]] : null,
          chargingSpans: exclude == 'charging' ? [[noon, noon + 1800]] : null,
          napEdits: exclude == 'nap' ? [NapEdit(kind: NapEditKind.added,
              startSec: noon, endSec: noon + 1800)] : null,
          savedSessions: exclude == 'workout' ? [{'id':'lunch_walk',
            'start_ts':noon, 'end_ts':noon + 1800, 'type':'walking',
            'status':'done'}] : null,
          tonightSleepOnsetSec: exclude == 'tonight_sleep' ? noon : 0,
          tonightSleepOffsetSec: exclude == 'tonight_sleep' ? noon + 1800 : 0);
      final dynamic output = await DerivationEngine.runDayBlocksForTest(input);
      expect(output.mealSuggestions, isEmpty);
    });
  }
}
