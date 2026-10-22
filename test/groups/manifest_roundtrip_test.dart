// Design 06 phase 1e: the publication manifest codec, the compat rule and the
// "unpublished is ignored after a restart" rule.
//
// RED today: none of the files below exist.
//
// ASSUMED NEW API
//   lib/compute/groups/manifest_codec.dart
//     const int kManifestCompat = 1;
//     class Manifest {                      // one `day_manifest` row, decoded
//       const Manifest({required String dayId, required int manifestSeq,
//         required int compat, required int registryVersion,
//         required Map<String,int> selected,      // group id -> revision
//         required List<String> keyOrder,         // bundle path order
//         required String bundleSha, required String seriesSha,
//         required Map<String,Object?> freshness, required int publishedAt});
//       fields carry the same names.
//     }
//     Map<String,Object?> manifestToRow(Manifest m);        // column -> value
//     Manifest manifestFromRow(Map<String,Object?> row);    // throws on junk
//     Manifest? tryDecodeManifest(Map<String,Object?> row, {int maxCompat});
//       // null (never a throw) for compat > maxCompat or an undecodable row
//   lib/data/db/manifest_store.dart
//     Future<Manifest?> latestManifest(DatabaseExecutor db, String dayId,
//         {int maxCompat = kManifestCompat});  // latest at or below maxCompat
//   LocalDb.schemaVersion == 79 (see manifest_schema_test.dart)
//
// Mirrors `_servedAlgoCeiling`: a reader serves the latest manifest it can
// read, so a rolled-back build keeps working over a newer build's rows.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/groups/manifest_codec.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/db/group_row_store.dart';
import 'package:openstrap_edge/data/db/manifest_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/frozen_day_result_fixtures.dart' show freshDb, dropDb;

const String _day = '2026-03-10';

Manifest _m({int seq = 1, int compat = 1, String day = _day}) => Manifest(
      dayId: day,
      manifestSeq: seq,
      compat: compat,
      registryVersion: 7,
      selected: const {'sleep.stage': 3, 'edge.assembly': 1, 'hrv.freq': 2},
      keyOrder: const ['date', 'sleep', 'series.hr_curve', 'scalars.rhr', 'zones'],
      bundleSha: 'ab' * 32,
      seriesSha: 'cd' * 32,
      freshness: const {
        'algo_version': 500,
        'finalized': true,
        'partial': false,
        'computed_at': 1234567890123,
        'note': null,
        'unicode': 'naïve ☃',
        'nested': {'a': 1.5, 'b': [1, 2, null]},
      },
      publishedAt: 42,
    );

