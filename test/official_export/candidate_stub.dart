// Candidate official files built in TEST code, only to exercise the
// requirements checker and the receiver harness before the real mapper exists
// (P2 replaces both with the production mapper's output).
//
// `naiveCopyCandidate` is the baseline the spec says must fail: the fork's rows
// copied into the target layout wherever a table and column name match, with no
// policy applied. `policyCandidate` is the positive control: it follows the
// profile's table policies and the carried-cursor rule, nothing more.
import 'dart:io';

import 'package:openstrap_edge/data/official_export/profile.dart';
import 'package:openstrap_edge/data/official_export/profile_target.dart';
import 'package:openstrap_edge/data/official_export/profile_tables.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'rich_fixture.dart';

Future<Database> _createTargetShaped(String path, {int userVersion = 62}) async {
  await databaseFactoryFfi.deleteDatabase(path);
  final db = await databaseFactoryFfi.openDatabase(path);
  for (final type in const ['table', 'index', 'view', 'trigger']) {
    for (final o in officialTargetObjects.where((o) => o.type == type)) {
      await db.execute(o.sql);
    }
  }
  await db.execute('PRAGMA user_version = $userVersion');
  return db;
}

Future<List<String>> _commonColumns(Database db, String table) async {
  final target = [
    for (final r in await db.rawQuery('PRAGMA main.table_info("$table")')) r['name'] as String,
  ];
  final source = {
    for (final r in await db.rawQuery('PRAGMA src.table_info("$table")')) r['name'] as String,
  };
  return [for (final c in target) if (source.contains(c)) c];
}

Future<String> naiveCopyCandidate(RichFixture fx) async {
  final out = '${File(fx.forkPath).parent.path}/naive.db';
  final db = await _createTargetShaped(out);
  try {
    await db.execute('ATTACH DATABASE ? AS src', [fx.forkPath]);
    final fork = {
      for (final r in await db.rawQuery("SELECT name FROM src.sqlite_master WHERE type='table'"))
        r['name'] as String,
    };
    for (final r in await db.rawQuery("SELECT name FROM main.sqlite_master WHERE type='table'")) {
      final t = r['name'] as String;
      if (!fork.contains(t)) continue;
      final cols = await _commonColumns(db, t);
      if (cols.isEmpty) continue;
      final list = cols.map((c) => '"$c"').join(',');
      await db.execute('INSERT OR REPLACE INTO main."$t"($list) SELECT $list FROM src."$t"');
    }
    await db.execute('DETACH DATABASE src');
  } finally {
    await db.close();
  }
  return out;
}

Future<String> policyCandidate(
  RichFixture fx, {
  int userVersion = 62,
  bool extraTable = false,
  bool dropImported = false,
}) async {
  final out = '${File(fx.forkPath).parent.path}/policy.db';
  final db = await _createTargetShaped(out, userVersion: userVersion);
  try {
    await db.execute('ATTACH DATABASE ? AS src', [fx.forkPath]);
    final fork = {
      for (final r in await db.rawQuery("SELECT name FROM src.sqlite_master WHERE type='table'"))
        r['name'] as String,
    };
    for (final e in officialProfile.tables.entries) {
      final t = e.value;
      if (!t.policy.carriesRows || !fork.contains(e.key)) continue;
      if (e.key.startsWith('raw_archive') && e.key != 'raw_archive_frames') continue;
      if (e.key == 'sync_cursor' || e.key == 'compute_freshness') continue;
      final cols = [
        for (final c in await _commonColumns(db, t.dest!))
          if (t.keep.contains(c) || t.rewrite.contains(c) || t.provenance.contains(c)) c,
      ];
      if (cols.isEmpty) continue;
      final list = cols.map((c) => '"$c"').join(',');
      await db.execute('INSERT OR REPLACE INTO main."${t.dest}"($list) SELECT $list FROM src."${e.key}"');
    }
    await db.execute(
      "INSERT INTO main.sync_cursor(name,value,updated_at) VALUES('decoded_pruned_before','${fx.expectedPrunedBefore}',1)",
    );
    await db.execute(
      "INSERT INTO main.compute_freshness SELECT * FROM src.compute_freshness WHERE key='substrate_archive_policy'",
    );
    await db.execute('DETACH DATABASE src');
    if (extraTable) await db.execute('CREATE TABLE fork_only_table(x INTEGER)');
    if (dropImported) await db.execute('ALTER TABLE day_result DROP COLUMN imported');
  } finally {
    await db.close();
  }
  return out;
}
