// The import's second connection to the backup file, fenced off from the main
// database's transactions.
//
// OWNER of [_txnDepth]: this guard. The merge opens the backup as a separate
// read-only connection AND ATTACHes the same file to the main connection.
// sqflite's BEGIN IMMEDIATE takes RESERVED on attached files too, so on
// Android a read through the second connection while a main transaction is open
// gets SQLITE_BUSY ("database is locked", retrycount exceeded) after a long
// stall. Desktop sqflite_ffi tolerates it, so tests cannot see it by
// symptom; this guard fails the read by construction instead.

import 'package:sqflite/sqflite.dart';

class ImportSourceGuard implements Database {
  ImportSourceGuard(this._inner);
  final Database _inner;
  int _txnDepth = 0;

  /// Test seam: every source read, with whether a main transaction was open.
  static List<(String op, bool txnOpen)>? debugReads;

  /// Run [body] as a main-database transaction; source reads inside throw.
  Future<T> mainTransaction<T>(
    Database main,
    Future<T> Function(Transaction txn) body,
  ) async {
    _txnDepth++;
    try {
      return await main.transaction(body);
    } finally {
      _txnDepth--;
    }
  }

  void _check(String op) {
    debugReads?.add((op, _txnDepth > 0));
    if (_txnDepth > 0) {
      throw StateError(
        'import source read ($op) inside a main-database transaction: '
        'read it before the transaction opens',
      );
    }
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) {
    _check('rawQuery');
    return _inner.rawQuery(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    _check('query');
    return _inner.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<void> close() => _inner.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'ImportSourceGuard only reads: ${invocation.memberName}',
  );
}
