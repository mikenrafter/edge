import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/official_export/coordinator.dart';
import 'package:openstrap_edge/data/official_export/destination.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import 'package:openstrap_edge/data/official_export/snapshot.dart';
import 'package:openstrap_edge/import/backup_crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../backup/backup_support.dart';
import 'fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'production exporter accounts for every imported table and produces official-parser fixtures',
    () async {
      // WHY: literal expected input checks both loss and fabricated metric leakage;
      // file hashes catch writes to the live DB, prefs and attachments.
      // CLAIM(export-accounted-data/export-no-source-write/export-no-fork-results).
      // catches: dropping any table, copying all activity kinds, stamping scores.
      final env = await BackupEnv.create('official_roundtrip.db');
      try {
        await setPrefs({
          'profile.height_cm': 173.5,
          'profile.weight_kg': 72.5,
          'unit_system': 'metric',
          'coach_api_key_present': true,
          'paired_remote_id': 'private-pairing',
        });
        await env.writeImu('recording-A.jsonl', [
          123,
          34,
          120,
          34,
          58,
          49,
          125,
          10,
        ]);
        final live = await LocalDb.instance;
        await seedOfficialFixture(live);
        await live.rawQuery('PRAGMA wal_checkpoint(FULL)');
        final liveBefore = sha256
            .convert(await File(live.path).readAsBytes())
            .toString();
        final prefsBefore = await allPrefs();
        final attachmentBefore = await env
            .imuFile('recording-A.jsonl')
            .readAsBytes();
        final artifact = await Directory(
          'build/official_probe/completed',
        ).create(recursive: true);
        for (final f in artifact.listSync()) {
          if (f is File) {
            await f.delete();
          }
        }
        final private = await Directory('${env.root.path}/private').create();
        final result = await OfficialExportCoordinator().export(
          snapshot: captureStrictOfficialSnapshot,
          privateRoot: private,
          destination: LocalOfficialDestination(artifact),
          passphrase: 'official pilot fixture passphrase',
          profileText: await File(
            'assets/official_export/v0.11.3.json',
          ).readAsString(),
          askRecovery: () async => true,
        );
        expect(
          result,
          isA<OfficialExportSaved>(),
          reason: result is OfficialExportFailed ? result.reason : '',
        );
        final saved = result as OfficialExportSaved;
        expect(saved.files, hasLength(2));
        expect(
          saved.report.skipped.any(
            (s) => s.table == 'future_user_notes' && s.rows == 1,
          ),
          isTrue,
        );
        expect(
          saved.report.skipped.any(
            (s) =>
                s.table == 'activity_suggestions' &&
                s.identity!.contains('meal-A'),
          ),
          isTrue,
        );
        expect(await allPrefs(), prefsBefore);
        expect(
          await env.imuFile('recording-A.jsonl').readAsBytes(),
          attachmentBefore,
        );
        await live.rawQuery('PRAGMA wal_checkpoint(FULL)');
        expect(
          sha256.convert(await File(live.path).readAsBytes()).toString(),
          liveBefore,
        );
        expect(private.listSync(), isEmpty);
        final plain = File('build/official_probe/official.db');
        await decryptBackupFile(
          File(saved.files.first),
          plain,
          'official pilot fixture passphrase',
        );
        final target = await databaseFactory.openDatabase(
          plain.absolute.path,
          options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
        );
        try {
          for (final entry in officialFixtureRows().entries) {
            final rows = await target.query(entry.key);
            expect(
              rows,
              isNotEmpty,
              reason:
                  '${entry.key} missing; skips: ${saved.report.skipped.where((s) => s.table == entry.key).map((s) => s.reason).join('; ')}',
            );
            final row = rows.firstWhere(
              (r) => entry.key != 'decoded_onehz' || r['device_id'] == '',
            );
            for (final field in entry.value.entries) {
              if ([
                'end_ts_fabricated',
                'ts_subsec',
                'attempt_group',
                'attempt',
                'origin',
              ].contains(field.key)) {
                continue;
              }
              final expected = switch (entry.key) {
                'sessions'
                    when [
                      'calories',
                      'strain',
                      'avg_hr',
                      'max_hr',
                      'trace_json',
                    ].contains(field.key) =>
                  null,
                'activity_suggestions' when field.key == 'details_json' =>
                  '{"sport":"running"}',
                'activity_review_meta' when field.key == 'revision' => 0,
                'sleep_nap' when field.key == 'payload_json' => null,
                'workout_split' when field.key == 'avg_hr' => null,
                'workout_suggestions'
                    when ['avg_bpm', 'peak_bpm'].contains(field.key) =>
                  null,
                _ => field.value,
              };
              expect(
                row[field.key],
                expected,
                reason: '${entry.key}.${field.key}',
              );
            }
          }
          expect(await target.query('day_result'), isEmpty);
          expect(await target.query('metric_series'), isEmpty);
          expect(await target.query('baselines'), isEmpty);
          expect(
            (await target.query('raw_archive')).map((r) => r['hex']).toSet(),
            {'AABB', 'CCDD'},
          );
          expect(await target.query('activity_suggestions'), hasLength(1));
          expect(await target.query('decoded_onehz'), hasLength(2));
        } finally {
          await target.close();
        }
        final recovery = File('${env.root.path}/recovery.db');
        await decryptBackupFile(
          File(saved.files.last),
          recovery,
          'official pilot fixture passphrase',
        );
        await verifyDatabaseInventory(
          recovery.path,
          saved.report.sourceInventory,
        );
        final recoveryDb = await databaseFactory.openDatabase(
          recovery.path,
          options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
        );
        try {
          expect(
            (await recoveryDb.query('future_user_notes')).single['note'],
            'Do not lose this',
          );
          expect(
            (await recoveryDb.query('backup_files')).single['bytes'],
            attachmentBefore,
          );
          expect(
            (await recoveryDb.query(
              'backup_prefs',
              where: 'key=?',
              whereArgs: ['profile.height_cm'],
            )).single['value'],
            '173.5',
          );
          expect(
            await recoveryDb.query(
              'backup_prefs',
              where: 'key=?',
              whereArgs: ['paired_remote_id'],
            ),
            isEmpty,
          );
          expect(await recoveryDb.query('day_result'), hasLength(3));
        } finally {
          await recoveryDb.close();
        }
        // The recovery file goes through the fork's real journaled importer,
        // including its extras/files restoration, on a disposable fresh install.
        await env.wipe();
        await LocalDb.importFromDbFile(recovery.path);
        final restored = await LocalDb.instance;
        expect(
          (await restored.query('journal')).single['note'],
          'Exact journal note 🏔',
        );
        expect(
          (await restored.query('ecg_reading')).single['attempt_group'],
          'group-A',
        );
        expect((await restored.query('sessions')).single['rpe'], 8.5);
        expect(
          await env.imuFile('recording-A.jsonl').readAsBytes(),
          attachmentBefore,
        );
        expect((await allPrefs())['profile.height_cm'], 173.5);
        expect((await allPrefs()).containsKey('paired_remote_id'), isFalse);
        await File('build/official_probe/fixture-report.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert(saved.report.toJson()),
        );
      } finally {
        await env.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
