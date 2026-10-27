import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../tool/sleep_hmm_compare.dart' as tool;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'stored comparison uses both real workers and leaves stored output intact',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      const start = 1782532800;
      const day = '2026-06-27';
      try {
        await db.execute(
          'CREATE TABLE day_result (day_id TEXT, algo_version INT, '
          'skipped INT, window_json TEXT)',
        );
        await db.execute(
          'CREATE TABLE decoded_onehz (device_id TEXT, ts_ms INT, '
          'rec_ts INT, counter INT, hr INT, ax REAL, ay REAL, az REAL, device_family TEXT)',
        );
        await db.execute(
          'CREATE TABLE decoded_rr (device_id TEXT, ts_ms INT, '
          'rec_ts INT, beat_index INT, rr_ts_ms INT, rr_ms INT)',
        );
        await db.insert('day_result', {
          'day_id': day,
          'algo_version': 116,
          'skipped': 0,
          'window_json': jsonEncode({
            'onset_ms': start * 1000,
            'offset_ms': (start + 600) * 1000,
          }),
        });
        final batch = db.batch();
        for (var i = 0; i < 600; i++) {
          batch.insert('decoded_onehz', {
            'device_id': 'band',
            'ts_ms': (start + i) * 1000,
            'rec_ts': start + i,
            'counter': i,
            'hr': 60,
            'ax': 0,
            'ay': 0,
            'az': 1,
            'device_family': 'gen4',
          });
          batch.insert('decoded_rr', {
            'device_id': 'band',
            'ts_ms': (start + i) * 1000,
            'rec_ts': start + i,
            'beat_index': 0,
            'rr_ts_ms': (start + i) * 1000,
            'rr_ms': i.isEven ? 1000 : 1100,
          });
        }
        await batch.commit(noResult: true);
        final before = await db.query('day_result');
        final result = await tool.compareStoredSleepNights(
          db,
          days: [day],
          deviceId: 'band',
        );
        expect(result, hasLength(1));
        final methods = result.single['comparison'] as Map;
        expect(methods.keys, ['cardio', 'hmm628']);
        for (final method in methods.keys) {
          final measured = methods[method] as Map;
          expect(measured['staging_method'], method);
          expect(measured['hr_min_night'], 60);
          expect(measured['rmssd_mean_night'], closeTo(100, 1e-9));
          expect(
            (measured['stage_seconds'] as Map).values.fold<int>(
              0,
              (sum, v) => sum + (v as int),
            ),
            600,
          );
        }
        expect(await db.query('day_result'), before);
        // A different device cannot borrow this band's measurements.
        final missing = await tool.compareStoredSleepNights(db, days: [day]);
        expect(missing.single['skipped'], contains('no retained decoded'));
        expect(missing.single.containsKey('comparison'), isFalse);
      } finally {
        await db.close();
      }
    },
  );
}
