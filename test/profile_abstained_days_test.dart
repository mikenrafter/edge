// A day whose metric abstains for a MISSING PROFILE FIELD
// (`need_input:name=age|sex|height_cm|weight_kg`) is not final: the user can
// still supply the field, and while raw is held the day can be re-derived.
// Held days are bounded (a user who never enters age must not keep the raw
// forever): past the raw-hold window the day finalizes with the abstention
// stated in its absent notes.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/series_codec.dart';

const _full = Profile(
    ageYears: 35, sex: 'm', weightKg: 75, heightCm: 178, restingHrManual: 55);
const _noAge =
    Profile(sex: 'm', weightKg: 75, heightCm: 178, restingHrManual: 55);

int _localSec(String day, int hour) {
  final d = DateTime.parse(day);
  return DateTime(d.year, d.month, d.day, hour).millisecondsSinceEpoch ~/ 1000;
}

Future<void> _insertDay(String day, {int wakeMin = 400}) async {
  final db = await LocalDb.instance;
  final start = _localSec(day, 9);
  final batch = db.batch();
  for (var i = 0; i < wakeMin * 60; i++) {
    final ts = start + i;
    batch.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': ts,
      'hr': i < 45 * 60 ? 130 : 62 + (i % 3) - 1,
      'ax': 0.05 * ((i % 60) / 60.0),
      'ay': 0.05 * ((i % 30) / 30.0),
      'az': 0.98,
      'device_family': 'gen4',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await batch.commit(noResult: true);
}

Future<void> _clear() async {
  final db = await LocalDb.instance;
  for (final t in const [
    'decoded_onehz',
    'day_result',
    'metric_series',
    'metric_series_version',
    'compute_freshness',
  ]) {
    await db.delete(t);
  }
  await db.delete('sync_cursor',
      where: 'name = ?', whereArgs: ['decoded_pruned_before']);
}

Future<Map<String, dynamic>> _bundle(String day) async {
  final row = (await LocalDb.dayResult(day))!;
  return SeriesCodec.decodePayloadJson('${row['payload_json']}')!;
}

Future<bool> _finalized(String day) async =>
    ((await LocalDb.dayResult(day))!['finalized'] as num) == 1;

Future<int> _rawRows(String day) async {
  final db = await LocalDb.instance;
  final start = _localSec(day, 0), end = _localSec(day, 24);
  return (await db.rawQuery(
          'SELECT COUNT(*) AS n FROM decoded_onehz WHERE rec_ts >= ? AND rec_ts < ?',
          [start, end]))
      .single['n'] as int;
}

Future<Set<String>> _owed() async => {
      for (final k in await LocalDb.computeFreshnessKeys(
          DerivationEngine.kProfileRepassKeyPrefix))
        k.substring(DerivationEngine.kProfileRepassKeyPrefix.length),
    };

const _days = [
  '2026-02-01', '2026-02-02', '2026-02-03', '2026-02-04', '2026-02-05',
  '2026-02-06', '2026-02-07',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_profile_abstained_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('profileBlockedFields reads only profile need_input notes', () {
    expect(
        DerivationEngine.profileBlockedFields({
          'absent_notes': {
            'strain': 'need_input:name=age',
            'calories': 'need_input:name=weight_kg',
            'hrv': 'need_input:name=hr_samples',
            'x': 'need_baseline:have=1,need=3',
          }
        }),
        {'age', 'weight_kg'});
    expect(DerivationEngine.profileBlockedFields({}), isEmpty);
  });

  test('a day abstaining on age is not finalized; supplying age reopens it',
      () async {
    await _clear();
    for (final d in _days) {
      await _insertDay(d);
    }
    await DerivationEngine().run(_noAge, heavy: true);

    final old = _days.first;
    expect((await _bundle(old))['absent_notes']['strain'],
        startsWith('need_input:name=age'));
    expect(await _finalized(old), isFalse,
        reason: 'older than the 48 h age window, but owed an age');
    expect(await _owed(), contains(old));
    expect(await _rawRows(old), greaterThan(0), reason: 'raw is held');

    await DerivationEngine().run(_full, heavy: true);
    // The first pass with an age writes the quiet levels; the next scores on
    // them (the quiet-level debt, which is its own marker).
    await DerivationEngine().run(_full, heavy: true);

    expect(await _owed(), isEmpty);
    final scored = <String>[
      for (final d in _days)
        if (((await _bundle(d))['scalars'] as Map)['strain'] != null) d,
    ];
    expect(scored, isNotEmpty,
        reason: 'strain lands where the data allows; notes: '
            '${[for (final d in _days) (await _bundle(d))['absent_notes']['strain']]}');
    expect(await _finalized(old), isTrue);
  });

  test('a user who never enters age: finalized past the hold window, with the '
      'abstention stated', () async {
    await _clear();
    await _insertDay('2026-02-01');
    await _insertDay('2026-02-25'); // data edge 24 days on
    await DerivationEngine().run(_noAge, heavy: true);
    final b = await _bundle('2026-02-01');
    expect(await _finalized('2026-02-01'), isTrue);
    expect(b['absent_notes']['strain'], startsWith('need_input:name=age'));
    expect(await _owed(), isNot(contains('2026-02-01')));
  });

  test('a profile-owed day whose raw is gone ends final with no marker after '
      'one pass; days that still have raw stay owed', () async {
    await _clear();
    for (final d in _days.take(3)) {
      await _insertDay(d);
    }
    await DerivationEngine().run(_noAge, heavy: true);
    final gone = _days.first;
    expect(await _owed(), containsAll(_days.take(3)));
    final db = await LocalDb.instance;
    await db.delete('decoded_onehz',
        where: 'rec_ts >= ? AND rec_ts < ?',
        whereArgs: [_localSec(gone, 0), _localSec(gone, 24)]);
    expect(await _rawRows(gone), 0);

    await DerivationEngine().run(_noAge, heavy: true);

    expect(await _owed(), isNot(contains(gone)));
    expect(await LocalDb.dayIsFinal(gone, kAlgoVersion), isTrue);
    expect((await _bundle(gone))['absent_notes']['strain'],
        startsWith('need_input:name=age'),
        reason: 'the abstention is still stated');
    expect(await _owed(), contains(_days[1]));
  });
}
