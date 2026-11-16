// WHY: CLAIM(sleep-summary-included-time). The update stamp comes from the
// served row's recording edge, never its computation time or a newer attempt.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'support/last_result_db.dart';

const dbName = 'sleep_summary_recordings_through_test.db';
const day = '2026-11-14';
final included = DateTime(2026, 11, 15, 5, 5);
final computed = DateTime(2026, 11, 16, 8, 42);
Future<void> seed({bool edge = true}) async {
  await LocalDb.putDayResult(dayId: day, algoVersion: kAlgoVersion,
    payloadJson: jsonEncode({'date': day, if (edge) 'data_edge_sec': included.millisecondsSinceEpoch ~/ 1000,
      'sleep_source': 'auto', 'sleep': {
        'accounting': {'value': {'tst_sec': 34320, 'efficiency_pct': 100}},
        'window': {'value': {'spt_sec': 34560,
          'onset_ms': DateTime(2026, 11, 14, 6, 39, 55).millisecondsSinceEpoch,
          'wake_ms': DateTime(2026, 11, 14, 16, 15, 55).millisecondsSinceEpoch}},
      }}), windowJson: '{}');
  final db = await LocalDb.instance;
  await db.update('day_result', {'computed_at': computed.millisecondsSinceEpoch}, where: 'day_id = ?', whereArgs: [day]);
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; });
  setUp(() => g1FreshDb(dbName));
  tearDownAll(() => g1DropDb(dbName));
  test('R2 served sleep metadata uses the selected included recording', () async {
    // catches: using the attempted day fingerprint or another day's source.
    await seed();
    final sec = included.millisecondsSinceEpoch ~/ 1000;
    await LocalDb.putDerivedFingerprint(day, kAlgoVersion, '${sec + 3600}:120:7');
    await LocalDb.putDerivedFingerprint('2026-11-15', kAlgoVersion, '${sec + 86400}:120:7');
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    final db = await LocalDb.instance;
    final before = await db.query('day_result');
    final night = await repo.getDaySleepV2(day);
    expect(night['recordings_through'], included.millisecondsSinceEpoch);
    expect(night['computed_at'], computed.millisecondsSinceEpoch);
    expect(await db.query('day_result'), before, reason: 'summary read preserves stored result');
  });
  test('R2 missing input stamp never falls back to computation, window end or fingerprint', () async {
    await seed(edge: false);
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    expect((await repo.getDaySleepV2(day))['recordings_through'], isNull);
    await LocalDb.putDerivedFingerprint(day, kAlgoVersion,
      '${included.millisecondsSinceEpoch ~/ 1000}:120:7');
    expect((await repo.getDaySleepV2(day))['recordings_through'], isNull);
  });
}
