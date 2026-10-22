// Design 06 phase 1e: what a publication is, and that it stays a shadow.
//
//  * Consistency: for an accepted day_result write, the published manifest's
//    key_order assembles the selected group rows to bytes equal to the stored
//    payload_json; bundle_sha is the sha-256 of those bytes; series_sha and
//    freshness describe the same write.
//  * Shadow safety: a failure while publishing never fails or rolls back the
//    day_result (or its metric_series); superseded and deleted days publish
//    nothing (the 1d `superseded` pattern); a refused frozen write publishes
//    nothing. Nothing is served from the manifest: the debug check only
//    compares.
//
// ASSUMED NEW API (besides publication.dart / manifest_codec.dart, see
// manifest_cas_test.dart and manifest_roundtrip_test.dart)
//   manifest_codec.dart
//     String sha256Hex(String text);   // over the UTF-8 bytes
//     String seriesSha(Map<String,double?> series);  // canonical: key-sorted,
//       // null kept as null, independent of insertion order
//   publication.dart
//     Future<String> assembleManifestPayload(DatabaseExecutor db, Manifest m);
//       // selected rows -> assembleBundle with m.keyOrder -> the exact stored
//       // encoding (no re-encode drift)
//   manifest_store.dart
//     class ManifestDiagnostics { int published, refused, failed, checked,
//         mismatched; String? lastProblem; }
//     final ManifestDiagnostics manifestDiagnostics;
//     Future<bool> checkManifestAgainstStored(DatabaseExecutor db, String dayId,
//         {required int algoVersion});
//       // debug only: latest manifest's bundle_sha == sha256Hex(stored
//       // payload_json); bumps checked / mismatched; never serves.
//   group_row_store.dart
//     writeGroupRowsAfterCommit gains optional
//       `Map<String,double?> series = const {}` (the series that write put
//       into metric_series) and publishes the manifest in the same shadow
//       transaction as the rows; failures count in manifestDiagnostics.failed
//       and roll the whole shadow transaction back (rows + manifest together).

import 'dart:convert';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/groups/manifest_codec.dart';
import 'package:openstrap_edge/compute/groups/publication.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/db/group_row_store.dart';
import 'package:openstrap_edge/data/db/manifest_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/frozen_day_result_fixtures.dart' show freshDb, dropDb;

const String _day = '2026-03-10';
const int _v = 500;

Map<String, Object?> _bundle({double rhr = 50.0, int a = 1}) => {
      'date': _day,
      'flags': <Object?>[],
      'sleep': {
        'window': {'value': {'onset_ms': a}}
      },
      'series': {'hr_curve': <Object?>[], 'hrv_day': <Object?>[]},
      'clinical': {
        'resting_hr': {'value': rhr}
      },
      'scalars': {'rhr': rhr, 'tst_min': 420.0, 'skin_temp_z': null},
    };

Future<bool> _put({
  double rhr = 50.0,
  int a = 1,
  bool pinned = true,
  bool finalized = false,
  DayResultWrite reason = DayResultWrite.derive,
  Map<String, double?>? series,
}) async {
  final stamp = pinned ? await captureInputStamp(_day) : null;
  return LocalDb.putDayResult(
    dayId: _day,
    algoVersion: _v,
    payloadJson: jsonEncode(_bundle(rhr: rhr, a: a)),
    windowJson: '{}',
    finalized: finalized,
    series: series ?? {'rhr': rhr},
    inputStamp: stamp,
    reason: reason,
  );
}

String _sha(String s) => c.sha256.convert(utf8.encode(s)).toString();

