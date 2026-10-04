// P4a: imports keep their current semantics but never clobber a LOCAL finalized
// row of the same version. Assumed API: see support.dart (nothing new is
// referenced; compiles today, fails on behaviour).
//
// Two surfaces:
//   * the three writers that go through `putDayResult` (whoop / cloud / demo),
//     exercised with the exact argument shape each one passes;
//   * the backup / restore merge (`LocalDb.importFromDbFile`), which already
//     skips locally finalized rows with its own `protectedKeys` set. Pinned
//     here so the new guard is a mirror of it, not a replacement for it.
//
// "Local" = the row this device derived itself (band source). A finalized row
// that is itself an import snapshot may still be replaced by a newer import:
// that is the existing `import_data_safety_test` rule "re-importing over a
// PREVIOUS import is allowed" and is repeated here at the DB level.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';

import 'support.dart';

/// The argument shape of WhoopImporter's write (finalized because no raw is left).
Future<void> whoopImportWrite(String day, {double rhr = 58.0}) =>
    LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'date': day,
        'imported': true,
        'source': 'whoop_export',
        'scalars': {'rhr': rhr},
      }),
      windowJson: '{}',
      finalized: true,
      source: 'whoop_export',
      rhr: rhr,
      series: {'rhr': rhr},
    );

/// The argument shape of CloudImporter's write (always finalized).
Future<void> cloudImportWrite(String day, {double rhr = 58.0}) =>
    LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'date': day,
        'imported': true,
        'source': 'cloud_v2',
        'scalars': {'rhr': rhr},
      }),
      windowJson: '{}',
      finalized: true,
      source: 'cloud_v2',
      rhr: rhr,
      series: {'rhr': rhr},
    );

/// The argument shape of the demo generator's write.
Future<void> demoWrite(String day, {double rhr = 58.0}) => LocalDb.putDayResult(
  dayId: day,
  algoVersion: kAlgoVersion,
  payloadJson: jsonEncode({'date': day, 'scalars': {'rhr': rhr}}),
  windowJson: '{}',
  finalized: true,
  source: 'demo',
  rhr: rhr,
  series: {'rhr': rhr},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUp(() async => db = await freshDb('openstrap_p4a_import_guard_test.db'));
  tearDownAll(dropDb);

  final importers = <String, Future<void> Function(String)>{
    'whoop': whoopImportWrite,
    'cloud': cloudImportWrite,
    'demo': demoWrite,
  };

  for (final e in importers.entries) {
    group('${e.key} import write', () {
      test('does not overwrite a local finalized row of the same version',
          () async {
        await seedRow(db, kDay, finalized: true);
        final before = (await rowOf(db, kDay))!;

        await e.value(kDay);

        expect(await rowOf(db, kDay), before);
        expect(await seriesOf(db, kDay, 'rhr'), 50.0);
        expect(await seriesOf(db, kDay, 'readiness'), 70.0);
      });

      test('still writes an empty day (current semantics)', () async {
        await e.value(kDay);
        final row = (await rowOf(db, kDay))!;
        expect(row['finalized'], 1);
        expect(row['rhr'], 58.0);
      });

      test('still replaces a non-finalized local row (current semantics)',
          () async {
        await seedRow(db, kDay, finalized: false);
        await e.value(kDay);
        expect((await rowOf(db, kDay))!['rhr'], 58.0);
        expect(await seriesOf(db, kDay, 'rhr'), 58.0);
      });

      test('writes its own (day, V) beside a local finalized older version',
          () async {
        await seedRow(db, kDay, version: kAlgoVersion - 1, finalized: true);
        await e.value(kDay);
        expect((await rowOf(db, kDay))!['rhr'], 58.0);
        expect((await rowOf(db, kDay, version: kAlgoVersion - 1))!['computed_at'],
            kSeedComputedAt);
      });
    });
  }

  test('a newer WHOOP import may replace a previous finalized import',
      () async {
    await whoopImportWrite(kDay, rhr: 58.0);
    await whoopImportWrite(kDay, rhr: 61.0);
    expect((await rowOf(db, kDay))!['rhr'], 61.0);
    expect(await seriesOf(db, kDay, 'rhr'), 61.0);
  });

  group('backup restore (importFromDbFile)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('openstrap_p4a_'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// Snapshot the live DB (VACUUM INTO, what `exportCopy` does) so the merge
    /// has a real same-schema source file.
    Future<String> snapshot() async {
      final dest = p.join(tmp.path, 'backup.db');
      await db.execute('VACUUM INTO ?', [dest]);
      return dest;
    }

    test('skips a locally finalized row, replaces a provisional one', () async {
      await seedRow(db, '2026-03-10', finalized: true, tag: 'backup-final');
      await seedRow(db, '2026-03-11', finalized: false, tag: 'backup-prov');
      final backup = await snapshot();

      // The device moves on after the backup was taken.
      await db.update('day_result', {'payload_json': payloadOf('local-final')},
          where: 'day_id = ?', whereArgs: ['2026-03-10']);
      await db.update('day_result', {'payload_json': payloadOf('local-prov')},
          where: 'day_id = ?', whereArgs: ['2026-03-11']);

      await LocalDb.importFromDbFile(backup);

      expect((await rowOf(db, '2026-03-10'))!['payload_json'],
          payloadOf('local-final'),
          reason: 'locally finalized: never overwritten by import');
      expect((await rowOf(db, '2026-03-11'))!['payload_json'],
          payloadOf('backup-prov', day: '2026-03-11'),
          reason: 'non-finalized rows keep the plain REPLACE behaviour');
    });
  });
}
