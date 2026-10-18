import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/demo/demo_data_generator.dart';
import 'package:openstrap_edge/gps/route_models.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
}

Future<void> _day(String date, int version, String source, double readiness) =>
    LocalDb.putDayResult(
      dayId: date,
      algoVersion: version,
      payloadJson: jsonEncode({
        'scalars': {'readiness': readiness},
        'synthetic_fixture': true,
      }),
      windowJson: '{}',
      finalized: true,
      readiness: readiness,
      series: {'readiness': readiness},
      source: source,
    );
Future<void> _session(String id, String source) async {
  await LocalDb.putSession({
    'id': id,
    'start_ts': 1000,
    'end_ts': 1200,
    'type': 'running',
    'status': 'done',
    'source': source,
    'created_at': 1000000,
  });
  await LocalDb.appendRoutePoints(id, [
    const RoutePoint(seq: 0, tsMs: 1000000, lat: 38.5, lng: -98).toRow(id),
  ]);
  await LocalDb.putWorkoutSplits(id, [
    {
      'km': 1,
      'meters': 1000.0,
      'duration_sec': 200,
      'avg_hr': 100.0,
      'net_elev_m': null,
    },
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('edge_demo_purge_');
    PathProviderPlatform.instance = _Paths(temp.path);
    LocalDb.dbName = '${temp.path}/fixture.db';
    await LocalDb.instance;
  });
  tearDown(() async {
    await LocalDb.close();
    await temp.delete(recursive: true);
  });

  for (final source in ['band', 'oura']) {
    test(
      'purge preserves earlier $source immutable version on the demo date',
      () async {
        const date = '2026-09-28';
        await _day(date, 90, source, 64);
        await _day(date, 97, 'demo', 88);
        final db = await LocalDb.instance;
        final before = await db.query(
          'day_result',
          where: 'day_id = ? AND algo_version = ?',
          whereArgs: [date, 90],
        );
        expect(before, hasLength(1));
        await DemoDataGenerator.purge();
        final survivors = await db.query(
          'day_result',
          where: 'day_id = ?',
          whereArgs: [date],
        );
        expect(
          survivors,
          hasLength(1),
          reason: 'date-only DELETE destroys unrelated immutable versions',
        );
        expect(
          survivors.single,
          before.single,
          reason: 'real/imported payload and metadata stay byte-for-byte',
        );
        final scalars = await db.query(
          'metric_series',
          where: 'date = ?',
          whereArgs: [date],
        );
        // Series storage has no version history. Recovery is optional, fabrication
        // is not: retained real readiness may be restored, otherwise show absent.
        expect(
          scalars.where((r) => r['key'] == 'readiness').map((r) => r['value']),
          anyOf(isEmpty, orderedEquals([64.0])),
        );
        final provenance = await db.query(
          'metric_series_version',
          where: 'date = ?',
          whereArgs: [date],
        );
        expect(provenance.where((r) => r['source'] == 'demo'), isEmpty);
        await DemoDataGenerator.purge();
        expect(
          await db.query('day_result', where: 'day_id = ?', whereArgs: [date]),
          survivors,
          reason: 'repeat cleanup is idempotent',
        );
      },
    );
  }
  test(
    'purge removes demo-only rows, sessions/routes/splits while preserving non-demo data',
    () async {
      await _day('2026-09-27', 90, 'band', 63);
      await _day('2026-09-28', 97, 'demo', 87);
      await _session('real-session', 'manual');
      await _session('demo-session', 'demo');
      final db = await LocalDb.instance;
      final before = <String, List<Map<String, Object?>>>{};
      for (final table in [
        'day_result',
        'metric_series',
        'metric_series_version',
      ]) {
        before[table] = await db.query(
          table,
          where: table == 'day_result' ? 'day_id = ?' : 'date = ?',
          whereArgs: ['2026-09-27'],
        );
      }
      final realSession = await LocalDb.session('real-session');
      final realRoute = await LocalDb.routePoints('real-session');
      final realSplits = await LocalDb.workoutSplits('real-session');
      for (var iteration = 0; iteration < 2; iteration++) {
        await DemoDataGenerator.purge();
        for (final table in before.keys) {
          expect(
            await db.query(
              table,
              where: table == 'day_result' ? 'day_id = ?' : 'date = ?',
              whereArgs: ['2026-09-27'],
            ),
            before[table],
          );
          expect(
            await db.query(
              table,
              where: table == 'day_result' ? 'day_id = ?' : 'date = ?',
              whereArgs: ['2026-09-28'],
            ),
            isEmpty,
          );
        }
        expect(await LocalDb.session('demo-session'), isNull);
        expect(await LocalDb.routePoints('demo-session'), isEmpty);
        expect(await LocalDb.workoutSplits('demo-session'), isEmpty);
        expect(await LocalDb.session('real-session'), realSession);
        expect(await LocalDb.routePoints('real-session'), realRoute);
        expect(await LocalDb.workoutSplits('real-session'), realSplits);
      }
    },
  );
}
