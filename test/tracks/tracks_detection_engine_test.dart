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
}
