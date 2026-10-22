// Design 06 phase 1e: a group revision a manifest names is never rewritten in
// place. Its bytes are what the manifest's bundle_sha vouches for; a write that
// ends up unpublished (unpinned, refused) must leave the earlier publication
// assembling to the same payload.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/groups/manifest_codec.dart';
import 'package:openstrap_edge/compute/groups/publication.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/db/group_row_store.dart';
import 'package:openstrap_edge/data/db/manifest_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/frozen_day_result_fixtures.dart' show freshDb, dropDb;

const String _day = '2026-03-10';

String _bundle(int a) => jsonEncode({
      'date': _day,
      'sleep': {'a': a},
      'scalars': {'rhr': 50.0 + a},
    });

/// Rows with the BLOB as text (Uint8List does not deep-compare in a matcher).
Future<List<String>> _rows(Database db) async => [
      for (final r in await db.query('group_row', orderBy: 'group_id, revision'))
        jsonEncode({...r, 'payload': utf8.decode(r['payload'] as List<int>)}),
    ];

void main() {
  late Database db;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async => db = await freshDb('manifest_published_immutable.db'));
  tearDownAll(dropDb);

  Future<bool> putUnpinned(int a) => LocalDb.putDayResult(
        dayId: _day,
        algoVersion: 500,
        payloadJson: _bundle(a),
        windowJson: '{}',
        series: const {'rhr': 50.0},
      );

  test('an unpinned rewrite leaves the published provisional rows intact',
      () async {
    final stamp = await captureInputStamp(_day);
    expect(
        await LocalDb.putDayResult(
            dayId: _day,
            algoVersion: 500,
            payloadJson: _bundle(1),
            windowJson: '{}',
            series: const {'rhr': 51.0},
            inputStamp: stamp),
        isTrue);
    final m = (await latestManifest(db, _day))!;
    final before = await assembleManifestPayload(db, m);
    final rowsBefore = await _rows(db);

    expect(await putUnpinned(2), isTrue); // unpinned: publishes nothing

    expect((await latestManifest(db, _day))!.manifestSeq, m.manifestSeq);
    expect(await assembleManifestPayload(db, m), before);
    expect(m.bundleSha, sha256Hex(before));
    final rowsAfter = await _rows(db);
    for (final r in rowsBefore) {
      expect(rowsAfter, contains(r), reason: 'old revision unchanged');
    }
    expect(rowsAfter.length, greaterThan(rowsBefore.length),
        reason: 'a new unpublished revision exists');
    expect(
        (await db.query('group_row', where: 'revision = 2')).every((r) => r['published'] == 0),
        isTrue);
  });
}
