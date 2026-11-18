// Copy a SQLite database into a new file with the SAME schema (tables,
// indexes, views, triggers, sqlite_sequence, user_version), entirely inside
// SQLite: ATTACH the source read side, then INSERT ... SELECT per table, so no
// row passes through Dart. sqflite runs those statements off the UI thread.
//
// Used for the issue report's recent slice, and as the whole-database export
// on SQLite older than 3.27, which has no `VACUUM INTO` (Android 8-10 ship
// the framework SQLite 3.18/3.22, and sqflite uses the framework's).

import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'db.dart' show LocalDb;

/// Rows of [table] to copy: '' = every row, a ' WHERE ...' clause = those
/// rows, null = none (the table itself is still created). The source is
/// attached as `src`.
typedef AttachCopyWhere = Future<String?> Function(
    DatabaseExecutor db, String table);

/// A file-to-file copy request; this never targets the live store.
class AttachedCopy {
  const AttachedCopy(this.srcPath, this.dest, this.whereFor);
  final String srcPath;
  final String dest;
  final AttachCopyWhere whereFor;
}

/// File-copy compatibility seam used by whole exports and recent slices.
Future<void> attachCopy(String srcPath, String dest, AttachCopyWhere whereFor) async {
  await LocalDb.exportCopy(attached: AttachedCopy(srcPath, dest, whereFor));
}

/// Capability for SQL in a newly created private export file. Its constructor
/// cannot wrap LocalDb.instance or any existing file. Dynamic writes remain
/// owned by LocalDb.exportCopy, the same seam as AttachedCopy.
class PrivateExportFile {
  PrivateExportFile._(this.read, this.factory);
  final Database read;
  final DatabaseFactory factory;
  String get path => read.path;

  static Future<PrivateExportFile> create(String path, {DatabaseFactory? factory}) async {
    final backend = factory ?? databaseFactory;
    await File(path).create(exclusive: true);
    try {
      final db = await backend.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
      return PrivateExportFile._(db, backend);
    } catch (_) {
      await backend.deleteDatabase(path);
      rethrow;
    }
  }

  Future<void> applySql(String sql, [List<Object?> arguments = const []]) async {
    await LocalDb.exportCopy(privateWrite: ExportFileWrite(this, [ExportFileStatement(sql, arguments)]));
  }

  Future<void> writeRow(String table, Map<String,Object?> row) async {
    final pending = beginBatch()..writeRow(table,row);
    await pending.flush();
  }

  PrivateExportBatch beginBatch() => PrivateExportBatch(this);
  Future<void> close() => read.close();
  Future<void> discard() => factory.deleteDatabase(path);
}

class ExportFileStatement {
  const ExportFileStatement(this.sql,this.arguments);
  final String sql;
  final List<Object?> arguments;
}

/// One queued native batch. This can name only the private file capability.
class ExportFileWrite {
  const ExportFileWrite(this.file,this.statements);
  final PrivateExportFile file;
  final List<ExportFileStatement> statements;
}

class PrivateExportBatch {
  PrivateExportBatch(this.file);
  final PrivateExportFile file;
  final List<ExportFileStatement> _statements=[];
  void writeRow(String table,Map<String,Object?> row) {
    String quote(String s) => '"${s.replaceAll('"','""')}"';
    _statements.add(ExportFileStatement(
      'INSERT INTO ${quote(table)} (${row.keys.map(quote).join(',')}) VALUES (${List.filled(row.length,'?').join(',')})',
      row.values.toList()));
  }
  Future<void> flush() async {
    await LocalDb.exportCopy(privateWrite: ExportFileWrite(file,List.unmodifiable(_statements)));
    _statements.clear();
  }
}
