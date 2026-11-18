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
import 'package:openstrap_edge/data/official_export/prune_cursor.dart';
import 'package:openstrap_edge/data/official_export/schema_catalog.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'candidate_stub.dart';
import 'support.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('upgrade a disposable copy of the owner database', () async {
    final original = Platform.environment['OWNER_ORIGINAL']!;
    final work = Directory(Platform.environment['OWNER_WORK']!)..createSync(recursive: true);
    final out = Directory(Platform.environment['OFFICIAL_PROBE_OUT'] ?? 'build/official_probe')
      ..createSync(recursive: true);
    expect(DateTime.utc(2026, 7, 1).toLocal().timeZoneOffset, Duration.zero, reason: 'harness needs a UTC process zone');
    final report = <String, Object?>{
      'fork_head': Platform.environment['OFFICIAL_FORK_HEAD'],
      'fork_status_porcelain': Platform.environment['OFFICIAL_FORK_STATUS'],
    };
    final watch = Stopwatch()..start();
    void lap(String what) {
      report['t:$what'] = watch.elapsedMilliseconds;
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
    await pre.close();
    lap('before');

    LocalDb.dbName = copy;
    final db = await LocalDb.instance;
    lap('upgrade_open');
    report['rebuild'] = LocalDb.lastRebuild?.toString();
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
    report['row_counts'] = {
      for (final e in postCounts.entries) e.key: {'before': preCounts[e.key], 'after': e.value},
      for (final e in preCounts.entries)
        if (!postCounts.containsKey(e.key)) e.key: {'before': e.value, 'after': null},
    };
    lap('after');

    // Capture the fork cursor now; query exact seconds from the mapped file below.
    final cursorRow = await db.rawQuery("SELECT value FROM sync_cursor WHERE name = 'decoded_pruned_before'");
    final forkCursor = cursorRow.isEmpty ? null : int.tryParse('${cursorRow.single['value']}');
    await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    await LocalDb.close();
    lap('close');

    await naiveCopyFrom(copy, '${work.path}/naive.db');
    lap('naive_candidate');
    final policyPath = await policyFrom(copy, '${work.path}/policy.db', expectedPrunedBefore: null);
    final mapped = await databaseFactoryFfi.openDatabase(policyPath);
    try {
      final oldest = await oldestMappedExactSec(mapped);
      final choice = chooseDecodedPrunedBefore(forkCursorSec: forkCursor, oldestExactSec: oldest);
      report['cursor'] = {
        'fork': forkCursor, 'oldest_exact_sec': oldest,
        'carried': choice.sec, 'reason': choice.reason.name,
      };
      if (choice.sec != null) {
        await mapped.insert('sync_cursor', {
          'name': 'decoded_pruned_before', 'value': '${choice.sec}', 'updated_at': 1,
        });
      }
    } finally {
      await mapped.close();
    }
    lap('policy_candidate');

    final shaAfter = await _sha(original);
    report['original_unchanged'] = shaAfter == shaBefore;
    report['candidates'] = {
      for (final n in ['upgraded', 'naive', 'policy']) n: File('${work.path}/$n.db').lengthSync(),
    };
    File('${out.path}/owner-upgrade.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    expect(shaAfter, shaBefore);
    expect((report['after'] as Map)['integrity'], 'ok');
  }, timeout: const Timeout(Duration(minutes: 40)));
}