void main() {
  late Database db;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async => db = await freshDb('manifest_publication.db'));
  tearDownAll(dropDb);

  Future<String> storedPayload() async =>
      (await db.query('day_result')).single['payload_json'] as String;

  group('consistency', () {
    test('an accepted pinned write publishes a manifest naming one revision '
        'per group row, all marked published', () async {
      expect(await _put(), isTrue);
      final m = (await latestManifest(db, _day))!;
      expect(m.manifestSeq, 1);
      expect(m.compat, kManifestCompat);
      expect(m.dayId, _day);
      final rows = await db.query('group_row');
      expect(m.selected.keys.toSet(), {for (final r in rows) r['group_id']});
      expect({for (final r in rows.where((r) => r['published'] == 1))
        r['group_id'] as String: r['revision']}, m.selected);
      expect(rows.where((r) => r['published'] != 1), isEmpty);
    });

    test('key_order assembles the selected rows to the stored payload_json '
        'byte for byte, and bundle_sha matches', () async {
      expect(await _put(), isTrue);
      final m = (await latestManifest(db, _day))!;
      final stored = await storedPayload();
      expect(await assembleManifestPayload(db, m), stored);
      expect(m.bundleSha, _sha(stored));
      expect(m.bundleSha, sha256Hex(stored));
    });

    test('every accepted rewrite publishes a new seq that matches ITS payload',
        () async {
      for (var i = 1; i <= 3; i++) {
        expect(await _put(rhr: 50.0 + i, a: i), isTrue);
        final m = (await latestManifest(db, _day))!;
        expect(m.manifestSeq, i);
        final stored = await storedPayload();
        expect(m.bundleSha, _sha(stored), reason: 'seq $i');
        expect(await assembleManifestPayload(db, m), stored, reason: 'seq $i');
      }
      // Older manifests stay (history), each a complete publication.
      expect(await db.query('day_manifest'), hasLength(3));
    });

    test('series_sha and freshness come from the same write as the bundle',
        () async {
      final series = <String, double?>{'rhr': 51.0, 'tst_min': 420.0, 'x': null};
      expect(await _put(rhr: 51.0, finalized: true, series: series), isTrue);
      final m = (await latestManifest(db, _day))!;
      final dr = (await db.query('day_result')).single;
      expect(m.seriesSha, seriesSha(series));
      expect(m.freshness['algo_version'], _v);
      expect(m.freshness['finalized'], true);
      expect(m.freshness['partial'], false);
      expect(m.freshness['computed_at'], dr['computed_at'],
          reason: 'the very write the bundle came from');
      expect(m.bundleSha, _sha(dr['payload_json'] as String));
    });

    test('seriesSha is order independent and value sensitive', () {
      expect(seriesSha({'a': 1.0, 'b': null}), seriesSha({'b': null, 'a': 1.0}));
      expect(seriesSha({'a': 1.0}), isNot(seriesSha({'a': 1.5})));
      expect(seriesSha({'a': null}), isNot(seriesSha({})),
          reason: 'a blanked key is not an absent key');
    });

    test('a changed series with an identical bundle changes series_sha only',
        () async {
      expect(await _put(series: {'rhr': 50.0}), isTrue);
      final a = (await latestManifest(db, _day))!;
      expect(await _put(series: {'rhr': 50.0, 'extra': 3.0}), isTrue);
      final b = (await latestManifest(db, _day))!;
      expect(b.bundleSha, a.bundleSha);
      expect(b.seriesSha, isNot(a.seriesSha));
    });

    test('the debug check compares and counts, never serves', () async {
      expect(await _put(), isTrue);
      final before = manifestDiagnostics.checked;
      expect(await checkManifestAgainstStored(db, _day, algoVersion: _v), isTrue);
      expect(manifestDiagnostics.checked, before + 1);
      await db.update('day_result', {'payload_json': '{"date":"2026-03-10"}'});
      final mm = manifestDiagnostics.mismatched;
      expect(await checkManifestAgainstStored(db, _day, algoVersion: _v), isFalse);
      expect(manifestDiagnostics.mismatched, mm + 1);
    });

    test('an unpinned write publishes nothing (its revisions are never '
        'reusable)', () async {
      expect(await _put(pinned: false), isTrue);
      expect(await db.query('day_result'), hasLength(1));
      expect(await db.query('day_manifest'), isEmpty);
      expect(await db.query('group_row', where: 'published = 1'), isEmpty);
    });

    test('a refused frozen write publishes nothing and keeps the manifest',
        () async {
      expect(await _put(finalized: true), isTrue);
      final m1 = (await latestManifest(db, _day))!;
      expect(await _put(rhr: 60.0, a: 9), isFalse);
      expect(await db.query('day_manifest'), hasLength(1));
      expect(manifestToRow((await latestManifest(db, _day))!),
          manifestToRow(m1));
    });
  });

  group('shadow safety', () {
    test('a failure while publishing never fails or rolls back day_result',
        () async {
      await db.execute('CREATE TRIGGER mf_boom BEFORE INSERT ON day_manifest '
          "BEGIN SELECT RAISE(ABORT, 'boom'); END");
      final failed = manifestDiagnostics.failed;
      expect(await _put(), isTrue);
      expect(await db.query('day_result'), hasLength(1));
      expect(await db.query('metric_series'), isNotEmpty);
      expect(await db.query('day_manifest'), isEmpty);
      expect(manifestDiagnostics.failed, failed + 1);
      expect(manifestDiagnostics.lastProblem, contains('boom'));
      // Rows and manifest travel together: no half set.
      expect(await db.query('group_row'), isEmpty);
    });

    test('after the failure is gone the next write publishes', () async {
      await db.execute('CREATE TRIGGER mf_boom BEFORE INSERT ON day_manifest '
          "BEGIN SELECT RAISE(ABORT, 'boom'); END");
      expect(await _put(), isTrue);
      await db.execute('DROP TRIGGER mf_boom');
      expect(await _put(a: 2), isTrue);
      expect((await latestManifest(db, _day))!.manifestSeq, 1);
      expect(await db.query('day_manifest'), hasLength(1));
    });

    Future<void> after(Map<String, Object?> row, {required Object? stamp}) =>
        writeGroupRowsAfterCommit(
            dayId: _day,
            algoVersion: _v,
            finalized: false,
            partial: false,
            skipped: false,
            userOverride: false,
            expectedPayload: row['payload_json'] as String,
            expectedComputedAt: (row['computed_at'] as num).toInt(),
            stamp: stamp as InputStamp?);

    test('write B replaced the day between A commit and A shadow write: A '
        'publishes nothing, the manifest stays B\'s', () async {
      expect(await _put(), isTrue);
      final a = (await db.query('day_result')).single;
      final stampA = await captureInputStamp(_day);
      expect(await _put(rhr: 51.0, a: 2), isTrue); // B
      final mB = (await latestManifest(db, _day))!;
      final manifests = await db.query('day_manifest', orderBy: 'manifest_seq');
      final before = groupRowDiagnostics.superseded;
      await after(a, stamp: stampA);
      expect(groupRowDiagnostics.superseded, before + 1);
      expect(await db.query('day_manifest', orderBy: 'manifest_seq'), manifests);
      expect(mB.bundleSha, _sha(await storedPayload()));
    });

    test('the day deleted in the gap: no manifest is recreated', () async {
      expect(await _put(), isTrue);
      final a = (await db.query('day_result')).single;
      final stampA = await captureInputStamp(_day);
      await LocalDb.deleteDays({_day});
      await after(a, stamp: stampA);
      expect(await db.query('day_manifest'), isEmpty);
      expect(await db.query('group_row'), isEmpty);
    });

    test('deleting a day removes its manifests', () async {
      expect(await _put(), isTrue);
      expect(await _put(a: 2), isTrue);
      expect(await db.query('day_manifest'), hasLength(2));
      await LocalDb.deleteDays({_day});
      expect(await db.query('day_manifest'), isEmpty);
    });

    test('a skipped marker publishes nothing', () async {
      final stamp = await captureInputStamp(_day);
      await LocalDb.putDayResult(
          dayId: _day,
          algoVersion: _v,
          payloadJson: jsonEncode(_bundle()),
          windowJson: '{}',
          skipped: true,
          series: const {},
          inputStamp: stamp);
      expect(await db.query('day_manifest'), isEmpty);
    });
  });
}
