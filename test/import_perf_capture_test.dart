import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/dev_log.dart';
import 'support/frozen_day_result_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('journaled fixture import logs one correlated run', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('import-perf-test');
    final old = DevLog.instance;
    DevLog.instance = DevLog(
      baseDir: () async => dir,
      devMode: () async => false,
    );
    try {
      await freshDb('cdg_perf.db');
      final source = await databaseFactory.openDatabase(
        '${dir.path}/source.db',
      );
      await source.execute('CREATE TABLE samples (ts INTEGER, hr INTEGER)');
      await source.insert('samples', {'ts': 1700000000, 'hr': 60});
      await source.execute(
        'CREATE TABLE metric_series (date TEXT, key TEXT, value REAL)',
      );
      await source.insert('metric_series', {
        'date': '2026-07-01',
        'key': 'strain',
        'value': 4.0,
      });
      await source.close();
      await LocalDb.importFromDbFile('${dir.path}/source.db');
      await DevLog.instance.flush();
      final lines = <String>[];
      await for (final file in dir.list(recursive: true)) {
        if (file is File && file.path.endsWith('.log')) {
          lines.addAll(await file.readAsLines());
        }
      }
      final perf = lines.where((s) => s.contains('[import-perf]')).toList();
      expect(perf.where((s) => s.contains('] begin ')), hasLength(1));
      expect(perf.where((s) => s.contains('] attach ')), hasLength(1));
      expect(perf.where((s) => s.contains('] end ')), hasLength(1));
      for (final table in ['samples', 'metric_series']) {
        expect(
          perf.where(
            (s) =>
                s.contains('] table_end ') &&
                s.contains('table=$table ') &&
                s.contains('path=bulk ') &&
                s.contains('rows=1 '),
          ),
          hasLength(1),
        );
      }
      expect(
        perf.map((s) => RegExp(r'run=(\S+)').firstMatch(s)!.group(1)).toSet(),
        hasLength(1),
      );
      expect(perf.every((s) => s.contains('[import]')), isTrue);
    } finally {
      DevLog.instance = old;
      await dropDb();
      await dir.delete(recursive: true);
    }
  });
}
