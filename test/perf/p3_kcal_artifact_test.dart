// 8AG-perf P3-C: the intraday calorie artifact `kcal_minutes|<day>`, end to end.
//
// ASSUMED API (see p3_kcal_builder_test.dart for the pure builder and the exact
// payload; support/p3_support.dart for the repository surface):
//
//   * The per-day derive (the offloaded second half of `_derivePreparedDay`,
//     i.e. inside the isolate) calls `buildKcalMinutes` with the SAME inputs it
//     hands `wakeDayEnergy` (wake series, restingHr, sleep window, step spans)
//     and, when it returns non-null, stores the payload as a `last_result` row:
//         key           'kcal_minutes|<day>'
//         computed_at   epoch ms the series was computed
//         payload_json  jsonEncode(payload)
//         input_sig     == LocalRepositoryImpl.artifactSignature(key) for the
//                       state the derive saw (one shared signature function, so
//                       a day derived by P3 reads FRESH to the warmer).
//     A day whose builder answers null (no raw, no anchors) stores NO row. A
//     re-derive of the same inputs REPLACES the row with an equal payload.
//     No existing stored output changes (calories, calories_total, ...).
//
//   * LocalRepositoryImpl.getDayCalorieCurve(String day) -> Future<Map?>
//       null when there is no row; else
//         {'minutes': [{'t': int, 'total': num?, 'active': num?, 'basal': num?}],
//          'basal_kcal_per_min': num, 'covered_minutes': int,
//          'computed_at': int}      // the row's computed_at, epoch ms
//       (`source` is stored but not served.) Gaps stay null.
//
//   * LocalRepositoryImpl.computeArtifact('kcal_minutes|<day>') (what the warmer
//     calls for a recent day derived before P3): rebuilds the payload from the
//     decoded substrate with the stored day's own sleep window / resting HR and
//     the repository profile, and returns EXACTLY what the derive stored (same
//     payload). Null when the day has no decoded raw (past retention) or the
//     builder abstains.
//
//   * `kAlgoVersion` is NOT bumped (nothing already stored moves): 100 stays,
//     and a changelog note next to `kAnalyticsPin` says edge now persists
//     Calories.minuteEnergy (the exact phrase 'edge now persists
//     Calories.minuteEnergy', so it can be found).
//
// Failure mode today: no `kcal_minutes|...` row is ever written and the reader
// does not exist.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/p3_support.dart';

const _day = '2025-09-10';
const _noHeightDay = '2025-09-11';

int _sec(int d, int h, int m) =>
    DateTime(2025, 9, d, h, m).millisecondsSinceEpoch ~/ 1000;

/// 10:00-13:00 on [d]: minutes % 10 < 3 at hr 150, the rest 70, and every
/// minute % 17 == 5 missing entirely (a gap). Accel is present so the day has
/// motion minutes. Device family stamped.
Future<void> _seed(int d) async {
  final db = await LocalDb.instance;
  final b = db.batch();
  var c = d * 100000;
  final from = _sec(d, 10, 0), to = _sec(d, 13, 0);
  for (var ts = from; ts < to; ts++) {
    final m = (ts - from) ~/ 60;
    if (m % 17 == 5) continue;
    b.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': c++,
      'hr': m % 10 < 3 ? 150 : 70,
      'ax': (ts % 3) * 0.01,
      'ay': 0.0,
      'az': 1.0,
      'device_family': 'gen4',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await b.commit(noResult: true);
}

Future<Map<String, Object?>?> _row(String key) async {
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
      'SELECT key, computed_at, payload_json FROM last_result WHERE key = ?',
      [key]);
  return rows.isEmpty ? null : rows.single;
}

/// The signature stored with [key]'s row (throws until the column exists).
Future<String?> _sigOf(String key) async {
  final db = await LocalDb.instance;
  final rows = await db
      .rawQuery('SELECT input_sig FROM last_result WHERE key = ?', [key]);
  return rows.isEmpty ? null : rows.single['input_sig'] as String?;
}

