// WHY: faster native pages must conserve duplicate/NULL keys and attribute
// individual constraint failures. CLAIM(export-linear-pages/export-accounted-data).
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/official_export/worker.dart';
import 'package:openstrap_edge/data/official_export/profile.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../backup/backup_support.dart';
import 'fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'keyset inventory matches ordered full-read hashes across page boundaries',
    () async {
      final env = await BackupEnv.create('official_paging.db');
      final db = await databaseFactory.openDatabase(
        '${env.root.path}/source.db',
      );
      try {
        await db.execute(
          'CREATE TABLE nullable_keys(a TEXT,b INTEGER,value TEXT,__export_cursor TEXT, PRIMARY KEY(a,b))',
        );
        await db.execute('CREATE TABLE heap(value TEXT)');
        await db.execute(
          'CREATE TABLE shadowed(ROWID TEXT,_rowid_ TEXT,oid TEXT,value TEXT)',
        );
        await db.execute(
          'CREATE TABLE no_rowid(a TEXT,b INTEGER,value TEXT, PRIMARY KEY(a,b)) WITHOUT ROWID',
        );
        final batch = db.batch();
        for (var i = 2500; i >= 0; i--) {
          batch.insert('nullable_keys', {
            'a': i < 1500 ? null : 'A',
            'b': i < 1500 ? null : i,
            'value': 'row-$i',
            '__export_cursor': 'preserve-$i',
          });
          batch.insert('heap', {'value': 'duplicate'});
          batch.insert('shadowed', {
            'ROWID': 'same',
            '_rowid_': 'same',
            'oid': 'same',
            'value': 'duplicate',
          });
          batch.insert('no_rowid', {'a': 'A', 'b': i, 'value': 'row-$i'});
        }
        await batch.commit(noResult: true);
        final inv = await inventoryDatabase(db);
        for (final (table, order) in [
          ('nullable_keys', 'a,b,rowid'),
          ('heap', 'rowid'),
          ('shadowed', 'ROWID,_rowid_,oid,value'),
          ('no_rowid', 'a,b'),
        ]) {
          final columns = [
            for (final c in await db.rawQuery('PRAGMA table_info($table)'))
              c['name'] as String,
          ];
          final all = OfficialRows(await db.query(table, orderBy: order));
          final initial = OfficialProfile.hash(jsonEncode([table, columns]));
          final expected = await Isolate.run(
            () => hashOfficialRowsHeavy(
              exportWorkerInputs,
              all,
              columns,
              initial,
            ),
          );
          expect((inv[table] as Map)['rows'], 2501, reason: table);
          expect((inv[table] as Map)['sha256'], expected, reason: table);
        }
      } finally {
        await db.close();
        await env.dispose();
      }
    },
  );

  test(
    'page batch retains valid rows around rejected rows and reports each rejection',
    () async {
      final env = await BackupEnv.create('official_batch.db');
      final db = await databaseFactory.openDatabase(
        '${env.root.path}/source.db',
      );
      try {
        await db.execute(
          'CREATE TABLE journal(date TEXT PRIMARY KEY,tags_json TEXT,note TEXT,updated_at INTEGER)',
        );
        final batch = db.batch();
        for (var i = 0; i < 2100; i++) {
          batch.insert('journal', {
            'date': 'day-${i.toString().padLeft(4, '0')}',
            'tags_json': '[]',
            'note': i % 500 == 0 ? null : 'keep-$i',
            'updated_at': i,
          });
        }
        await batch.commit(noResult: true);
        final out = '${env.root.path}/official.db';
        final report = await mapOfficialSnapshot(
          db.path,
          out,
          await File('assets/official_export/v0.11.3.json').readAsString(),
        );
        final target = await databaseFactory.openDatabase(out);
        try {
          final rows = await target.query('journal', orderBy: 'date');
          expect(rows, hasLength(2095));
          expect(rows.first['note'], 'keep-1');
          expect(rows.last['note'], 'keep-2099');
          final skips = report.skipped
              .where((s) => s.table == 'journal')
              .toList();
          expect(skips, hasLength(5));
          expect(skips.map((s) => s.identity).toSet(), {
            for (final i in [0, 500, 1000, 1500, 2000])
              jsonEncode({'date': 'day-${i.toString().padLeft(4, '0')}'}),
          });
          expect(
            skips.every(
              (s) =>
                  s.rows == 1 &&
                  s.reason.startsWith('Target constraints rejected row'),
            ),
            isTrue,
          );
        } finally {
          await target.close();
        }
      } finally {
        await db.close();
        await env.dispose();
      }
    },
  );
  test(
    'activity page worker preserves row correspondence across valid skipped and malformed decisions',
    () async {
      final env = await BackupEnv.create('official_activity_pages.db');
      try {
        final db = await LocalDb.instance;
        final batch = db.batch();
        for (var i = 0; i < 2100; i++) {
          batch.insert('activity_suggestions', {
            ...officialFixtureRows()['activity_suggestions']!,
            'id': 'activity-${i.toString().padLeft(4, '0')}',
            'kind': i % 3 == 0 ? 'meal' : 'workout',
            'details_json': i % 3 == 2
                ? '{'
                : jsonEncode({'sport': 'sport-$i', 'score': 98765}),
          });
        }
        await batch.commit(noResult: true);
        final source = await LocalDb.exportCopy();
        final out = '${env.root.path}/official.db';
        final report = await mapOfficialSnapshot(
          source,
          out,
          await File('assets/official_export/v0.11.3.json').readAsString(),
        );
        final target = await databaseFactory.openDatabase(out);
        try {
          final rows = await target.query(
            'activity_suggestions',
            orderBy: 'id',
          );
          expect(rows, hasLength(700));
          for (var i = 0; i < 700; i++) {
            final original = 3 * i + 1;
            expect(
              rows[i]['id'],
              'activity-${original.toString().padLeft(4, '0')}',
            );
            expect(
              rows[i]['details_json'],
              jsonEncode({'sport': 'sport-$original'}),
            );
          }
          final rejected = report.skipped.where(
            (s) => s.table == 'activity_suggestions' && s.columns.isEmpty,
          );
          expect(rejected, hasLength(1400));
          expect(
            rejected.where(
              (s) => s.reason == 'Activity decision JSON is unreadable',
            ),
            hasLength(700),
          );
        } finally {
          await target.close();
          await File(source).delete();
        }
      } finally {
        await env.dispose();
      }
    },
  );
}
