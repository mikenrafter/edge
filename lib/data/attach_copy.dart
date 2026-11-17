// Copy a SQLite database into a new file with the SAME schema (tables,
// indexes, views, triggers, sqlite_sequence, user_version), entirely inside
// SQLite: ATTACH the source read side, then INSERT ... SELECT per table, so no
// row passes through Dart. sqflite runs those statements off the UI thread.
//
// Used for the issue report's recent slice, and as the whole-database export
// on SQLite older than 3.27, which has no `VACUUM INTO` (Android 8-10 ship
// the framework SQLite 3.18/3.22, and sqflite uses the framework's).

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
