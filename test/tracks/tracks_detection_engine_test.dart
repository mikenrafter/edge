import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/tracks_store.dart';

// The real derive, end to end: a stored day goes in, the review list is
// filled by the running app's own path. No detection window is supplied.

/// 09:00-17:00 local at rest (constant gravity), heart rate [hrAt] by hour.
Substrate restingDay(int date, int Function(int hour) hrAt) {
  final start = DateTime(2026, 4, date, 9).millisecondsSinceEpoch ~/ 1000;
  const n = 8 * 3600;
  final ts = [for (var i = 0; i < n; i++) start + i];
  return Substrate(
    tsSec: ts,
    hr: [for (var i = 0; i < n; i++) hrAt(9 + i ~/ 3600) + (i % 3)],
    rrTsMs: const [],
    rrMs: const [],
    ax: List.filled(n, 0),
    ay: List.filled(n, 0),
    az: List.filled(n, 1),
    spo2Red: List.filled(n, 0),
    spo2Ir: List.filled(n, 0),
    skinTemp: List.filled(n, 3000),
    skinContact: List.filled(n, 0),
    deviceFamily: 'gen4',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_tracks_detection_engine.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() => LocalDb.close());
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<List<Map<String, Object?>>> derive(int date, int Function(int) hrAt) async {
    final label = '2026-04-${date.toString().padLeft(2, '0')}';
    final db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': 0});
    await db.delete('activity_suggestions');
    await TracksStore(db).saveDefinition(
      const TrackDefinition(
        id: 'cannabis',
        name: 'Cannabis',
        icon: 'leaf',
        kind: 'consumed',
        roles: ['detectable'],
        systems: ['hr'],
      ),
    );
    await DerivationEngine().deriveImportedDays(
      restingDay(date, hrAt),
      const Profile(),
      {label},
    );
    return db.query('activity_suggestions', where: "kind = 'track'");
  }

  test('a still hour 20 bpm above the day puts a cannabis candidate in review',
      () async {
    final rows = await derive(10, (h) => h == 14 ? 92 : 70);
    expect(rows, hasLength(1));
    expect(rows.single['day_id'], '2026-04-10');
    expect(rows.single['status'], 'pending');
    expect(
      rows.single['start_ts'],
      DateTime(2026, 4, 10, 14).millisecondsSinceEpoch ~/ 1000,
    );
    expect(rows.single['details_json'], contains('"track_id":"cannabis"'));
  });

  test('a flat day has no candidate', () async {
    expect(await derive(11, (_) => 70), isEmpty);
  });

  // R2-1: the night began the previous evening. The calendar day's hr_curve
  // holds none of 22:00-24:00, so the early-sleep window needs the sleep
  // window's own minutes.
  test('an alcohol-like night that began the previous evening is detected',
      () async {
    final db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': 0});
    await db.delete('activity_suggestions');
    await TracksStore(db).saveDefinition(
      const TrackDefinition(
        id: 'alcohol',
        name: 'Alcohol',
        icon: 'wine',
        kind: 'consumed',
        roles: ['detectable'],
        systems: ['hr', 'hrv'],
      ),
    );
    for (var d = 1; d <= 8; d++) {
      final date = '2026-05-${(10 - d).toString().padLeft(2, '0')}';
      await db.insert('metric_series', {'date': date, 'key': 'rhr', 'value': 55.0});
      await db.insert('metric_series', {'date': date, 'key': 'rmssd', 'value': 55.0});
    }
    final start = DateTime(2026, 5, 9, 18).millisecondsSinceEpoch ~/ 1000;
    final onset = DateTime(2026, 5, 9, 22).millisecondsSinceEpoch ~/ 1000;
    final earlyEnd = onset + 3 * 3600;
    final wake = DateTime(2026, 5, 10, 7).millisecondsSinceEpoch ~/ 1000;
    final end = DateTime(2026, 5, 10, 12).millisecondsSinceEpoch ~/ 1000;
    final n = end - start;
    final ts = [for (var i = 0; i < n; i++) start + i];
    int hrAt(int t) => t < onset ? 80 : (t < earlyEnd ? 68 : (t < wake ? 52 : 80));
    final rrTs = <double>[], rr = <double>[];
    var clock = onset * 1000.0;
    var flip = false;
    while (clock < wake * 1000) {
      final spread = clock < earlyEnd * 1000 ? 30.0 : 70.0;
      final v = 1000.0 + (flip ? spread : 0);
      flip = !flip;
      clock += v;
      rrTs.add(clock);
      rr.add(v);
    }
    final sub = Substrate(
      tsSec: ts,
      hr: [for (final t in ts) hrAt(t)],
      rrTsMs: rrTs,
      rrMs: rr,
      ax: List.filled(n, 0),
      ay: List.filled(n, 0),
      az: [for (final t in ts) (t >= onset && t < wake) ? 1.0 : 1.0 + 0.3 * ((t % 7) / 7)],
      spo2Red: List.filled(n, 0),
      spo2Ir: List.filled(n, 0),
      skinTemp: List.filled(n, 3000),
      skinContact: List.filled(n, 0),
      deviceFamily: 'gen4',
    );
    await DerivationEngine().deriveImportedDays(sub, const Profile(), {'2026-05-10'});
    final row = await LocalDb.dayResult('2026-05-10');
    // Positive control: the derive found the night, so the test exercises it.
    expect(row!['window_json'], contains('onset'));
    final rows = await db.query('activity_suggestions', where: "kind = 'track'");
    expect(rows, hasLength(1));
    expect(
      (rows.single['start_ts'] as int) - onset,
      inInclusiveRange(0, 600),
      reason: 'the detected onset, minutes after the first sample of sleep',
    );
    expect(rows.single['details_json'], contains('"track_id":"alcohol"'));
    expect(rows.single['details_json'], contains('"exposure_date":"2026-05-09"'));
  });

  // R2-6: tonight's sleep and a known nap are not awake time. They are low
  // heart-rate hours; counted as resting daytime they would drag the day's
  // baseline down and turn ordinary awake hours into a "jump" (cannabis).
  test('tonight sleep and a manual nap are excluded from awake windows', () async {
    final db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': 0});
    await db.delete('activity_suggestions');
    await TracksStore(db).saveDefinition(
      const TrackDefinition(
        id: 'cannabis',
        name: 'Cannabis',
        icon: 'leaf',
        kind: 'consumed',
        roles: ['detectable'],
        systems: ['hr'],
      ),
    );
    int at(int day, int h) => DateTime(2026, 6, day, h).millisecondsSinceEpoch ~/ 1000;
    final start = at(1, 12), end = at(2, 10);
    final nightOnset = at(1, 22), nightWake = at(2, 7);
    final napStart = at(1, 12), napEnd = at(1, 15);
    final n = end - start;
    final ts = [for (var i = 0; i < n; i++) start + i];
    bool asleep(int t) => t >= nightOnset && t < nightWake;
    bool napping(int t) => t >= napStart && t < napEnd;
    await db.insert('sleep_nap', {
      'day_id': '2026-06-01',
      'created_at': 1,
      'start_ts': napStart,
      'end_ts': napEnd,
      'source': 'manual',
    });
    final rrTs = <double>[], rr = <double>[];
    var clock = nightOnset * 1000.0;
    var flip = false;
    while (clock < nightWake * 1000) {
      final v = 1000.0 + (flip ? 60 : 0);
      flip = !flip;
      clock += v;
      rrTs.add(clock);
      rr.add(v);
    }
    final sub = Substrate(
      tsSec: ts,
      hr: [for (final t in ts) asleep(t) ? 52 : (napping(t) ? 50 : 88)],
      rrTsMs: rrTs,
      rrMs: rr,
      ax: List.filled(n, 0),
      ay: List.filled(n, 0),
      // Awake: a brief tilt about 3% of the time. Asleep and napping: still.
      az: [
        for (final t in ts)
          (asleep(t) || napping(t))
              ? 1.0
              : (t >= nightWake || t >= at(1, 20)
                  ? 1.0 + 0.3 * ((t % 7) / 7)
                  : (t % 60 < 2 ? 1.3 : 1.0)),
      ],
      spo2Red: List.filled(n, 0),
      spo2Ir: List.filled(n, 0),
      skinTemp: List.filled(n, 3000),
      skinContact: List.filled(n, 0),
      deviceFamily: 'gen4',
    );
    await DerivationEngine().deriveImportedDays(sub, const Profile(), {'2026-06-01', '2026-06-02'});
    final row = await LocalDb.dayResult('2026-06-01');
    expect(row, isNotNull);
    final rows = await db.query('activity_suggestions', where: "kind = 'track'");
    expect(rows, isEmpty);
  });
}
