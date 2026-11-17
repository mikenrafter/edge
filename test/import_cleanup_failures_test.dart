// WHY: a partial restore failure must survive cleanup, and a cleanup failure
// after a successful copy must never be presented as a successful import.
// CLAIM(restore-cleanup): every cleanup is attempted; first copy error wins.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/src/mixin/factory.dart'
    show buildDatabaseFactory, SqfliteInvokeHandler;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late String source;
  var failDrop = false, failCopy = false, copyFailed = false, failClose = false;
  final calls = <String>[];
  final readers = <int>{}, closed = <int>{};

  setUpAll(() {
    sqfliteFfiInit();
    final native = databaseFactoryFfi as SqfliteInvokeHandler;
    databaseFactory = buildDatabaseFactory(invokeMethod: (method, [args]) async {
      final sql = args is Map ? args['sql'] : null;
      if (sql is String) calls.add(sql);
      if (failCopy && sql is String &&
          sql.startsWith('INSERT OR REPLACE INTO main."decoded_onehz"')) {
        failCopy = false;
        copyFailed = true;
        return native.invokeMethod<Object?>(method,
            {...args as Map, 'sql': 'INSERT INTO missing_copy_table VALUES (1)'});
      }
      if (failDrop && sql == 'DROP TABLE IF EXISTS temp._restore_protected_day_results') {
        failDrop = false;
        return native.invokeMethod<Object?>(method,
            {...args as Map, 'sql': 'DROP TABLE missing_cleanup_table'});
      }
      final result = await native.invokeMethod<Object?>(method, args);
      if (method == 'openDatabase' && args is Map && args['readOnly'] == true && result is Map) {
        readers.add(result['id'] as int);
      }
      if (method == 'closeDatabase' && args is Map) {
        final id = args['id'] as int;
        closed.add(id);
        if (failClose && copyFailed && readers.contains(id)) {
          failClose = false;
          throw StateError('source close failed after its native handle closed');
        }
      }
      return result;
    });
  });

  setUp(() async {
    failDrop = failCopy = copyFailed = failClose = false;
    calls.clear(); readers.clear(); closed.clear();
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('restore_cleanup_');
    LocalDb.dbName = p.join(temp.path, 'destination.db');
    await LocalDb.instance;
    source = p.join(temp.path, 'source.db');
    final src = await databaseFactory.openDatabase(source);
    await src.execute('CREATE TABLE decoded_onehz (rec_ts INTEGER, counter INTEGER, hr INTEGER)');
    await src.insert('decoded_onehz', {'rec_ts': 1790000000, 'counter': 1, 'hr': 65});
    await src.close();
    calls.clear(); readers.clear(); closed.clear();
  });

  tearDown(() async {
    failDrop = failCopy = failClose = false;
    await LocalDb.close();
    await temp.delete(recursive: true);
  });

  test('successful copy reports failed cleanup and still detaches/closes', () async {
    failDrop = true;
    await expectLater(LocalDb.importFromDbFile(source),
        throwsA(isA<DatabaseException>().having((e) => '$e', 'SQL cause', contains('missing_cleanup_table'))));
    expect(failDrop, isFalse, reason: 'the real failing SQL was reached');
    final failure = calls.indexOf('DROP TABLE IF EXISTS temp._restore_protected_day_results');
    expect(calls.indexOf('DROP TABLE IF EXISTS temp._restore_rr_carried'), greaterThan(failure));
    expect(calls.indexOf('DETACH DATABASE imp'), greaterThan(failure));
    expect(readers, isNotEmpty);
    expect(closed, containsAll(readers));
    final db = await LocalDb.instance;
    expect(await db.rawQuery('SELECT rec_ts FROM decoded_onehz'), hasLength(1),
        reason: 'cleanup failure does not undo an already committed page');
    expect((await db.rawQuery('PRAGMA database_list')).any((r) => r['name'] == 'imp'), isFalse);
  });

  test('copy error wins over a later source-close error', () async {
    failCopy = failClose = true;
    await expectLater(LocalDb.importFromDbFile(source),
        throwsA(isA<DatabaseException>().having((e) => '$e', 'original SQL cause', contains('missing_copy_table'))));
    expect(copyFailed, isTrue);
    expect(failClose, isFalse, reason: 'source close was also attempted');
    expect(closed, containsAll(readers));
    expect((await (await LocalDb.instance).rawQuery('PRAGMA database_list'))
        .any((r) => r['name'] == 'imp'), isFalse);
  });
}
