// The nap cleanup read `sleep.window.value` with a bare `as Map?`. A day with
// no main night stores the abstain envelope `{value: "—", tier, ...}`, so the
// cast threw `String is not a subtype of Map?`, the engine logged "will retry",
// and the one-shot cleanup never ran for ANY day (the marker was never written).
// Real exports carry that shape from algo versions 97-104.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/nap_overlap_cleanup.dart';
import 'package:openstrap_edge/data/db.dart';

Map<String, dynamic> _env(Object? v) =>
    {'value': v, 'confidence': 0, 'tier': 'x', 'inputs_used': []};

Future<void> _put(String day, int v, Map<String, dynamic> payload) =>
    LocalDb.putDayResult(
      dayId: day,
      algoVersion: v,
      payloadJson: jsonEncode(payload),
      windowJson: '{}',
      finalized: true,
    );

Map<String, dynamic> _day({Object? window, Object? naps}) => {
      'sleep': {'window': _env(window)},
      'naps': naps is List ? {..._env(naps), 'count': naps.length} : _env(naps),
      'scalars': <String, dynamic>{},
    };

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_nap_absent_window_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('absent next-night window / absent naps are skipped, the rest cleaned',
      () async {
    final nap = {'start': 2000, 'end': 3000};
    // d1: next day (d2) has NO night -> window.value is the string "—".
    await _put('2025-03-01', 97, _day(naps: [nap]));
    // d2: has naps absent as a string, and its next day (d3) has a real night.
    await _put('2025-03-02', 98, _day(window: '—', naps: '—'));
    await _put('2025-03-03', 100, _day(window: '—', naps: [nap]));
    // d4's night covers d3's nap; d3 is the one that must be cleaned.
    await _put('2025-03-04',
        104, _day(window: {'onset_ms': 1000 * 1000, 'offset_ms': 5000 * 1000}));

    final cleaned = await cleanNextNightNapsOnce();

    expect(cleaned, 1);
    expect(await LocalDb.computeFreshness(kNapNextNightCleanupKey), isNotNull,
        reason: 'marker written: no permanent retry loop');
    final row = await LocalDb.dayResult('2025-03-03');
    final payload = jsonDecode(row!['payload_json'] as String) as Map;
    expect((payload['naps'] as Map)['value'], isEmpty);
    final marker = jsonDecode(
        (await LocalDb.computeFreshness(kNapNextNightCleanupKey))!['payload_json']
            as String) as Map;
    expect((marker['skipped'] as Map)['2025-03-01'], 'no_next_night_window',
        reason: 'the skip is recorded with its reason');
  });
}
