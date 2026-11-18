// Upgrades a DISPOSABLE COPY of the owner's uploaded database through the fork's
// real migrations and open repair, then builds the two candidate files the
// receiver probe imports. Copied to owner_upgrade_test.dart by
// harness/run_owner_harness.sh and run ONLY on a Boat sandbox I own.
//
// The original is hashed before and after and never opened for writing: only the
// copy is. The owner's data stays on Boat and the owner's machine.
//
// Env: OWNER_ORIGINAL (path), OWNER_WORK (dir for the copy and candidates),
//      OFFICIAL_PROBE_OUT (report directory).
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/official_export/profile_tables.dart';
import 'package:openstrap_edge/data/official_export/schema_catalog.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/official_export/payload_requirements.dart';
import 'support.dart';
import 'conservation.dart';

Future<String> _sha(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

Future<Map<String, int>> _counts(Database db) async {
  final out = <String, int>{};
  final catalog = await SchemaCatalog.read(db);
  for (final name in catalog.tables.keys) {
    out[name] = Sqflite.firstIntValue(
          await db.rawQuery('SELECT count(*) FROM "${name.replaceAll('"', '""')}"'),
        ) ??
        0;
  }
  return out;
}

void reportZone() {
  expect(DateTime(2026, 7, 1).timeZoneOffset.inHours, -6, reason: 'owner-shaped Denver process zone');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('upgrade a disposable copy of the owner database', () async {
    final original = Platform.environment['OWNER_ORIGINAL']!;
    final work = Directory(Platform.environment['OWNER_WORK']!)..createSync(recursive: true);
    final out = Directory(Platform.environment['OFFICIAL_PROBE_OUT'] ?? 'build/official_probe')
      ..createSync(recursive: true);
    reportZone();
    final report = <String, Object?>{
      'fork_head': Platform.environment['OFFICIAL_FORK_HEAD'],
      'fork_status_porcelain': Platform.environment['OFFICIAL_FORK_STATUS'],
    };
    final watch = Stopwatch()..start();
    void lap(String what) {
      report['t:$what'] = watch.elapsedMilliseconds;
      // Phase timing also makes a long archive expansion observable without
      // logging source values while the final report is still being built.
      // ignore: avoid_print
      print('P2 owner phase $what: ${watch.elapsedMilliseconds} ms');
      watch.reset();
    }

    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    PathProviderPlatform.instance = TempPaths(work.path);

    final shaBefore = await _sha(original);
    lap('sha');
    final copy = '${work.path}/upgraded.db';
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final f = File('$copy$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    File(original).copySync(copy);
    lap('copy');
    report['original'] = {'path': 'owner export', 'bytes': File(original).lengthSync(), 'sha256': shaBefore};

    final pre = await databaseFactoryFfi.openDatabase(copy, options: OpenDatabaseOptions(readOnly: true));
    final preCounts = await _counts(pre);
    report['before'] = {
      'user_version': Sqflite.firstIntValue(await pre.rawQuery('PRAGMA user_version')),
      'integrity': (await pre.rawQuery('PRAGMA integrity_check')).single.values.single,
      'tables': preCounts.length,
    };
    expect((report['before'] as Map)['user_version'],89);
    await pre.close();
    lap('before');

    LocalDb.dbName = copy;
    final db = await LocalDb.instance;
    lap('upgrade_open');
    report['rebuild'] = LocalDb.lastRebuild?.toString();
    expect(LocalDb.lastRebuild,isNull,reason:'the real source must migrate without quarantine/rebuild');
    final postCatalog = await SchemaCatalog.read(db);
    final postCounts = await _counts(db);
    final gaps = officialProfile.coverage(postCatalog);
    report['after'] = {
      'user_version': Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version')),
      'schemaVersion': LocalDb.schemaVersion,
      'integrity': (await db.rawQuery('PRAGMA integrity_check')).single.values.single,
      'tables': postCounts.length,
      'profile_gaps': [for (final g in gaps) g.text],
    };
    expect((report['after'] as Map)['user_version'],LocalDb.schemaVersion);
    report['row_counts'] = {
      for (final e in postCounts.entries) e.key: {'before': preCounts[e.key], 'after': e.value},
      for (final e in preCounts.entries)
        if (!postCounts.containsKey(e.key)) e.key: {'before': e.value, 'after': null},
    };
    lap('after');


    await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    await LocalDb.close();
    lap('close');

    final mappedReport = await mapOfficialSnapshot(snapshotPath: copy,
        outputPath: '${work.path}/policy.db', factory: databaseFactoryFfi);
    final mapped = await databaseFactoryFfi.openDatabase(mappedReport.path,
        options: OpenDatabaseOptions(readOnly: true));
    try {
      final inventory = await PayloadInventory.read(mapped);
      final violations = checkPayload(inventory, officialProfile,
          target: loadCapture('target_schema_62.json'),
          expectedPrunedBefore: mappedReport.cursor.sec);
      expect(violations, isEmpty);
      report['payload_violations'] = [for (final v in violations) v.toString()];
      report['cursor'] = {'oldest_exact_sec': await oldestMappedExactSec(mapped),
        'carried': mappedReport.cursor.sec, 'reason': mappedReport.cursor.reason.name};
      report['mapping_counts'] = mappedReport.targetCounts;
      report['mapping_tables'] = mappedReport.tables;
      expect(inventory.rowCounts['day_result'], 0);
      expect(inventory.rowCounts['day_checkpoint'], 0);
    } finally { await mapped.close(); }
    lap('production_mapper');
    await verifyConservation(copy,mappedReport);
    report['source_value_conservation']='passed';
    lap('conservation_oracle');

    final shaAfter = await _sha(original);
    report['original_unchanged'] = shaAfter == shaBefore;
    report['candidates'] = {
      for (final n in ['upgraded', 'policy']) n: File('${work.path}/$n.db').lengthSync(),
    };
    File('${out.path}/owner-upgrade.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    expect(shaAfter, shaBefore);
    expect((report['after'] as Map)['integrity'], 'ok');
  }, timeout: const Timeout(Duration(minutes: 40)));
}
