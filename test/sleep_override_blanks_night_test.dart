// "Not sleep" and a user-set window that the band cannot back must BLANK the
// night, and the blank must hold.
//
// The reported bug: pressing "Not sleep", or setting the times by hand, left
// the night's old sleep numbers on screen and in the scores. Three stores kept
// them:
//   * the edge#305 guard in `_derivePreparedDay` ("never write night-null over
//     night-real") treated the user's own blanking as a pruned-raw regression
//     and declined to write, so the old `day_result` kept being served;
//   * `metric_series` is REPLACE-per-key, so any sleep key the new derive does
//     not write (a retired key, e.g. `odi_per_hour`) kept its old row;
//   * the frozen morning-readiness pin kept serving the old readiness.
//
// Real LocalDb + real DerivationEngine, no mocks. Fixed local-time fixtures,
// never `DateTime.now()`.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _d1 = '2025-09-04';
const _d2 = '2025-09-05';

int _sec(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

/// Every sleep-derived key the night owns in `metric_series`, plus two RETIRED
/// keys (`odi_per_hour`, `spo2`) the current derive never writes — their old
/// rows are exactly what REPLACE-per-key cannot clean up.
const _sleepKeys = [
  'tst_min',
  'efficiency',
  'rem_min',
  'deep_min',
  'light_min',
  'rhr',
  'dip_pct',
  'midsleep_sec',
  'sleep_onset_sec',
  'sol_min',
  'awakenings',
  'longest_sleep_min',
  'unobserved_min',
  'odi_per_hour',
  'spo2',
];

late Database _db;

Future<void> _freshDb() async {
  await LocalDb.close();
  LocalDb.dbName = 'sleep_override_blanks_night_test.db';
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  _db = await LocalDb.instance;
}

/// Two quiet nights at 1 Hz (22:00 -> 08:00 on 09-03/04 and 09-04/05: still
/// wrist, low HR), and one lone reading on 09-06 as the data edge. Nothing is
/// recorded in the daytime, so a window set there is genuinely uncovered.
Future<void> _seed() async {
  final b = _db.batch();
  var c = 0;
  void run(int from, int to, int Function(int) hr) {
    for (var ts = from; ts < to; ts++) {
      b.insert('decoded_onehz', {
        'device_id': '',
        'ts_ms': ts * 1000,
        'rec_ts': ts,
        'counter': c++,
        'hr': hr(ts),
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
        'device_family': 'gen4',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  int night(int ts) => 52 + (ts % 7);
  run(_sec(2025, 9, 3, 22, 0), _sec(2025, 9, 4, 8, 0), night);
  run(_sec(2025, 9, 4, 22, 0), _sec(2025, 9, 5, 8, 0), night);
  run(_sec(2025, 9, 6, 12, 0), _sec(2025, 9, 6, 12, 1), (_) => 70);
  await b.commit(noResult: true);
}

Future<void> _derive(String day) =>
    DerivationEngine().runDays(const Profile(), {day}, force: true);

Future<void> _override(String day, int onset, int offset, String source) =>
    LocalDb.putSleepOverride(
      dayId: day,
      onsetTs: onset,
      offsetTs: offset,
      source: source,
    );

/// A real, computed night: the user confirms 23:30 -> 06:30 and it stages from
/// the samples inside that window.
Future<void> _realNight(String day, {required int prevDay}) async {
  await _override(
    day,
    _sec(2025, 9, prevDay, 23, 30),
    _sec(2025, 9, prevDay + 1, 6, 30),
    'confirmed',
  );
  await _derive(day);
}

Future<Map<String, dynamic>> _bundle(String day) async {
  final r = await LocalDb.dayResult(day);
  return jsonDecode(r!['payload_json'] as String) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> _scalars(String day) async =>
    ((await _bundle(day))['scalars'] as Map).cast<String, dynamic>();

Future<Map<String, double?>> _series(String day) async => {
      for (final r in await _db
          .query('metric_series', where: 'date = ?', whereArgs: [day]))
        r['key'] as String: (r['value'] as num?)?.toDouble(),
    };

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await _freshDb();
    await _seed();
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('fixture is not vacuous: a confirmed window really stages a night',
      () async {
    await _realNight(_d2, prevDay: 4);
    final sc = await _scalars(_d2);
    expect(sc['tst_min'], 420);
    expect(sc['rhr'], isNotNull);
    expect((await _series(_d2))['tst_min'], 420);
  });

  group('Not sleep', () {
    Future<void> reject() async {
      await _override(_d2, _sec(2025, 9, 4, 23, 30), _sec(2025, 9, 5, 6, 30),
          'rejected');
      await _derive(_d2);
    }

    test('blanks the served day: no scalar, column, stage or hypnogram',
        () async {
      await _realNight(_d2, prevDay: 4);
      await reject();

      final row = (await LocalDb.dayResult(_d2))!;
      expect(row['algo_version'], kAlgoVersion);
      expect(row['rhr'], isNull);
      expect(row['rmssd'], isNull);
      expect(row['readiness'], isNull);

      final bundle = await _bundle(_d2);
      expect(bundle['sleep_source'], 'rejected');
      final sc = (bundle['scalars'] as Map).cast<String, dynamic>();
      for (final k in [
        'tst_min',
        'efficiency',
        'rem_min',
        'deep_min',
        'light_min',
        'rhr',
        'dip_pct',
        'midsleep_sec',
        'sleep_onset_sec',
        'sol_min',
        'awakenings',
        'longest_sleep_min',
      ]) {
        expect(sc[k], isNull, reason: '$k must be blank after "Not sleep"');
      }
      expect(((bundle['series'] as Map)['hypnogram'] as List), isEmpty);
    });

    test('the repository read says "no night", reason rejected', () async {
      await _realNight(_d2, prevDay: 4);
      await reject();
      final repo = LocalRepositoryImpl(getProfileMap: () => {});
      final n = await repo.getDaySleep(_d2);
      expect(n['has_sleep'], isFalse);
      expect(n['sleep_source'], 'rejected');
      expect(n['duration_min'], isNull);
    });

    test('metric_series rows for the sleep keys are DELETED, including retired '
        'keys REPLACE can never overwrite', () async {
      await _realNight(_d2, prevDay: 4);
      // A key the current derive no longer writes: its old row would survive
      // a REPLACE-per-key write forever.
      await _db.insert('metric_series',
          {'date': _d2, 'key': 'odi_per_hour', 'value': 4.0});
      await _db
          .insert('metric_series', {'date': _d2, 'key': 'spo2', 'value': 96.0});
      expect((await _series(_d2))['tst_min'], 420);

      await reject();

      final series = await _series(_d2);
      for (final k in _sleepKeys) {
        expect(series.containsKey(k), isFalse,
            reason: '$k row must be gone, not NULL and not stale');
      }
      // Daytime facts of the same date are untouched.
      expect(series.containsKey('worn_min'), isTrue);
    });

    test('an OLDER-version row that still holds the night is not served',
        () async {
      await _realNight(_d2, prevDay: 4);
      final stale = (await LocalDb.dayResult(_d2))!;
      // Replay the pre-fix install: only an older version's row, full night.
      await _db.delete('day_result',
          where: 'day_id = ? AND algo_version = ?',
          whereArgs: [_d2, kAlgoVersion]);
      await LocalDb.putDayResult(
        dayId: _d2,
        algoVersion: kAlgoVersion - 1,
        payloadJson: stale['payload_json'] as String,
        windowJson: stale['window_json'] as String,
        rhr: (stale['rhr'] as num?)?.toDouble(),
      );
      await reject();
      final served = (await LocalDb.dayResult(_d2))!;
      expect(served['algo_version'], kAlgoVersion);
      expect((await _scalars(_d2))['tst_min'], isNull);
    });

    test('is idempotent: three more derives change nothing', () async {
      await _realNight(_d2, prevDay: 4);
      await reject();
      String snap(Map<String, dynamic> sc, Map<String, double?> s) =>
          jsonEncode([sc, s]);
      final first = snap(await _scalars(_d2), await _series(_d2));
      for (var i = 0; i < 3; i++) {
        await _derive(_d2);
        expect(snap(await _scalars(_d2), await _series(_d2)), first);
      }
    });

    test('a full pass and a later sync do not bring the old night back',
        () async {
      await _realNight(_d2, prevDay: 4);
      await reject();
      await DerivationEngine().run(const Profile(), force: true);
      expect((await _scalars(_d2))['tst_min'], isNull);
      expect((await _series(_d2)).containsKey('tst_min'), isFalse);
    });

    test('raw already pruned: the stored night is still blanked', () async {
      await _realNight(_d2, prevDay: 4);
      // Raw retention has passed for this day; only a later reading remains so
      // the engine has a data edge.
      await _db.delete('decoded_onehz',
          where: 'rec_ts < ?', whereArgs: [_sec(2025, 9, 6, 0, 0)]);
      await _db.delete('sleep_session_candidates');
      await reject();
      expect((await _scalars(_d2))['tst_min'], isNull);
      expect((await _series(_d2)).containsKey('tst_min'), isFalse);
      expect((await LocalDb.dayResult(_d2))!['rhr'], isNull);
      // The day's non-sleep content survived the blanking.
      expect((await _bundle(_d2))['date'], _d2);
    });

    test('clears the frozen morning-readiness pin for that day', () async {
      await _realNight(_d2, prevDay: 4);
      await LocalDb.setFrozenHeadline(_d2, 77);
      await reject();
      expect(await LocalDb.frozenHeadline(), isNull);
    });

    test('the cross-day input records the night as not recorded', () async {
      await _realNight(_d2, prevDay: 4);
      await reject();
      await DerivationEngine().run(const Profile(), force: true);
      final art = await LocalDb.baseline('crossday_input');
      final days = (jsonDecode(art!['payload_json'] as String)['days'] as List)
          .cast<Map>();
      final rec = days.firstWhere((r) => r['date'] == _d2);
      expect(rec['tst_min'], isNull);
      expect(rec['onset_sec'], isNull);
      expect(rec['rhr'], isNull);
    });

    test('the NEXT night\'s baseline no longer contains the blanked night',
        () async {
      await _realNight(_d1, prevDay: 3);
      await _realNight(_d2, prevDay: 4);
      int n(Map b) =>
          (((b['readiness_absent_diag'] as Map)['rhr'] as Map)['baseline_n']
                  as num)
              .toInt();
      expect(n(await _bundle(_d2)), 1, reason: 'sanity: D1 is in the baseline');

      await _override(_d1, _sec(2025, 9, 3, 23, 30), _sec(2025, 9, 4, 6, 30),
          'rejected');
      await DerivationEngine().rederiveAfterSleepEdit(const Profile(), _d1);

      expect((await _series(_d1)).containsKey('rhr'), isFalse);
      expect(n(await _bundle(_d2)), 0,
          reason: 'D2 was re-derived without the blanked night');
    });
  });

  group('a user-set window', () {
    test('over hours the band did not record: the old night is blanked, the '
        'saved window survives', () async {
      await _realNight(_d2, prevDay: 4);
      final onset = _sec(2025, 9, 5, 12, 30);
      final wake = _sec(2025, 9, 5, 15, 30);
      await _override(_d2, onset, wake, 'manual');
      await _derive(_d2);

      final sc = await _scalars(_d2);
      for (final k in ['tst_min', 'efficiency', 'rhr', 'rem_min']) {
        expect(sc[k], isNull, reason: k);
      }
      expect((await _series(_d2)).containsKey('tst_min'), isFalse);
      expect((await _series(_d2)).containsKey('rhr'), isFalse);
      expect((await LocalDb.dayResult(_d2))!['rhr'], isNull);

      final repo = LocalRepositoryImpl(getProfileMap: () => {});
      final n = await repo.getDaySleep(_d2);
      expect(n['has_sleep'], isFalse);
      expect(n['sleep_source'], 'manual');
      expect(n['onset_ts'], onset);
      expect(n['wake_ts'], wake);
    });

    test('over hours the band DID record: computed strictly from the window',
        () async {
      await _override(_d2, _sec(2025, 9, 5, 0, 0), _sec(2025, 9, 5, 5, 0),
          'manual');
      await _derive(_d2);
      expect((await _scalars(_d2))['tst_min'], 300,
          reason: 'five in-window hours, not the auto night\'s seven');
    });

    test('is idempotent too', () async {
      await _realNight(_d2, prevDay: 4);
      await _override(_d2, _sec(2025, 9, 5, 12, 30), _sec(2025, 9, 5, 15, 30),
          'manual');
      await _derive(_d2);
      final first = jsonEncode([await _scalars(_d2), await _series(_d2)]);
      for (var i = 0; i < 3; i++) {
        await _derive(_d2);
        expect(jsonEncode([await _scalars(_d2), await _series(_d2)]), first);
      }
    });
  });
}
