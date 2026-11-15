// Copied into the immutable v0.11.3 source package by run_target_import.sh.
// WHY: a mapper-only round trip cannot prove the real receiver accepts values.
// CLAIM(export-real-target/export-no-fork-results/export-input-identity).
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TargetPaths extends PathProviderPlatform {
  TargetPaths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final encrypted in [false, true]) {
    test(
      'real official ${encrypted ? 'encrypted picker' : 'plain DB'} import, repeat and model reads',
      () async {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        SharedPreferences.setMockInitialValues({});
        final root = await Directory.systemTemp.createTemp('official_import_');
        PathProviderPlatform.instance = TargetPaths(root.path);
        LocalDb.dbName = '${root.path}/official.db';
        final app = AppState.forTesting();
        try {
          final source = encrypted
              ? Directory(
                  '/home/user/runs/export-official/build/official_probe/completed',
                ).listSync().whereType<File>().singleWhere(
                  (f) => f.path.contains('openstrap-official-'),
                )
              : File(
                  '/home/user/runs/export-official/build/official_probe/official.db',
                );
          final before = sha256.convert(await source.readAsBytes()).toString();
          for (var repetition = 0; repetition < 2; repetition++) {
            if (encrypted) {
              final result = await runImport(
                app,
                [source.path],
                askPassphrase: () async => 'official pilot fixture passphrase',
              );
              expect(result.error, isNull);
              expect(
                result.days,
                0,
              ); // v0.11.3 counts empty day_result, not raw days.
            } else {
              final counts = await LocalDb.importFromDbFile(source.path);
              expect(counts['_days'], 0);
            }
            final db = await LocalDb.instance;
            expect(await db.getVersion(), 58);
            expect(LocalDb.lastRebuild, isNull);
            expect(
              (await db.query(
                'journal',
                where: 'date=?',
                whereArgs: ['2026-11-01'],
              )).single['note'],
              'Exact journal note 🏔',
            );
            expect(
              (await db.query('lab_result')).single['note'],
              'exact lab note',
            );
            expect(
              (await db.query('raw_archive')).map((r) => r['hex']).toSet(),
              {'AABB', 'CCDD'},
            );
            final parents = await db.query(
              'decoded_onehz',
              orderBy: 'device_id',
            );
            expect(parents, hasLength(2));
            expect(parents.first['hr'], 63);
            expect(parents.last['hr'], 58);
            expect(parents.first['on_wrist'], isNull);
            expect(parents.first['hr_valid'], isNull);
            expect(parents.first['skin_temp_c'], isNull);
            expect((await db.query('decoded_rr')).single['rr_ms'], 952);
            expect((await db.query('observation')).single['value'], 71.0);
            final session = (await db.query('sessions')).single;
            expect(session['private'], 1);
            expect(session['rpe'], 8.5);
            expect(session['calories'], isNull);
            expect(session['strain'], isNull);
            expect(session['trace_json'], isNull);
            expect((await db.query('workout_route')).single['lat'], 40.1234);
            final ecg = EcgReading.fromRow(
              (await db.query('ecg_reading')).single,
            );
            expect(ecg?.notes, 'My exact ECG note');
            expect(ecg?.category, EcgCategory.sinusRhythm);
            expect(ecg?.status, EcgReadingStatus.completed);
            expect((await db.query('ecg_reading_packet')).single['samples'], [
              1,
              0,
              2,
              0,
            ]);
            final decisions = await db.query('activity_suggestions');
            // The pinned importer migrates the dismissed legacy suggestion into
            // its review ledger as a second decided row. Repeat imports converge.
            expect(decisions, hasLength(2));
            final migrated = ActivitySuggestion.fromRow(
              decisions.singleWhere((r) => r['id'] == 'suggest-A'),
            );
            expect(migrated.status, ActivityReviewStatus.superseded);
            final decision = ActivitySuggestion.fromRow(
              decisions.singleWhere((r) => r['id'] == 'activity-A'),
            );
            expect(decision.kind, ActivityKind.workout);
            expect(decision.status, ActivityReviewStatus.discarded);
            expect(decision.sport, 'running');
            expect(
              (await db.query('sleep_nap')).single['payload_json'],
              isNull,
            );
            final results = await db.query('day_result');
            if (encrypted) {
              // AppState's real refresh creates a new partial manual-nap projection.
              // This is target computation from the imported user correction.
              expect(results, hasLength(1));
              expect(results.single['algo_version'], 113);
              expect(results.single['partial'], 1);
              expect(results.single['readiness'], isNull);
              expect(results.single['rhr'], isNull);
              expect(results.single['rmssd'], isNull);
              final payload =
                  jsonDecode(results.single['payload_json'] as String) as Map;
              expect(payload['scalars']['nap_min'], 10.0);
              expect(payload.containsKey('sentinel'), isFalse);
            } else {
              expect(results, isEmpty);
            }
            expect(
              await db.query('metric_series'),
              encrypted
                  ? [
                      {'date': '2026-11-01', 'key': 'nap_min', 'value': 10.0},
                    ]
                  : isEmpty,
            );
            expect(
              (await db.rawQuery(
                'PRAGMA integrity_check',
              )).single.values.single,
              'ok',
            );
          }
          expect(sha256.convert(await source.readAsBytes()).toString(), before);
          expect(
            root
                .listSync()
                .whereType<File>()
                .where((f) => f.path.endsWith('.db'))
                .map((f) => f.path)
                .toList(),
            ['${root.path}/official.db'],
          );
        } finally {
          app.dispose();
          await LocalDb.close();
          await root.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
