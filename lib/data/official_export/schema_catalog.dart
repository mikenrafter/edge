// What a SQLite file's tables and columns actually are, parsed once into
// checked types. The same type reads the fork's repaired runtime schema, the
// tagged target's schema and (in P2) the export snapshot, so the coverage gate
// and the runtime inventory cannot disagree about a shape.
import 'package:sqflite/sqflite.dart';

/// One column of one table, from `PRAGMA table_xinfo`.
class ColumnShape {
  const ColumnShape({
    required this.name,
    required this.type,
    required this.notNull,
    required this.defaultValue,
    required this.pk,
    required this.hidden,
  });

  /// Parses one `PRAGMA table_xinfo` row; null when the row is not one.
  static ColumnShape? fromXinfo(Map<String, Object?> row) {
    final name = row['name'];
    final type = row['type'];
    final notNull = row['notnull'];
    final pk = row['pk'];
    final hidden = row['hidden'] ?? 0;
    if (name is! String || type is! String) return null;
    if (notNull is! int || pk is! int || hidden is! int) return null;
    final dflt = row['dflt_value'];
    if (dflt != null && dflt is! String) return null;
    return ColumnShape(
      name: name,
      type: type,
      notNull: notNull == 1,
      defaultValue: dflt as String?,
      pk: pk,
      hidden: hidden,
    );
  }

  final String name, type;
  final bool notNull;
  final String? defaultValue;

  /// 1-based position in the primary key, 0 when not part of it.
  final int pk;

  /// 0 ordinary, 1 hidden virtual-table column, 2/3 generated.
  final int hidden;

  /// A new row may omit this column: it is nullable, defaulted or generated.
  bool get supplyOptional => !notNull || defaultValue != null || hidden >= 2;
}

/// One table with the facts the export policy depends on.
class TableShape {
  TableShape({
    required this.name,
    required this.columns,
    required this.sql,
    required this.indexes,
  });

  final String name;
  final List<ColumnShape> columns;

  /// The CREATE statement, or null for a table SQLite lists without one.
  final String? sql;

  /// `PRAGMA index_list` origin/unique facts: (name, unique, origin).
  final List<({String name, bool unique, String origin})> indexes;

  Set<String> get columnNames => {for (final c in columns) c.name};

  /// A `WITHOUT ROWID` table has no rowid to page by.
  bool get withoutRowid =>
      sql != null &&
      RegExp(r'\)\s*WITHOUT\s+ROWID\s*;?\s*$', caseSensitive: false)
          .hasMatch(sql!.trim());

  bool get virtualTable =>
      sql != null &&
      RegExp(r'^\s*CREATE\s+VIRTUAL\s+TABLE', caseSensitive: false)
          .hasMatch(sql!);

  /// The first rowid alias no column shadows, or null when none is usable.
  /// A column named like an alias takes the name over from the rowid.
  String? get rowidAlias {
    if (withoutRowid || virtualTable) return null;
    final names = {for (final c in columns) c.name.toLowerCase()};
    for (final alias in const ['rowid', '_rowid_', 'oid']) {
      if (!names.contains(alias)) return alias;
    }
    return null;
  }

  /// Columns that are generated or hidden: a plain INSERT cannot supply them.
  List<String> get nonPlainColumns => [
    for (final c in columns)
      if (c.hidden != 0) c.name,
  ];
}

/// Every table of one database file, by name.
class SchemaCatalog {
  SchemaCatalog(this.tables);

  /// Parses the probe's JSON shape (`tables` + `objects`); throws on a
  /// malformed document rather than guessing.
  factory SchemaCatalog.fromProbe(Map<String, Object?> opened) {
    final objects = (opened['objects'] as List).cast<Map>();
    final raw = (opened['tables'] as Map).cast<String, Object?>();
    final sqlByName = {
      for (final o in objects)
        if (o['type'] == 'table') o['name'] as String: o['sql'] as String?,
    };
    final tables = <String, TableShape>{};
    for (final e in raw.entries) {
      final body = (e.value as Map).cast<String, Object?>();
      tables[e.key] = TableShape(
        name: e.key,
        columns: [
          for (final r in (body['columns'] as List))
            ColumnShape.fromXinfo((r as Map).cast<String, Object?>()) ??
                (throw FormatException('bad column in ${e.key}: $r')),
        ],
        sql: sqlByName[e.key],
        indexes: [
          for (final i in (body['indexes'] as List))
            (
              name: (i as Map)['name'] as String,
              unique: i['unique'] == 1,
              origin: '${i['origin']}',
            ),
        ],
      );
    }
    return SchemaCatalog(tables);
  }

  /// Reads a live connection. SQLite's own `sqlite_%` tables are not user data;
  /// a table that merely starts with `sqlite` is, so the match is on `sqlite_`.
  static Future<SchemaCatalog> read(DatabaseExecutor db) async {
    final master = await db.rawQuery(
      "SELECT name, sql FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name",
    );
    final tables = <String, TableShape>{};
    for (final m in master) {
      final name = m['name'] as String;
      final quoted = name.replaceAll('"', '""');
      tables[name] = TableShape(
        name: name,
        columns: [
          for (final r in await db.rawQuery('PRAGMA table_xinfo("$quoted")'))
            ColumnShape.fromXinfo(r) ??
                (throw FormatException('bad column in $name: $r')),
        ],
        sql: m['sql'] as String?,
        indexes: [
          for (final i in await db.rawQuery('PRAGMA index_list("$quoted")'))
            (
              name: i['name'] as String,
              unique: i['unique'] == 1,
              origin: '${i['origin']}',
            ),
        ],
      );
    }
    return SchemaCatalog(tables);
  }

  final Map<String, TableShape> tables;
}
