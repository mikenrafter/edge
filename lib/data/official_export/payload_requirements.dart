// Requirements any candidate official file must meet, checked from a read of
// its catalog and counts. P1 uses it to reject a naive copy; P2's mapper output
// and the runtime validator must satisfy it with no violation.
import 'package:sqflite/sqflite.dart';

import 'profile.dart';
import 'schema_catalog.dart';

/// What a candidate file contains, read once.
class PayloadInventory {
  const PayloadInventory({
    required this.userVersion,
    required this.catalog,
    required this.rowCounts,
    required this.syncCursorNames,
    required this.freshnessKeys,
    required this.prunedBefore,
  });

  /// Reads a candidate file once: version, layout, row counts and the two
  /// key-filtered tables. Table names are quoted; the file is not trusted.
  static Future<PayloadInventory> read(Database db) async {
    final catalog = await SchemaCatalog.read(db);
    final counts = <String, int>{};
    for (final name in catalog.tables.keys) {
      final quoted = name.replaceAll('"', '""');
      counts[name] =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT count(*) FROM "$quoted"'),
          ) ??
          0;
    }
    Future<Set<String>> keys(String table, String column) async =>
        catalog.tables.containsKey(table)
        ? {
            for (final r in await db.rawQuery('SELECT "$column" AS k FROM "$table"'))
              '${r['k']}',
          }
        : <String>{};
    int? pruned;
    if (catalog.tables.containsKey('sync_cursor')) {
      final r = await db.rawQuery(
        "SELECT value FROM sync_cursor WHERE name = 'decoded_pruned_before'",
      );
      if (r.isNotEmpty) pruned = int.tryParse('${r.single['value']}');
    }
    return PayloadInventory(
      userVersion: Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version')) ?? 0,
      catalog: catalog,
      rowCounts: counts,
      syncCursorNames: await keys('sync_cursor', 'name'),
      freshnessKeys: await keys('compute_freshness', 'key'),
      prunedBefore: pruned,
    );
  }

  final int userVersion;
  final SchemaCatalog catalog;
  final Map<String, int> rowCounts;
  final Set<String> syncCursorNames, freshnessKeys;
  final int? prunedBefore;
}

/// One broken requirement; [text] names the table or key.
class PayloadViolation {
  const PayloadViolation(this.kind, this.text);
  final String kind, text;
  @override
  String toString() => '$kind: $text';
}

/// Every broken requirement of [payload] against [profile] and the captured
/// [target] layout. Empty means the file may go to the receiver.
///
/// [expectedPrunedBefore] is the carried cursor the exporter computed (null:
/// the fork had none, so no row is expected). Kinds: `userVersion`,
/// `unknownTable`, `layout`, `droppedTableHasRows`, `foreignCursor`,
/// `foreignFreshnessKey`, `prunedBeforeMismatch`, `prunedBeforeUnexpected`,
/// `prunedBeforeInvalid`.
List<PayloadViolation> checkPayload(
  PayloadInventory payload,
  OfficialProfile profile, {
  required SchemaCatalog target,
  required int? expectedPrunedBefore,
}) {
  final out = <PayloadViolation>[];
  if (payload.userVersion != officialTargetSchema) {
    out.add(
      PayloadViolation(
        'userVersion',
        'user_version ${payload.userVersion}, expected $officialTargetSchema',
      ),
    );
  }
  final carrierNames = {for (final c in profile.carriers) c.name};
  for (final name in payload.catalog.tables.keys) {
    if (_platformTables.contains(name)) continue;
    if (!target.tables.containsKey(name) && !carrierNames.contains(name)) {
      out.add(PayloadViolation('unknownTable', name));
    }
  }
  for (final t in target.tables.values) {
    final actual = payload.catalog.tables[t.name];
    if (actual == null) {
      out.add(PayloadViolation('layout', 'missing target table ${t.name}'));
    } else if (!_sameColumns(actual.columns, t.columns)) {
      out.add(
        PayloadViolation(
          'layout',
          '${t.name} column definitions differ: '
          'actual ${[for (final c in actual.columns) (c.name,c.type,c.notNull,c.defaultValue,c.pk)]}; '
          'expected ${[for (final c in t.columns) (c.name,c.type,c.notNull,c.defaultValue,c.pk)]}',
        ),
      );
    }
  }
  final expectedObjects = {
    for (final o in target.objects)
      if (o.type != 'table') (o.type, o.name): (o.table, o.sql),
  };
  final actualObjects = {
    for (final o in payload.catalog.objects) (o.type, o.name): (o.table, o.sql),
  };
  for (final key in {...expectedObjects.keys, ...actualObjects.keys}) {
    if (actualObjects[key] != expectedObjects[key]) {
      out.add(PayloadViolation('layout', '${key.$1} ${key.$2} differs from the tagged release'));
    }
  }
  // A table that carries no rows by policy (R/D) or has no source at all
  // (target-only, such as a receiver cache) must be empty; so must any fork
  // computation sitting in a target table of the same name.
  final carrying = {
    for (final e in profile.tables.entries)
      if (e.value.policy.carriesRows) e.value.dest!,
  };
  for (final e in payload.rowCounts.entries) {
    if (e.value == 0 || _platformTables.contains(e.key)) continue;
    if (!carrying.contains(e.key) && !carrierNames.contains(e.key)) {
      out.add(PayloadViolation('droppedTableHasRows', e.key));
    }
  }
  for (final n in payload.syncCursorNames) {
    if (n != 'decoded_pruned_before') {
      out.add(PayloadViolation('foreignCursor', 'sync_cursor:$n'));
    }
  }
  for (final k in payload.freshnessKeys) {
    if (k != 'substrate_archive_policy') {
      out.add(PayloadViolation('foreignFreshnessKey', 'compute_freshness:$k'));
    }
  }
  final hasCursor = payload.syncCursorNames.contains('decoded_pruned_before');
  if (hasCursor && expectedPrunedBefore == null) {
    out.add(const PayloadViolation('prunedBeforeUnexpected',
        'decoded_pruned_before row present, none expected'));
  }
  if (hasCursor && payload.prunedBefore == null) {
    out.add(const PayloadViolation('prunedBeforeInvalid',
        'decoded_pruned_before value is not an integer'));
  }
  if (payload.prunedBefore != expectedPrunedBefore) {
    out.add(
      PayloadViolation(
        'prunedBeforeMismatch',
        'decoded_pruned_before ${payload.prunedBefore}, expected $expectedPrunedBefore',
      ),
    );
  }
  return out;
}

/// Tables the platform's SQLite adds to every file it opens: Android's
/// SQLiteDatabase creates `android_metadata` (one locale row) in the private
/// target too, so it is neither unknown nor fork data. Every Android SQLite
/// file has it, the official app's own databases included. The source's copy
/// is still dropped by its profile. [android_metadata_test]
const _platformTables = {'android_metadata'};

bool _sameColumns(List<ColumnShape> a, List<ColumnShape> b) =>
    a.length == b.length &&
    Iterable<int>.generate(a.length).every((i) =>
      (a[i].name, a[i].type, a[i].notNull, a[i].defaultValue, a[i].pk) ==
      (b[i].name, b[i].type, b[i].notNull, b[i].defaultValue, b[i].pk));