Future<int> _rowCount(String key) async {
  final db = await LocalDb.instance;
  return (await db.rawQuery(
          'SELECT COUNT(*) AS n FROM last_result WHERE key = ?', [key]))
      .first['n'] as int;
}

Future<Map<String, dynamic>> _scalars(String day) async {
  final r = await LocalDb.dayResult(day);
  final b = jsonDecode(r!['payload_json'] as String) as Map;
  return (b['scalars'] as Map).cast<String, dynamic>();
}

Map<String, dynamic> _payload(Map<String, Object?> row) =>
    (jsonDecode(row['payload_json'] as String) as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _minutes(Map<String, dynamic> p) =>
    [for (final m in (p['minutes'] as List)) (m as Map).cast<String, dynamic>()];

double _sumActive(Map<String, dynamic> p) => [
      for (final m in _minutes(p)) (m['active'] as num?)?.toDouble() ?? 0.0
    ].fold(0.0, (a, b) => a + b);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final repo = p3Repo();
  final profile = Profile.fromMap(p3ProfileMap);

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_p3_kcal_artifact_test.db';
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName));
    await LocalDb.instance;
    await _seed(10);
    await _seed(11);
    await DerivationEngine().runDays(profile, {_day}, force: true);
    // A profile with no height: the day derives, calories abstain.
    await DerivationEngine().runDays(
        Profile.fromMap({...p3ProfileMap}..remove('height_cm')), {_noHeightDay},
        force: true);
  });
  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName));
  });

  test('harness: the seeded day derived with a stored active-calorie figure',
      () async {
    final sc = await _scalars(_day);
    expect(sc['calories'], isNotNull);
    expect((sc['calories'] as num), greaterThan(0));
  });

  test('the derive stored kcal_minutes|<day>, and the minutes fold back to '
      'the day\'s stored active calories', () async {
    final row = await _row(p3Kcal(_day));
    expect(row, isNotNull, reason: 'a day derived from here on gets the curve');
    final payload = _payload(row!);
    expect(payload['v'], 1);
    expect(_minutes(payload), isNotEmpty);
    expect(_sumActive(payload),
        closeTo(((await _scalars(_day))['calories'] as num).toDouble(), 1e-6));
    expect(row['computed_at'], isA<int>());
    expect((row['computed_at'] as int),
        greaterThan(DateTime.now().millisecondsSinceEpoch - 600000));
  });

  test('gaps in the data are null minutes, never interpolated; covered_minutes '
      'counts the rest', () async {
    final payload = _payload((await _row(p3Kcal(_day)))!);
    final ms = _minutes(payload);
    final from = _sec(10, 10, 0);
    // Minute 5 and 22 and 39 ... of the window are missing from the seed.
    final byT = {for (final m in ms) m['t'] as int: m};
    for (final gap in [5, 22, 39, 56, 73, 90, 107, 124, 141, 158, 175]) {
      final m = byT[from + gap * 60];
      expect(m, isNotNull, reason: 'the series keeps the minute\'s place');
      expect(m!['total'], isNull, reason: 'gap minute $gap');
      expect(m['active'], isNull);
      expect(m['basal'], isNull);
    }
    expect(payload['covered_minutes'],
        ms.where((m) => m['total'] != null).length);
    expect(ms.first['t'], from);
  });

  test('the stored row carries the signature the repository computes now',
      () async {
    expect(await _row(p3Kcal(_day)), isNotNull);
    final sig = await p3Sig(repo, p3Kcal(_day));
    expect(sig, isNotNull);
    expect(await _sigOf(p3Kcal(_day)), sig,
        reason: 'one signature function: the warmer then finds it fresh');
  });

  group('getDayCalorieCurve', () {
    test('serves {minutes, basal_kcal_per_min, covered_minutes, computed_at}',
        () async {
      final curve = await (repo as dynamic).getDayCalorieCurve(_day) as Map?;
      expect(curve, isNotNull);
      final row = (await _row(p3Kcal(_day)))!;
      final stored = _payload(row);
      expect(curve!['computed_at'], row['computed_at']);
      expect(curve['basal_kcal_per_min'], stored['basal_kcal_per_min']);
      expect(curve['covered_minutes'], stored['covered_minutes']);
      final minutes = (curve['minutes'] as List).cast<Map>();
      final storedMinutes = _minutes(stored);
      expect(minutes, hasLength(storedMinutes.length));
      for (var i = 0; i < minutes.length; i++) {
        expect(minutes[i]['t'], storedMinutes[i]['t']);
        expect(minutes[i]['total'], storedMinutes[i]['total']);
        expect(minutes[i]['active'], storedMinutes[i]['active']);
        expect(minutes[i]['basal'], storedMinutes[i]['basal']);
      }
    });

    test('a day with no artifact is null (absent, never made up)', () async {
      expect(await (repo as dynamic).getDayCalorieCurve('2025-01-01'), isNull);
      expect(await (repo as dynamic).getDayCalorieCurve(_noHeightDay), isNull);
    });
  });

  test('regression guard (passes today): a profile that cannot price calories '
      '(no height) stores no curve although the day derived', () async {
    expect(await LocalDb.dayResult(_noHeightDay), isNotNull);
    expect((await _scalars(_noHeightDay))['calories'], isNull);
    expect(await _row(p3Kcal(_noHeightDay)), isNull);
  });

  test('re-deriving the same inputs is idempotent: one row, equal payload',
      () async {
    final before = _payload((await _row(p3Kcal(_day)))!);
    await p3Tick();
    await DerivationEngine().runDays(profile, {_day}, force: true);
    expect(await _rowCount(p3Kcal(_day)), 1);
    final after = _payload((await _row(p3Kcal(_day)))!);
    expect(jsonEncode(after), jsonEncode(before));
  });

  test('the warmer\'s producer rebuilds the SAME payload from the substrate '
      'for a day derived without the artifact', () async {
    final stored = _payload((await _row(p3Kcal(_day)))!);
    final db = await LocalDb.instance;
    await db.delete('last_result',
        where: 'key = ?', whereArgs: [p3Kcal(_day)]); // "derived before P3"
    final built = await p3Compute(repo, p3Kcal(_day));
    expect(built, isNotNull);
    expect(jsonEncode(built), jsonEncode(stored));
    expect(await p3Compute(p3Repo(profile: {...p3ProfileMap}..remove('height_cm')),
            p3Kcal(_day)),
        isNull,
        reason: 'the producer abstains exactly where the builder does');
  });

  test('a day with no raw has no curve and no signature (past retention: '
      'absent, never fabricated)', () async {
    final db = await LocalDb.instance;
    await db.delete('last_result',
        where: 'key = ?', whereArgs: [p3Kcal(_day)]);
    await db.delete('decoded_onehz',
        where: 'rec_ts >= ? AND rec_ts < ?',
        whereArgs: [_sec(10, 0, 0), _sec(11, 0, 0)]);
    expect(await p3Compute(repo, p3Kcal(_day)), isNull);
    expect(await p3Sig(repo, p3Kcal(_day)), isNull);
    expect(await (repo as dynamic).getDayCalorieCurve(_day), isNull);
    expect(await _row(p3Kcal(_day)), isNull);
  });

  group('no output change', () {
    test('P3 itself bumps nothing: 101 is the incremental repin\'s bump '
        '(lombScargle first-sample shift), not this artifact\'s', () {
      expect(kAlgoVersion, 101);
    });

    test('the analytics pin carries minuteEnergy (7334289 and its '
        'descendant 65c8901)', () {
      expect(kAnalyticsPin, '65c8901c8fb09cd076290ea37676d55ef6c47429');
    });

    test('a changelog note next to kAnalyticsPin says edge now persists '
        'minuteEnergy', () {
      final s = File('lib/compute/derivation_engine.dart').readAsStringSync();
      final i = s.indexOf('const String kAnalyticsPin');
      expect(i, greaterThan(0));
      final window = s.substring(i > 3000 ? i - 3000 : 0, i + 600);
      expect(window, contains('edge now persists Calories.minuteEnergy'));
    });
  });
}
