// AppState.importProgress during a backup restore: the stages the import
// screen draws (ImportProgressView), in order, then back to null.
//
//   Preparing(inflating? / opening / checking)
//     -> Copying(stage, rowsDone non-decreasing, rowsTotal)
//     -> Rebuilding(daysDone, daysTotal, day)
//     -> Done -> null
//   a thrown import: ... -> Failed(error) -> null

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_derive_harness.dart';

const _name = 'import_progress_test.db';
const _t0 = 1790000000;

class _Rollup implements ImportRollupProbe {
  @override
  Future<void> finalize(Profile profile) async {}
}

/// A plain-.db backup: [seconds] of 1 Hz rows and two scored days.
Future<String> _backup(String dir, {int seconds = 5000}) async {
  final path = p.join(dir, 'backup.db');
  await databaseFactoryFfi.deleteDatabase(path);
  final src = await databaseFactoryFfi.openDatabase(path);
  await src.execute('''CREATE TABLE decoded_onehz (
    device_id TEXT NOT NULL DEFAULT '', ts_ms INTEGER NOT NULL DEFAULT 0,
    rec_ts INTEGER, counter INTEGER NOT NULL, hr INTEGER,
    PRIMARY KEY (device_id, ts_ms))''');
  await src.execute('''
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n
                            WHERE i < $seconds)
    INSERT INTO decoded_onehz
    SELECT '', ($_t0 + i) * 1000, $_t0 + i, i, 60 FROM n''');
  await src.execute('''CREATE TABLE day_result (
    day_id TEXT NOT NULL, algo_version INTEGER NOT NULL,
    payload_json TEXT NOT NULL, computed_at INTEGER NOT NULL,
    finalized INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day_id, algo_version))''');
  for (final d in ['2026-09-20', '2026-09-21']) {
    await src.insert('day_result', {
      'day_id': d, 'algo_version': 100, 'payload_json': '{}',
      'computed_at': 1, 'finalized': 1,
    });
  }
  await src.close();
  return path;
}

int _phase(ImportProgress v) => switch (v) {
      ImportPreparing() => 0,
      ImportCopying() => 1,
      ImportRebuilding() => 2,
      ImportDone() => 3,
      ImportFailed() => 3,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState app;
  late List<ImportProgress?> seen;

  setUp(() async {
    await deriveDbSetUp(_name);
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('import_progress_');
    app = AppState.forTesting();
    app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    app.debugFinalizeImport = _Rollup();
    seen = [];
    app.importProgress.addListener(() => seen.add(app.importProgress.value));
  });
  tearDown(() async {
    app.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
    await deriveDbTearDown(_name);
  });

  /// Waits for the progress to clear (a view may hold Done briefly).
  Future<void> cleared() => until(() => app.importProgress.value == null,
      within: const Duration(seconds: 5), what: 'importProgress back to null');

  test('a plain .db: preparing, copying, rebuilding, done, then null',
      () async {
    expect(app.importProgress.value, isNull);
    final path = await _backup(tmp.path);

    await app.importEdgeBackup(path);
    await cleared();

    final steps = seen.whereType<ImportProgress>().toList();
    expect(steps, isNotEmpty, reason: 'the import reported nothing');
    expect(steps.first, isA<ImportPreparing>());
    expect(steps.whereType<ImportCopying>(), isNotEmpty);
    expect(steps.whereType<ImportRebuilding>(), isNotEmpty);
    expect(steps.last, isA<ImportDone>());
    expect(steps.whereType<ImportFailed>(), isEmpty);
    expect(seen.last, isNull);

    // Stages only move forward.
    for (var i = 1; i < steps.length; i++) {
      expect(_phase(steps[i]), greaterThanOrEqualTo(_phase(steps[i - 1])),
          reason: '${steps[i - 1]} then ${steps[i]}');
    }
    // A plain file is never inflated.
    for (final s in steps.whereType<ImportPreparing>()) {
      expect(s.step, isNot(ImportPrepStep.inflating));
    }
    // Copying: stage index forward, rows non-decreasing within a stage,
    // never past the total.
    final copying = steps.whereType<ImportCopying>().toList();
    for (final c in copying) {
      expect(c.stageIndex, inInclusiveRange(0, c.stageCount - 1));
      expect(c.rowsDone, inInclusiveRange(0, c.rowsTotal));
    }
    for (var i = 1; i < copying.length; i++) {
      final a = copying[i - 1], b = copying[i];
      expect(b.stageIndex, greaterThanOrEqualTo(a.stageIndex));
      if (b.stageIndex == a.stageIndex) {
        expect(b.rowsDone, greaterThanOrEqualTo(a.rowsDone));
      }
    }
    // The heart-rate rows were counted as they landed.
    final hr = copying.where((c) => c.stage == ImportStage.heartRate).toList();
    expect(hr, isNotEmpty, reason: 'decoded_onehz is the heartRate stage');
    expect(hr.last.rowsDone, 5000);
    // Rebuilding: days forward, never past the total.
    final rebuilding = steps.whereType<ImportRebuilding>().toList();
    for (var i = 0; i < rebuilding.length; i++) {
      final r = rebuilding[i];
      expect(r.daysDone, inInclusiveRange(0, r.daysTotal));
      if (i > 0) {
        expect(r.daysDone, greaterThanOrEqualTo(rebuilding[i - 1].daysDone));
      }
    }
  });

  test('a .db.gz reports inflating before opening', () async {
    final plain = await _backup(tmp.path, seconds: 100);
    final gz = '$plain.gz';
    File(gz).writeAsBytesSync(gzip.encode(File(plain).readAsBytesSync()));

    await app.importEdgeBackup(gz);
    await cleared();

    final prep = seen.whereType<ImportPreparing>().map((s) => s.step).toList();
    expect(prep, contains(ImportPrepStep.inflating));
    expect(prep, contains(ImportPrepStep.opening));
    expect(prep.indexOf(ImportPrepStep.inflating),
        lessThan(prep.indexOf(ImportPrepStep.opening)));
    expect(seen.whereType<ImportProgress>().last, isA<ImportDone>());
  });

  test('a thrown import reports Failed, then null', () async {
    final bad = File(p.join(tmp.path, 'not_a_db.db'))
      ..writeAsStringSync('this is not a database ' * 200);

    await expectLater(app.importEdgeBackup(bad.path), throwsA(anything));
    await cleared();

    final steps = seen.whereType<ImportProgress>().toList();
    expect(steps, isNotEmpty, reason: 'the import reported nothing');
    expect(steps.last, isA<ImportFailed>());
    expect((steps.last as ImportFailed).error, isNotEmpty);
    expect(steps.whereType<ImportDone>(), isEmpty);
    expect(seen.last, isNull);
  });
}
