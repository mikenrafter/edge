// Requirements any candidate official file must meet, checked from a read of
// its catalog and counts. P1 uses it to reject a naive copy; P2's mapper output
// and the runtime validator must satisfy it with no violation.
//
// STUB for the red phase: reports nothing.
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

List<PayloadViolation> checkPayload(
  PayloadInventory payload,
  OfficialProfile profile, {
  required SchemaCatalog target,
  required int? expectedPrunedBefore,
}) => const [];
