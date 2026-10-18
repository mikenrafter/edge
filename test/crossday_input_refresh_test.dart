// The engine side of the kept cross-day input: against a real database, a pass
// reads the payloads of the days that changed and nothing else, the stored
// artifact always equals a rebuild from nothing, and the cross-day bundle is
// computed again only when something it is computed from changed.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _days = 8;
int _clock = 1000000;

String _label(int daysAgo) =>
    dayLabelOf(DateTime.now().subtract(Duration(days: daysAgo)));

Future<void> _put(int daysAgo,
    {double strain = 10, bool finalized = true, bool skipped = false}) async {
  _clock += 1000;
  await LocalDb.putDayResult(
    dayId: _label(daysAgo),
    algoVersion: kAlgoVersion,
    payloadJson: jsonEncode({
      'scalars': {'strain': strain, 'steps': 4000 + daysAgo, 'rhr': 55.0},
      if (skipped) 'skipped': true,
    }),
    windowJson: '{}',
    finalized: finalized,
    skipped: skipped,
    rhr: 55.0 + daysAgo,
    rmssd: 40.0,
    readiness: 70,
    reason: DayResultWrite.userOverride,
  );
}

Future<void> _seed() async {
  for (var i = _days - 1; i >= 0; i--) {
    await _put(i, strain: 8.0 + i, finalized: i > 0);
  }
}

Future<String> _artifact() async =>
    (await LocalDb.baseline('crossday_input'))!['payload_json'] as String;

int _rowsRead(DerivationEngine e) =>
    (e.perf.summary()['counts'] as Map)['crossday_payload_rows'] as int? ?? 0;

Future<List<Map<String, dynamic>>> _refresh(DerivationEngine e) {
  e.perf.startPass();
  return e.refreshCrossDayInputForTest();
}

