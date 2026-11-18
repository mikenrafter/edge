// Sleep structural phase 2, codec/migration: `sleep_override.payload_json`
// arrives through the next additive rung and heals on open.
//
// CLAIM(sleep-editor-transport): the payload travels with its row, so the
// column must exist on fresh, upgraded and same-version-repaired databases,
// and an upgrade must not scan history.
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';

const _name = 'sleep_editor_migration_test.db';

Future<String> _path() async =>
    p.join(await databaseFactory.getDatabasesPath(), _name);

Future<Database> _open() async {
  await LocalDb.close();
  LocalDb.dbName = _name;
  return LocalDb.instance;
}

Future<List<String>> _cols(Database db) async => [
      for (final r in await db.rawQuery('PRAGMA table_info(sleep_override)'))
        r['name'] as String
    ];

/// Tamper a closed store back to what rung 92 left: no payload column.
Future<void> _toV92({int version = 92}) async {
  await LocalDb.close();
  final raw = await databaseFactory.openDatabase(await _path());
  await raw.execute('ALTER TABLE sleep_override DROP COLUMN payload_json');
  await raw.execute('PRAGMA user_version = $version');
  await raw.close();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(await _path());
  });
  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(await _path());
  });

  // WHY: schema 93 is the next free rung; a fork build that forgot the bump
  // would never run the ladder step on existing installs.
  test('the schema version is at least 93', () {
    expect(LocalDb.schemaVersion, greaterThanOrEqualTo(93));
  });

  test('a fresh database has the nullable payload column', () async {
    final db = await _open();
    expect(await _cols(db), contains('payload_json'));
    await db.insert('sleep_override', {
      'day_id': 'd', 'onset_ts': 1, 'offset_ts': 2, 'source': 'manual',
      'created_at': 3,
    });
    expect((await db.query('sleep_override')).single['payload_json'], isNull);
  });

  // WHY: the real upgrade path. Existing rows survive with a NULL payload
  // (history unavailable), and the version lands on the current rung.
  test('an upgrade from 92 adds the column and keeps rows', () async {
    var db = await _open();
    await db.insert('sleep_override', {
      'day_id': '2026-10-12', 'onset_ts': 100, 'offset_ts': 200,
      'source': 'confirmed', 'created_at': 5,
    });
    await _toV92();
    db = await _open();
    expect(await _cols(db), contains('payload_json'));
    final r = (await db.query('sleep_override')).single;
    expect((r['onset_ts'], r['offset_ts'], r['payload_json']), (100, 200, null));
    expect((await db.rawQuery('PRAGMA user_version')).single.values.single,
        LocalDb.schemaVersion);
  });

  // WHY: a merged build at the SAME version can still lack the column; the
  // open-time repair must add it without a version bump.
  test('same-version repair heals a missing column', () async {
    await _open();
    await _toV92(version: LocalDb.schemaVersion);
    final db = await _open();
    expect(await _cols(db), contains('payload_json'));
  });

  // WHY: repeating the open changes nothing and never duplicates the column.
  test('reopening is idempotent', () async {
    await _open();
    final db = await _open();
    expect((await _cols(db)).where((c) => c == 'payload_json'), hasLength(1));
  });
}
