// A trend must not have holes where the current version abstained but an
// older version stored a value: those points are served, each flagged with
// `from_older_version`. Current values are never replaced.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _put(String day, int version, double? strain,
        {bool imported = false}) =>
    LocalDb.putDayResult(
      dayId: day,
      algoVersion: version,
      payloadJson: jsonEncode({
        'date': day,
        if (imported) 'imported': true,
        'scalars': {'strain': strain},
      }),
      windowJson: '{}',
      finalized: true,
      series: {'strain': strain},
    );

String _d(int i) => '2020-07-0$i';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_older_version_trend_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  final repo = LocalRepositoryImpl(getProfileMap: () => const {'age': 30});

  test('days 4-7 abstain now, v104 had them: all 7 points, 4-7 flagged',
      () async {
    for (var i = 1; i <= 7; i++) {
      await _put(_d(i), 104, 10.0 + i);
      await _put(_d(i), kAlgoVersion, i <= 3 ? 5.0 + i : null);
    }
    final chart = await repo.getChart('strain');
    final pts = (chart['points'] as List).cast<Map>();
    expect(pts.map((e) => e['v']).toList(),
        [6.0, 7.0, 8.0, 14.0, 15.0, 16.0, 17.0]);
    expect([for (final e in pts) e['from_older_version']],
        [null, null, null, 104, 104, 104, 104]);
    // Each older point says why the current version has no value; current
    // points carry no reason.
    expect([for (final e in pts) e['older_version_reason'] != null],
        [false, false, false, true, true, true, true]);
  });

  test('no older value: the hole stays a hole', () async {
    const day = '2020-07-09';
    await _put(day, 104, null);
    await _put(day, kAlgoVersion, null);
    final pts = ((await repo.getChart('strain'))['points'] as List).cast<Map>();
    expect(pts.any((e) => e['t'] == DateTime.parse('$day 12:00:00').millisecondsSinceEpoch ~/ 1000),
        isFalse);
  });

  test('an older imported vendor row never reaches the trend', () async {
    const day = '2020-07-11';
    await _put(day, 104, 19.0, imported: true);
    await _put(day, kAlgoVersion, null);
    final pts = ((await repo.getChart('strain'))['points'] as List).cast<Map>();
    expect(pts.where((e) => e['v'] == 19.0), isEmpty);
  });

  test('the only value in the 7th-oldest version still reaches the trend',
      () async {
    const day = '2020-07-12';
    for (var v = 100; v <= 106; v++) {
      await _put(day, v, v == 100 ? 6.5 : null);
    }
    await _put(day, kAlgoVersion, null);
    final pts = ((await repo.getChart('strain'))['points'] as List).cast<Map>();
    final t = DateTime.parse('$day 12:00:00').millisecondsSinceEpoch ~/ 1000;
    final pt = pts.singleWhere((e) => e['t'] == t);
    expect(pt['v'], 6.5);
    expect(pt['from_older_version'], 100);
  });
}