/// What a rebuild from nothing would store right now.
Future<String> _rebuilt() async {
  final keep = await LocalDb.baseline('crossday_input');
  final fresh = DerivationEngine();
  await (await LocalDb.instance)
      .delete('baselines', where: 'key = ?', whereArgs: ['crossday_input']);
  await _refresh(fresh);
  final out = await _artifact();
  if (keep != null) {
    await LocalDb.putBaseline('crossday_input', keep['payload_json'] as String);
  }
  return out;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'crossday_input_refresh_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    LocalDb.nowMs = () => _clock;
    await LocalDb.instance;
    await _seed();
  });
  tearDownAll(() async {
    LocalDb.nowMs = () => DateTime.now().millisecondsSinceEpoch;
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  group('crossday_input artifact', () {
    test('first pass reads every payload and stores row keys', () async {
      final e = DerivationEngine();
      final days = await _refresh(e);
      expect(_rowsRead(e), _days);
      expect(days.length, _days);
      final art = jsonDecode(await _artifact()) as Map;
      expect(art['algo_version'], kAlgoVersion);
      expect((art['row_keys'] as Map).length, _days);
      expect(DerivationEngine.crossDayArtifactUsableToday(art, todayLabel()),
          isTrue);
      expect((days.last)['is_today'], true);
      expect((days.last)['unsettled'], true);
    });

    test('a second pass over unchanged rows reads nothing and writes nothing',
        () async {
      final e = DerivationEngine();
      await _refresh(e);
      final first = await LocalDb.baseline('crossday_input');
      _clock += 5000;
      final days = await _refresh(e);
      expect(_rowsRead(e), 0);
      expect(days.length, _days);
      final second = await LocalDb.baseline('crossday_input');
      expect(second!['payload_json'], first!['payload_json']);
      expect(second['updated_at'], first['updated_at'],
          reason: 'identical artifact: not rewritten');
    });

    test('today re-derived: one payload read, equal to a rebuild', () async {
      final e = DerivationEngine();
      await _refresh(e);
      for (var i = 1; i <= 3; i++) {
        await _put(0, strain: 10.0 + i, finalized: false);
        await _refresh(e);
        expect(_rowsRead(e), 1, reason: 'pass $i');
        expect(await _artifact(), await _rebuilt(), reason: 'pass $i');
      }
    });

    test('an earlier day replaced (late history): that day alone is read',
        () async {
      final e = DerivationEngine();
      await _refresh(e);
      await _put(4, strain: 17, finalized: true);
      final days = await _refresh(e);
      expect(_rowsRead(e), 1);
      expect(days.firstWhere((d) => d['date'] == _label(4))['strain'], 17);
      expect(await _artifact(), await _rebuilt());
    });

    test('a new engine (cold start, headless wake) reuses the stored artifact',
        () async {
      await _refresh(DerivationEngine());
      await _put(0, strain: 11, finalized: false);
      final e = DerivationEngine();
      await _refresh(e);
      expect(_rowsRead(e), 1);
      expect(await _artifact(), await _rebuilt());
    });

    test('a skipped day is neither a record nor read again', () async {
      await _put(3, skipped: true);
      final e = DerivationEngine();
      final days = await _refresh(e);
      expect(days.any((d) => d['date'] == _label(3)), isFalse);
      await _refresh(e);
      expect(_rowsRead(e), 0);
      expect(await _artifact(), await _rebuilt());
    });

    test('an algo bump rebuilds everything: an older artifact is not kept',
        () async {
      final e = DerivationEngine();
      await _refresh(e);
      final art = jsonDecode(await _artifact()) as Map;
      art['algo_version'] = kAlgoVersion - 1;
      await LocalDb.putBaseline('crossday_input', jsonEncode(art));
      await _refresh(e);
      expect(_rowsRead(e), _days);
      expect(
          (jsonDecode(await _artifact()) as Map)['algo_version'], kAlgoVersion);
    });

    test('an artifact written before row keys existed is rebuilt once',
        () async {
      final e = DerivationEngine();
      await _refresh(e);
      final art = jsonDecode(await _artifact()) as Map..remove('row_keys');
      await LocalDb.putBaseline('crossday_input', jsonEncode(art));
      await _refresh(e);
      expect(_rowsRead(e), _days);
      await _refresh(e);
      expect(_rowsRead(e), 0);
    });

    test('yesterday\'s artifact is not trusted for today\'s flags', () async {
      final e = DerivationEngine();
      await _refresh(e);
      final art = jsonDecode(await _artifact()) as Map;
      art['built_for_day'] = _label(1);
      await LocalDb.putBaseline('crossday_input', jsonEncode(art));
      final days = await _refresh(e);
      expect(_rowsRead(e), 0, reason: 'records are kept; only stamps move');
      expect(days.where((d) => d['is_today'] == true).length, 1);
      expect(
          (jsonDecode(await _artifact()) as Map)['built_for_day'], todayLabel());
      expect(await _artifact(), await _rebuilt());
    });
  });

  group('crossday bundle', () {
    const profile = Profile(ageYears: 35, weightKg: 75, heightCm: 178, sex: 'm');

    Future<String> bundle() async =>
        (await LocalDb.baseline('crossday'))!['payload_json'] as String;
    Future<int> updatedAt() async =>
        (await LocalDb.baseline('crossday'))!['updated_at'] as int;

    test('computed again only when an input changed', () async {
      final e = DerivationEngine();
      await _refresh(e);
      await e.runCrossDayForTest(profile);
      expect(e.debugCrossDayComputed, 1);
      final first = await bundle();
      final at = await updatedAt();
      expect((jsonDecode(first) as Map)['algo_version'], kAlgoVersion);

      _clock += 5000;
      await _refresh(e);
      await e.runCrossDayForTest(profile);
      expect(e.debugCrossDayComputed, 1, reason: 'same inputs: reused');
      expect(await bundle(), first);
      expect(await updatedAt(), greaterThan(at),
          reason: 'still stamped as written now, for the "as of" label');

      await _put(0, strain: 15, finalized: false);
      await _refresh(e);
      await e.runCrossDayForTest(profile);
      expect(e.debugCrossDayComputed, 2, reason: 'today changed');

      await e.runCrossDayForTest(
          const Profile(ageYears: 36, weightKg: 75, heightCm: 178, sex: 'm'));
      expect(e.debugCrossDayComputed, 3, reason: 'profile changed');

      await LocalDb.putCycleLog(_label(2), 'start');
      await e.runCrossDayForTest(
          const Profile(ageYears: 36, weightKg: 75, heightCm: 178, sex: 'm'));
      expect(e.debugCrossDayComputed, 4, reason: 'cycle log changed');
    });

    test('a new engine reuses it; a missing bundle is recomputed', () async {
      await _refresh(DerivationEngine());
      await DerivationEngine().runCrossDayForTest(profile);
      final e = DerivationEngine();
      await e.runCrossDayForTest(profile);
      expect(e.debugCrossDayComputed, 0);
      await (await LocalDb.instance)
          .delete('baselines', where: 'key = ?', whereArgs: ['crossday']);
      await e.runCrossDayForTest(profile);
      expect(e.debugCrossDayComputed, 1);
      expect(await LocalDb.baseline('crossday'), isNotNull);
    });

    test('the reused bundle equals a recomputed one', () async {
      final e = DerivationEngine();
      await _refresh(e);
      await e.runCrossDayForTest(profile);
      final kept = jsonDecode(await bundle()) as Map;
      await (await LocalDb.instance)
          .delete('baselines', where: 'key = ?', whereArgs: ['crossday']);
      await e.runCrossDayForTest(profile);
      final again = jsonDecode(await bundle()) as Map;
      kept.remove('built_at_epoch');
      again.remove('built_at_epoch');
      expect(jsonEncode(again), jsonEncode(kept));
    });
  });
}
