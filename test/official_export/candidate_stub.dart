// Candidate official files built in TEST code, only to exercise the
// requirements checker and the receiver harness before the real mapper exists
// (P2 replaces both with the production mapper's output).
//
// `naiveCopyCandidate` is the baseline the spec says must fail: the fork's rows
// copied into the target layout wherever a table and column name match, with no
// policy applied. `policyCandidate` is the positive control: it follows the
// profile's table policies and the carried-cursor rule, nothing more.
import 'dart:io';

import 'package:openstrap_edge/data/official_export/profile_target.dart';
import 'package:openstrap_edge/data/official_export/profile_tables.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'rich_fixture.dart';

Future<Database> _createTargetShaped(String path, {int userVersion = 62}) async {
  await databaseFactoryFfi.deleteDatabase(path);
  final db = await databaseFactoryFfi.openDatabase(path);
  // Tables only: indexes, views and triggers come after the rows, so a target
  // trigger (it maintains the receiver-owned input/session counters) never
  // fires on the copy. The production exporter follows the same order.
  for (final o in officialTargetObjects.where((o) => o.type == 'table')) {
    await db.execute(o.sql);
  }
  await db.execute('PRAGMA user_version = $userVersion');
  return db;
}

Future<void> _finishTargetShaped(Database db) async {
  for (final type in const ['index', 'view', 'trigger']) {
    for (final o in officialTargetObjects.where((o) => o.type == type)) {
      await db.execute(o.sql);
    }
  }
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

Future<String> naiveCopyCandidate(RichFixture fx, {String name = 'naive.db'}) =>
    naiveCopyFrom(fx.forkPath, '${File(fx.forkPath).parent.path}/$name');

/// The naive baseline from any fork database file into [out].
Future<String> naiveCopyFrom(String forkPath, String out) async {
  final db = await _createTargetShaped(out);
  try {
    await db.execute('ATTACH DATABASE ? AS src', [forkPath]);
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
    await _finishTargetShaped(db);
  } finally {
    await db.close();
  }
  return out;
}

Future<String> policyCandidate(
  RichFixture fx, {
  String name = 'policy.db',
  int userVersion = 62,
  bool extraTable = false,
  bool dropImported = false,
  bool withCursor = true,
  bool unitKeyControl = false,
}) => policyFrom(
  fx.forkPath,
  '${File(fx.forkPath).parent.path}/$name',
  expectedPrunedBefore: fx.expectedPrunedBefore,
  userVersion: userVersion,
  extraTable: extraTable,
  dropImported: dropImported,
  withCursor: withCursor,
  unitKeyControl: unitKeyControl,
);

/// The positive control from any fork database file into [out]. The carried
/// cursor is [expectedPrunedBefore] (null: no row).
Future<String> policyFrom(
  String forkPath,
  String out, {
  required int? expectedPrunedBefore,
  int userVersion = 62,
  bool extraTable = false,
  bool dropImported = false,
  bool withCursor = true,
  bool unitKeyControl = false,
}) async {
  final db = await _createTargetShaped(out, userVersion: userVersion);
  try {
    await db.execute('ATTACH DATABASE ? AS src', [forkPath]);
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
      final list = [...cols, ...t.emptyConstants.keys].map((c) => '"$c"').join(',');
      final values = [...cols.map((c) => '"$c"'), ...t.emptyConstants.values].join(',');
      await db.execute('INSERT OR REPLACE INTO main."${t.dest}"($list) SELECT $values FROM src."${e.key}"');
    }
    if (withCursor && expectedPrunedBefore != null) {
      await db.execute(
        "INSERT INTO main.sync_cursor(name,value,updated_at) VALUES('decoded_pruned_before','$expectedPrunedBefore',1)",
      );
    }
    await db.execute(
      "INSERT INTO main.compute_freshness SELECT * FROM src.compute_freshness WHERE key='substrate_archive_policy'",
    );
    await db.execute('DETACH DATABASE src');
    if (unitKeyControl) {
      // Control only: a literal qualified key so the receiver proof is
      // satisfiable. P2 supplies the real injective unit-key encoding.
      await db.execute("UPDATE journal_field_def SET key='custom_caffeine~g' WHERE key='custom_caffeine'");
      await db.execute("UPDATE journal_metric SET field='custom_caffeine~g' WHERE field='custom_caffeine'");
    }
    await _finishTargetShaped(db);
    if (extraTable) await db.execute('CREATE TABLE fork_only_table(x INTEGER)');
    if (dropImported) await db.execute('ALTER TABLE day_result DROP COLUMN imported');
  } finally {
    await db.close();
  }
  return out;
}
