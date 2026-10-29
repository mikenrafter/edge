// The wake harness provenance record (kind `harness`) is durable: it outlives
// the 14-day diagnostic retention, merges by occurrence + config digest
// (restoring twice = once), rides a selected-day export of its day and is not
// lost behind the recent-trace export's row limit.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/wake/wake_stores.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../backup/backup_support.dart';
import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('wake_harness_prov.db'));
  setUp(() async => env.wipe());
  tearDownAll(() async => env.dispose());

  const trace = DbWakeTraceStore();
  final record = {
    'version': 1,
    'rule': 'hybrid',
    'params': {'rule': 'hybrid', 'hrRiseBpm': 9},
    'effective': {'hrRiseBpm': 9, 'triggerRunSec': 120},
    'digest': 'abc123',
  };
  Future<List<Map<String, Object?>>> harnessRows([int? e]) async =>
      (await LocalDb.wakeTraceRows(e ?? epoch))
          .where((r) => r['kind'] == 'harness')
          .toList();

  test('outlives diagnostic retention 30 days later; plan does not (control)',
      () async {
    await trace.append(row('plan', -40));
    await trace.append(row('harness', -40, record));
    await trace.append(row('plan', 0, {}, epoch + 30 * 86400));
    expect(
      (await LocalDb.wakeTraceRows(epoch)).where((r) => r['kind'] == 'plan'),
      isEmpty,
    );
    expect(await harnessRows(), hasLength(1));
  });

  test('restore merges by occurrence and digest: twice equals once', () async {
    await trace.append(row('harness', -40, record));
    await env.seedData();
    final backup = await LocalDb.exportCopy();
    await env.wipe();
    await LocalDb.importFromDbFile(backup);
    await LocalDb.importFromDbFile(backup);
    expect(await harnessRows(), hasLength(1));
    // The same config recorded locally at another instant (a restart, another
    // device): still one record per occurrence and digest.
    await env.wipe();
    await trace.append(row('harness', -38, record));
    await LocalDb.importFromDbFile(backup);
    final rows = await harnessRows();
    expect(rows, hasLength(1));
    expect(rows.single['at_ms'], atMinute(-38).millisecondsSinceEpoch);
    expect(jsonDecode(rows.single['data_json'] as String)['digest'], 'abc123');
  });

  test('restore into an empty database brings it back', () async {
    await trace.append(row('harness', -40, record));
    await env.seedData();
    final backup = await LocalDb.exportCopy();
    await env.wipe();
    await LocalDb.importFromDbFile(backup);
    expect(await harnessRows(), hasLength(1));
  });

  test('a selected-day export of its day carries it, another day does not',
      () async {
    await trace.append(row('harness', -40, record));
    final dayId = _localDay(alarmAt);
    Future<int> countIn(Set<String> days) async {
      final path = await LocalDb.exportDaysDb(days);
      final copy = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(readOnly: true));
      final rows = await copy.query('wake_trace',
          where: 'kind = ?', whereArgs: ['harness']);
      await copy.close();
      return rows.length;
    }

    expect(await countIn({dayId}), 1);
    expect(
        await countIn({_localDay(alarmAt.add(const Duration(days: 3)))}), 0);
  });

  test('the recent-trace export keeps it behind more than 400 newer rows',
      () async {
    await trace.append(row('harness', -40, record));
    final batch = (await LocalDb.instance).batch();
    for (var i = 1; i <= 420; i++) {
      batch.insert('wake_trace', {
        'wake_epoch': epoch,
        'at_ms': atMinute(-39).millisecondsSinceEpoch + i * 1000,
        'kind': 'natural',
        'data_json': jsonEncode({'reason': 'remNotStable', 'i': i}),
      });
    }
    await batch.commit(noResult: true);
    final recent = await LocalDb.wakeTraceRecent();
    expect(recent.where((r) => r['kind'] == 'harness'), hasLength(1));
    expect(recent.where((r) => r['kind'] == 'natural'), hasLength(400));
  });
}

String _localDay(DateTime t) {
  final l = t.toLocal();
  return '${l.year.toString().padLeft(4, '0')}-'
      '${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
}
