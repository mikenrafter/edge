// Design 06 phase 1c, Sol r1 finding 5: day scopes come from SQLite
// 'localtime' (the phone's CURRENT zone), not the zone at the time (design 01,
// not landed). Until it lands the interim rule is conservative: a `zone` input
// bumps whenever the observed zone (name and offset) changes, and every
// day-scoped group declares it, so a zone change invalidates every day.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db/input_revision_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<int> _zone() async {
  final snap = await inputRevSnapshot(['zone'],
      fromDay: '2026-01-01', toDay: '2026-12-31');
  return snap['zone']?[''] ?? 0;
}

void main() {
  const name = 'input_revision_zone_test.db';
  Future<String> path() async =>
      p.join(await databaseFactory.getDatabasesPath(), name);

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    await databaseFactory.deleteDatabase(await path());
    LocalDb.dbName = name;
    await LocalDb.instance;
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(await path());
  });

  test('the first observation records the zone and bumps nothing', () async {
    final before = await _zone();
    expect(await observeInputZone(zoneKey: 'UTC|0'), isFalse);
    expect(await _zone(), before);
  });

  test('the same zone again bumps nothing', () async {
    final before = await _zone();
    expect(await observeInputZone(zoneKey: 'UTC|0'), isFalse);
    expect(await _zone(), before);
  });

  test('a zone change bumps the global zone input once', () async {
    final before = await _zone();
    expect(await observeInputZone(zoneKey: 'JST|540'), isTrue);
    expect(await _zone(), before + 1);
    expect(await observeInputZone(zoneKey: 'JST|540'), isFalse);
    expect(await _zone(), before + 1);
  });

  test('a DST change of offset in the same zone name is a zone change',
      () async {
    final before = await _zone();
    expect(await observeInputZone(zoneKey: 'EST|-300'), isTrue);
    expect(await observeInputZone(zoneKey: 'EDT|-240'), isTrue);
    expect(await _zone(), before + 2);
  });

  test('a trigger day label agrees with dayLabelOf across a local DST '
      'boundary, including a 01:30 row', () async {
    final db = await LocalDb.instance;
    // Every half hour for three days around each March/November transition
    // of the zone this process runs in (a no-op in a zone without DST).
    final probes = <int>[];
    for (final start in [DateTime(2026, 3, 7), DateTime(2026, 10, 30)]) {
      for (var h = 0; h < 24 * 4 * 2; h++) {
        probes.add(start.add(Duration(minutes: 30 * h))
                .millisecondsSinceEpoch ~/
            1000);
      }
    }
    probes.add(DateTime(2026, 3, 8, 1, 30).millisecondsSinceEpoch ~/ 1000);
    probes.add(DateTime(2026, 11, 1, 1, 30).millisecondsSinceEpoch ~/ 1000);
    for (final ts in probes) {
      final got = (await db.rawQuery(
              "SELECT strftime('%Y-%m-%d', ?, 'unixepoch', 'localtime') d",
              [ts]))
          .single['d'];
      expect(got, dayLabelOf(DateTime.fromMillisecondsSinceEpoch(ts * 1000)),
          reason: 'ts $ts');
    }
  });
}