Future<void> _insertRow(Database db, Map<String, Object?> row) =>
    db.insert('day_manifest', row);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(dropDb);

  test('kManifestCompat is 1', () => expect(kManifestCompat, 1));

  group('codec', () {
    test('encode then decode is lossless', () {
      final m = _m();
      final back = manifestFromRow(manifestToRow(m));
      expect(back.dayId, m.dayId);
      expect(back.manifestSeq, m.manifestSeq);
      expect(back.compat, m.compat);
      expect(back.registryVersion, m.registryVersion);
      expect(back.selected, m.selected);
      expect(back.keyOrder, m.keyOrder, reason: 'order is the payload order');
      expect(back.bundleSha, m.bundleSha);
      expect(back.seriesSha, m.seriesSha);
      expect(back.freshness, m.freshness);
      expect(back.publishedAt, m.publishedAt);
    });

    test('the row carries exactly the day_manifest columns, text as JSON', () {
      final row = manifestToRow(_m());
      expect(row.keys.toSet(), {
        'day_id', 'manifest_seq', 'compat', 'registry_version',
        'selected_json', 'key_order_json', 'bundle_sha', 'series_sha',
        'freshness_json', 'published_at',
      });
      expect(jsonDecode(row['selected_json'] as String), isA<Map>());
      expect(jsonDecode(row['key_order_json'] as String), isA<List>());
      expect(jsonDecode(row['freshness_json'] as String), isA<Map>());
    });

    test('encoding is deterministic: equal manifests, equal rows', () {
      final a = manifestToRow(_m());
      final reordered = Manifest(
        dayId: _day, manifestSeq: 1, compat: 1, registryVersion: 7,
        selected: const {'hrv.freq': 2, 'edge.assembly': 1, 'sleep.stage': 3},
        keyOrder: _m().keyOrder, bundleSha: _m().bundleSha,
        seriesSha: _m().seriesSha, freshness: _m().freshness, publishedAt: 42,
      );
      expect(manifestToRow(reordered), a);
    });

    test('a round trip through a second encode is a fixed point', () {
      final row = manifestToRow(_m());
      expect(manifestToRow(manifestFromRow(row)), row);
    });

    test('an unknown future compat is skipped, not thrown on', () {
      final row = manifestToRow(_m(compat: 99));
      // A future layout may not even be JSON a v1 reader understands.
      row['selected_json'] = 'not json {{ \u0000';
      row['freshness_json'] = '[[[';
      expect(tryDecodeManifest(row), isNull);
      expect(tryDecodeManifest(row, maxCompat: 99), isNull,
          reason: 'junk under a readable compat is also skipped, not thrown');
    });

    test('a readable compat decodes', () {
      expect(tryDecodeManifest(manifestToRow(_m())), isNotNull);
      expect(tryDecodeManifest(manifestToRow(_m(compat: 99)), maxCompat: 99),
          isNotNull);
    });
  });

  group('store', () {
    late Database db;
    setUp(() async => db = await freshDb('manifest_roundtrip.db'));

    test('a stored manifest reads back lossless', () async {
      await _insertRow(db, manifestToRow(_m()));
      final back = (await latestManifest(db, _day))!;
      expect(manifestToRow(back), manifestToRow(_m()));
    });

    test('latestManifest takes the highest seq at or below the reader compat; '
        'a newer build\'s manifest is skipped', () async {
      await _insertRow(db, manifestToRow(_m(seq: 1)));
      await _insertRow(db, manifestToRow(_m(seq: 2)));
      await _insertRow(db, manifestToRow(_m(seq: 3, compat: 99)));
      expect((await latestManifest(db, _day))!.manifestSeq, 2);
      expect((await latestManifest(db, _day, maxCompat: 99))!.manifestSeq, 3);
    });

    test('only a future manifest: nothing to serve, no crash', () async {
      await _insertRow(db, manifestToRow(_m(compat: 99)));
      expect(await latestManifest(db, _day), isNull);
    });

    test('no manifest, other days only: null', () async {
      await _insertRow(db, manifestToRow(_m(day: '2026-03-11')));
      expect(await latestManifest(db, _day), isNull);
    });

    test('an unpublished revision is ignored after a restart', () async {
      final stamp = await captureInputStamp(_day);
      expect(
          await LocalDb.putDayResult(
            dayId: _day,
            algoVersion: 500,
            payloadJson: jsonEncode({
              'date': _day,
              'sleep': {'a': 1},
              'scalars': {'rhr': 50.0},
            }),
            windowJson: '{}',
            series: const {'rhr': 50.0},
            inputStamp: stamp,
          ),
          isTrue);
      final m1 = (await latestManifest(db, _day))!;
      expect(m1.selected, isNotEmpty);

      // A crash after a newer revision was written but before any manifest
      // named it: revision 2 exists, published = 0.
      final r1 = (await db.query('group_row',
          where: 'day_id = ? AND group_id = ? AND revision = 1',
          whereArgs: [_day, 'sleep.stage'])).single;
      await db.insert('group_row', {...r1, 'revision': 2, 'published': 0});

      await LocalDb.close();
      final reopened = await LocalDb.instance;

      final m2 = (await latestManifest(reopened, _day))!;
      expect(m2.selected, m1.selected, reason: 'rev 2 is not in any manifest');
      expect(m2.selected['sleep.stage'], 1);
      final pub = await reopened.query('group_row',
          where: 'day_id = ? AND published = 1', whereArgs: [_day]);
      expect({for (final r in pub) r['group_id'] as String: r['revision']},
          m1.selected, reason: 'published = 1 is exactly the manifest');
      expect(
          await reopened.query('group_row',
              where: "group_id = 'sleep.stage' AND revision = 2 AND published = 1"),
          isEmpty);
    });
  });
}
