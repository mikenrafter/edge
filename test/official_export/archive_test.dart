import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/substrate_archive_codec.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/official_export/worker.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../backup/backup_support.dart';
import 'fixture.dart';

Future<void> archive(Database db, {int codec = 1, bool corrupt = false}) async {
  final b = ArchiveBucket(
    (ArchiveTableBuilder()..addRows([
          {
            'device_id': '',
            'ts_ms': fixtureTs * 1000,
            'rec_ts': fixtureTs,
            'counter': 7,
            'hr': 99,
            'device_family': 'gen4',
          },
          {
            'device_id': '',
            'ts_ms': (fixtureTs + 1) * 1000,
            'rec_ts': fixtureTs + 1,
            'counter': 8,
            'hr': 64,
            'device_family': 'gen4',
          },
        ]))
        .build(),
    (ArchiveTableBuilder()..addRows([
          {
            'device_id': '',
            'ts_ms': fixtureTs * 1000,
            'rec_ts': fixtureTs,
            'beat_index': 0,
            'rr_ts_ms': fixtureTs * 1000,
            'rr_ms': 333,
          },
          {
            'device_id': '',
            'ts_ms': (fixtureTs + 1) * 1000,
            'rec_ts': fixtureTs + 1,
            'beat_index': 0,
            'rr_ts_ms': (fixtureTs + 1) * 1000,
            'rr_ms': 940,
          },
        ]))
        .build(),
  );
  final w = SubstrateArchiveCodec.encodeMergeVerify(b);
  await db.insert('substrate_archive', {
    'device_id': '',
    'utc_day': fixtureTs ~/ 86400,
    'codec': codec,
    'from_ts': w.fromTs,
    'to_ts': w.toTs,
    'onehz_rows': 2,
    'rr_rows': 2,
    'raw_bytes': w.rawBytes,
    'fingerprint': w.fingerprint + (corrupt ? 1 : 0),
    'blob': w.blob,
    'created_at': 1,
    'updated_at': 1,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUp(() async {
    env = await BackupEnv.create('official_archive.db');
  });
  tearDown(() async {
    await env.dispose();
  });
  // WHY: the entire live second owns its beat set, even if it is empty.
  // CLAIM(export-input-identity). catches: concatenating old archive RR.
  test(
    'exact archive expands; a live parent with no beats never regains old beats',
    () async {
      final db = await LocalDb.instance;
      await archive(db);
      await db.insert('decoded_onehz', {
        'device_id': '',
        'ts_ms': fixtureTs * 1000,
        'rec_ts': fixtureTs,
        'counter': 7,
        'hr': 63,
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
      expect(
        (await out.query(
          'decoded_onehz',
          orderBy: 'ts_ms',
        )).map((r) => r['hr']).toList(),
        [63, 64],
      );
      expect((await out.query('decoded_rr')).map((r) => r['rr_ms']).toList(), [
        940,
      ]);
      await out.close();
      await File(source).delete();
    },
  );
  // WHY: unreadable evidence must be reported while unrelated user data exports.
  // CLAIM(export-accounted-data). catches: throwing or silently dropping codec.
  for (final corruption in [false, true]) {
    test('unknown/corrupt bucket skips with report ($corruption)', () async {
      final db = await LocalDb.instance;
      await archive(db, codec: corruption ? 1 : 999, corrupt: corruption);
      await db.insert('journal', {
        'date': fixtureDay,
        'note': 'keep me',
        'updated_at': 1,
      });
      final source = await LocalDb.exportCopy();
      final dest = '${env.root.path}/official.db';
      final report = await mapOfficialSnapshot(
        source,
        dest,
        await File('assets/official_export/v0.11.3.json').readAsString(),
      );
      expect(
        report.skipped.any(
          (s) =>
              s.table == 'substrate_archive' &&
              s.reason.contains('codec or corrupt'),
        ),
        isTrue,
      );
      final out = await databaseFactory.openDatabase(
        dest,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      expect((await out.query('journal')).single['note'], 'keep me');
      expect(await out.query('decoded_onehz'), isEmpty);
      await out.close();
      await File(source).delete();
    });
  }
  // WHY: export must never resurrect deleted data through raw or archive replay.
  // CLAIM(export-input-identity). catches: ignoring excluded windows.
  test(
    'deletion window filters archive and forbids original blob replay',
    () async {
      final db = await LocalDb.instance;
      await archive(db);
      await db.insert('compute_freshness', {
        'key': 'redrive_excluded_windows',
        'payload_json': jsonEncode([
          [fixtureTs, fixtureTs + 1],
        ]),
        'updated_at': 1,
      });
      final source = await LocalDb.exportCopy();
      final dest = '${env.root.path}/official.db';
      final report = await mapOfficialSnapshot(
        source,
        dest,
        await File('assets/official_export/v0.11.3.json').readAsString(),
      );
      final out = await databaseFactory.openDatabase(
        dest,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      expect((await out.query('decoded_onehz')).single['hr'], 64);
      expect(await out.query('substrate_archive'), isEmpty);
      expect(
        report.skipped.any((s) => s.reason.contains('deleted data')),
        isTrue,
      );
      await out.close();
      await File(source).delete();
    },
  );
  // WHY: hashes distinguish SQL types and BLOB bytes, including NULL vs zero.
  // CLAIM(export-typed-hash). catches: stringify-all-values checksum.
  test('canonical typed encoding is unambiguous', () {
    expect(canonicalValue(null), 'n');
    expect(canonicalValue(0), 'i0');
    expect(canonicalValue(''), 's');
    expect(canonicalValue(1.0), 'dP/AAAAAAAAA=');
    expect(canonicalValue(Uint8List.fromList([0, 255])), 'bAP8=');
    expect(canonicalValue(-0.0), isNot(canonicalValue(0.0)));
  });
  // WHY: an unknown deletion policy must remain unsafe even if a recognized
  // key appears later. CLAIM(export-input-identity). catches: resetting the latch.
  test(
    'unknown deletion policy cannot be cleared by a later recognized key',
    () async {
      final db = await LocalDb.instance;
      await db.insert('compute_freshness', {
        'key': 'future_deletion_policy',
        'payload_json': '{}',
        'updated_at': 1,
      });
      await db.insert('compute_freshness', {
        'key': 'redrive_excluded_windows',
        'payload_json': '[]',
        'updated_at': 2,
      });
      await db.insert('decoded_onehz', {
        'device_id': '',
        'ts_ms': fixtureTs * 1000,
        'rec_ts': fixtureTs,
        'counter': 7,
        'hr': 63,
      });
      await db.insert('journal', {
        'date': fixtureDay,
        'note': 'keep this edit',
        'updated_at': 1,
      });
      final source = await LocalDb.exportCopy();
      final dest = '${env.root.path}/official.db';
      final report = await mapOfficialSnapshot(
        source,
        dest,
        await File('assets/official_export/v0.11.3.json').readAsString(),
      );
      final out = await databaseFactory.openDatabase(
        dest,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      expect(await out.query('decoded_onehz'), isEmpty);
      expect((await out.query('journal')).single['note'], 'keep this edit');
      expect(
        report.skipped.any(
          (s) => s.table == 'decoded_onehz' && s.reason.contains('Deletion'),
        ),
        isTrue,
      );
      await out.close();
      await File(source).delete();
    },
  );
  // WHY: two exact buckets with incompatible claims have no safe winner.
  // CLAIM(export-input-identity). catches: silently accepting the first bucket.
  test(
    'conflicting archive seconds are withheld while the rest exports',
    () async {
      final db = await LocalDb.instance;
      await archive(db);
      final conflicting = ArchiveBucket(
        (ArchiveTableBuilder()..addRows([
              {
                'device_id': '',
                'ts_ms': fixtureTs * 1000,
                'rec_ts': fixtureTs,
                'counter': 7,
                'hr': 77,
                'device_family': 'gen4',
              },
            ]))
            .build(),
        ArchiveTable.empty,
      );
      final w = SubstrateArchiveCodec.encodeMergeVerify(conflicting);
      await db.insert('substrate_archive', {
        'device_id': '',
        'utc_day': fixtureTs ~/ 86400 + 1,
        'codec': 1,
        'from_ts': w.fromTs,
        'to_ts': w.toTs,
        'onehz_rows': 1,
        'rr_rows': 0,
        'raw_bytes': w.rawBytes,
        'fingerprint': w.fingerprint,
        'blob': w.blob,
        'created_at': 1,
        'updated_at': 1,
      });
      final source = await LocalDb.exportCopy();
      final dest = '${env.root.path}/official.db';
      final report = await mapOfficialSnapshot(
        source,
        dest,
        await File('assets/official_export/v0.11.3.json').readAsString(),
      );
      final out = await databaseFactory.openDatabase(
        dest,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      expect((await out.query('decoded_onehz')).map((r) => r['hr']).toList(), [
        64,
      ]);
      expect((await out.query('decoded_rr')).map((r) => r['rr_ms']).toList(), [
        940,
      ]);
      expect(await out.query('substrate_archive'), isEmpty);
      expect(
        report.skipped.any((s) => s.reason.contains('Conflicting')),
        isTrue,
      );
      await out.close();
      await File(source).delete();
    },
  );

  // WHY: interval inputs can overlap a deleted window even if they start
  // earlier; observations carry milliseconds, not seconds. CLAIM(export-input-identity).
  test(
    'deletion policy filters overlapping intervals and millisecond observations',
    () async {
      final db = await LocalDb.instance;
      await db.insert('compute_freshness', {
        'key': 'redrive_excluded_windows',
        'payload_json': '[[100,200]]',
        'updated_at': 1,
      });
      await db.insert('live_coverage', {
        'start_ts': 90,
        'end_ts': 110,
        'steps': 10,
        'day': fixtureDay,
        'source': 'live',
        'device_id': '',
      });
      for (final ts in [150000, 250000]) {
        await db.insert('observation', {
          'device_id': 'vendor',
          'ts_ms': ts,
          'date': fixtureDay,
          'source_kind': 'vendor',
          'key': 'weight',
          'value': 72.5,
          'unit': 'kg',
          'attribution': 'vendor',
        });
      }
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
      expect(await out.query('live_coverage'), isEmpty);
      expect((await out.query('observation')).single['ts_ms'], 250000);
      await out.close();
      await File(source).delete();
    },
  );
  // WHY: archive metadata additions must not abort unrelated export.
  // CLAIM(export-accounted-data). catches: inserting an unprojected archive row.
  test('unknown archive metadata columns are skipped and listed', () async {
    final db = await LocalDb.instance;
    await archive(db);
    await db.execute(
      'ALTER TABLE substrate_archive ADD COLUMN future_metadata TEXT',
    );
    await db.update('substrate_archive', {
      'future_metadata': 'keep in recovery',
    });
    final source = await LocalDb.exportCopy();
    final dest = '${env.root.path}/official.db';
    final report = await mapOfficialSnapshot(
      source,
      dest,
      await File('assets/official_export/v0.11.3.json').readAsString(),
    );
    final out = await databaseFactory.openDatabase(
      dest,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    expect(await out.query('decoded_onehz'), hasLength(2));
    expect(await out.query('substrate_archive'), hasLength(1));
    expect(
      report.skipped.any(
        (s) =>
            s.table == 'substrate_archive' &&
            s.columns.contains('future_metadata'),
      ),
      isTrue,
    );
    await out.close();
    await File(source).delete();
  });
}
