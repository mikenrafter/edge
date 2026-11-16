// WHY: the production exporter must preserve evidence without carrying fork
// scores. Proves CLAIM(export-no-source-write/export-accounted-data).
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/official_export/profile.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../backup/backup_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUp(() async {
    env = await BackupEnv.create('official_export_test.db');
  });
  tearDown(() async {
    await env.dispose();
  });

  // WHY: a workout with no scores has nothing to clear or report as lost.
  // CLAIM(export-accounted-data). catches unconditional score-cleared entries.
  test('workout without scores produces no scores-cleared omission', () async {
    final db = await LocalDb.instance;
    await db.insert('sessions', {
      'id': 'no-scores',
      'start_ts': 100,
      'end_ts': 200,
      'type': 'running',
      'status': 'done',
      'source': 'manual',
      'created_at': 1,
    });
    final source = await LocalDb.exportCopy();
    final report = await mapOfficialSnapshot(
      source,
      '${env.root.path}/official.db',
      await File('assets/official_export/v0.11.3.json').readAsString(),
    );
    expect(
      report.skipped.where(
        (s) => s.table == 'sessions' && s.reason.contains('scores cleared'),
      ),
      isEmpty,
    );
    await File(source).delete();
  });

  // catches: new tables silently dropped by a common-column copier.
  test('every runtime source table and column has a reviewed policy', () async {
    final db = await LocalDb.instance;
    final profile = OfficialProfile.fromJson(
      jsonDecode(
        await File('assets/official_export/v0.11.3.json').readAsString(),
      ),
    );
    final actual = <String, Set<String>>{};
    for (final row in await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT GLOB 'sqlite_*'",
    )) {
      final name = row['name'] as String;
      actual[name] = {
        for (final c in await db.rawQuery('PRAGMA table_info("$name")'))
          c['name'] as String,
      };
    }
    expect(profile.unclassified(actual), isEmpty);
    actual['future_user_notes'] = {'id', 'note'};
    expect(profile.unclassified(actual), contains('future_user_notes'));
    actual['journal']!.add('future_answer');
    expect(profile.unclassified(actual), contains('journal.future_answer'));
  });

  // catches: source writes, score relabeling, unsupported enums copied whole.
  test(
    'preserves journal and raw, skips unknowns with reasons, empties results',
    () async {
      final live = await LocalDb.instance;
      await live.insert('journal', {
        'date': '2026-11-01',
        'tags_json': '[]',
        'note': 'my exact note',
        'updated_at': 123,
      });
      await live.insert('decoded_onehz', {
        'device_id': '',
        'ts_ms': 1790000000000,
        'rec_ts': 1790000000,
        'counter': 7,
        'hr': 63,
        'on_wrist': 1,
      });
      await live.insert('day_result', {
        'day_id': '2026-11-01',
        'algo_version': 113,
        'payload_json': '{"sentinel":98765}',
        'computed_at': 1,
        'finalized': 1,
      });
      await live.execute(
        'CREATE TABLE future_user_notes(id TEXT PRIMARY KEY,note TEXT)',
      );
      await live.insert('future_user_notes', {
        'id': 'keep',
        'note': 'unsupported original',
      });
      await live.execute(
        'CREATE TABLE sqliteX_user_notes(id TEXT PRIMARY KEY,note TEXT)',
      );
      await live.insert('sqliteX_user_notes', {
        'id': 'prefix',
        'note': 'also preserve this',
      });
      final source = await LocalDb.exportCopy();
      final before = sha256
          .convert(await File(source).readAsBytes())
          .toString();
      final dest = '${env.root.path}/official.db';
      final profileText = await File(
        'assets/official_export/v0.11.3.json',
      ).readAsString();
      final report = await mapOfficialSnapshot(source, dest, profileText);
      expect(
        sha256.convert(await File(source).readAsBytes()).toString(),
        before,
      );
      final target = await databaseFactory.openDatabase(
        dest,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      expect(await target.getVersion(), 58);
      expect((await target.query('journal')).single['note'], 'my exact note');
      expect((await target.query('decoded_onehz')).single['hr'], 63);
      expect(await target.query('day_result'), isEmpty);
      expect(
        report.skipped.any(
          (s) =>
              s.table == 'future_user_notes' &&
              s.rows == 1 &&
              s.reason.isNotEmpty,
        ),
        isTrue,
      );
      expect(
        report.skipped.any(
          (s) => s.table == 'sqliteX_user_notes' && s.rows == 1,
        ),
        isTrue,
      );
      await target.close();
      await File(source).delete();
    },
  );
  // WHY: a private-destination seam must never permit overwriting the live DB.
  // CLAIM(export-no-source-write). catches: deleting an existing destination.
  test(
    'snapshot refuses an existing destination including the live database',
    () async {
      await env.seedData();
      final db = await LocalDb.instance;
      final before = await db.query('decoded_onehz');
      await expectLater(
        LocalDb.exportCopy(destinationPath: db.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await db.query('decoded_onehz'), before);
      final existing = File('${env.root.path}/existing.db');
      await existing.writeAsString('keep this file');
      await expectLater(
        LocalDb.exportCopy(destinationPath: existing.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await existing.readAsString(), 'keep this file');
    },
  );

  // WHY: imported vendor workouts own routes without a sessions row.
  // CLAIM(export-accounted-data). catches: treating every route as a manual session child.
  test('vendor workout routes retain their portable imported parent', () async {
    final db = await LocalDb.instance;
    await db.insert('imported_workout', {
      'uuid': 'vendor-parent',
      'start_ts': 100,
      'end_ts': 200,
      'kind': 'running',
      'source': 'health_connect',
    });
    await db.insert('workout_route', {
      'session_id': 'vendor-parent',
      'seq': 0,
      'ts_ms': 150000,
      'lat': 40.25,
      'lng': -105.5,
    });
    final source = await LocalDb.exportCopy();
    final dest = '${env.root.path}/official.db';
    await mapOfficialSnapshot(
      source,
      dest,
      await File('assets/official_export/v0.11.3.json').readAsString(),
    );
    final out = await databaseFactory.openDatabase(
      dest,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    expect((await out.query('workout_route')).single['lat'], 40.25);
    await out.close();
    await File(source).delete();
  });
}
