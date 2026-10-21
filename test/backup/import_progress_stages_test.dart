// The import's first status stage was one long "looking at the backup". It now
// reports opening -> checking version -> counting (done/total tables) before the
// first copy stage, and the import leaves a summary the owner can read.
//
// RED: no counting step is reported and no summary is stored.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_progress.dart';

import 'backup_support.dart';

const _t0 = 1790000000;

void main() {
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('bkx_stages_test.db'));
  tearDownAll(() async => env.dispose());

  /// An export of a live DB with three days of raw data, one ordinary derived
  /// day, then two extra rows planted in the copy: a day_result from a NEWER
  /// build and a substrate_archive bucket in a codec this build lacks.
  Future<String> source() async {
    await env.wipe();
    final db = await LocalDb.instance;
    for (var d = 0; d < 3; d++) {
      for (var i = 0; i < 20; i++) {
        final ts = _t0 + d * 86400 + i;
        await db.insert('decoded_onehz', {
          'device_id': '', 'ts_ms': ts * 1000, 'rec_ts': ts,
          'counter': d * 100 + i + 1, 'hr': 60,
        });
      }
    }
    await db.insert('day_result', {
      'day_id': '2026-09-21', 'algo_version': kAlgoVersion,
      'payload_json': '{}', 'computed_at': 1, 'finalized': 1,
    });
    final path = await LocalDb.exportCopy();
    final copy = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    await copy.insert('day_result', {
      'day_id': '2026-10-01', 'algo_version': kAlgoVersion + 5,
      'payload_json': '{}', 'computed_at': 2, 'finalized': 1,
    });
    await copy.insert('substrate_archive', {
      'device_id': '', 'utc_day': _t0 ~/ 86400, // inside the keep window; older buckets are left out unreported
      'codec': 9999, 'from_ts': _t0,
      'to_ts': _t0 + 10, 'onehz_rows': 10, 'rr_rows': 0, 'raw_bytes': 10,
      'fingerprint': 1, 'tz_offset_min': 0,
      'blob': Uint8List.fromList([1, 2, 3, 4]), 'created_at': 1, 'updated_at': 1,
    });
    await copy.close();
    return path;
  }

  test('first stage: opening, checking version, counting tables, then copying',
      () async {
    final path = await source();
    await env.wipe();
    final seen = <ImportProgress>[];
    await LocalDb.importFromDbFile(path, onProgress: seen.add);

    final prep = seen.whereType<ImportPreparing>().toList();
    final order = <ImportPrepStep?>[];
    for (final s in prep) {
      if (order.isEmpty || order.last != s.step) order.add(s.step);
    }
    expect(order, [
      ImportPrepStep.opening,
      ImportPrepStep.checking,
      ImportPrepStep.counting,
    ]);

    final counting =
        prep.where((s) => s.step == ImportPrepStep.counting).toList();
    expect(counting.first.done, 0);
    expect(counting.first.total, greaterThan(0));
    for (var i = 0; i < counting.length; i++) {
      expect(counting[i].total, counting.first.total);
      expect(counting[i].done, inInclusiveRange(0, counting[i].total!));
      if (i > 0) {
        expect(counting[i].done, greaterThanOrEqualTo(counting[i - 1].done!));
      }
    }
    expect(counting.last.done, counting.last.total);

    final firstCopy = seen.indexWhere((s) => s is ImportCopying);
    final lastPrep = seen.lastIndexWhere((s) => s is ImportPreparing);
    expect(firstCopy, greaterThan(lastPrep),
        reason: 'all preparing steps come before the first copy stage');
  });

  test('the import leaves a summary with the counts the owner needs',
      () async {
    final path = await source();
    await env.wipe();
    expect(await lastImportSummary(), isNull);
    await LocalDb.importFromDbFile(path);

    final s = await lastImportSummary();
    expect(s, isNotNull, reason: 'a summary is persisted');
    expect(s!.daysWithRaw, 3);
    expect(s.daysDerived, 1, reason: 'the above-ceiling day is not served');
    expect(s.sourceDaysAboveCeiling, 1);
    expect(s.archiveBucketsSkipped, 1);
    expect(s.prefsRestored, greaterThanOrEqualTo(0));
    expect(s.filesRestored, 0);
  });

  test('the summary is not itself carried into the next export', () {
    expect(prefsKeyBackedUp('import_summary_v1'), isFalse);
    expect(p.basename('x'), 'x');
  });
}
