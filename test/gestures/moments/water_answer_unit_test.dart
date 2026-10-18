// The marked-moment Water answer takes the same unit-aware step as the
// steppers (RED).
//
// `MomentAnswerWriter.answer(m, MomentChoice.water)` adds ONE glass to the
// moment's day. Its size is the shared `WaterUnits.stepMl` for the saved units
// preference (SharedPreferences key `units_system`, the one UnitsController
// persists): metric 250 ml, imperial one US cup (8 fl oz, exact ml). The writer
// signature is unchanged (existing fakes override it), so the writer reads the
// saved preference itself. Stored amounts are always ml.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/water_units.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/state/units_controller.dart';

const _m = PendingMoment(date: '2026-10-06', hhmm: '10:15');
const _m2 = PendingMoment(date: '2026-10-06', hhmm: '15:40');
final _now = DateTime(2026, 10, 7, 12, 0);
const _writer = MomentAnswerWriter();
final _max = kJournalFieldsByKey['water_ml']!.max;

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

var _n = 0;
Future<void> _fresh(List<String> created) async {
  final name = 'openstrap_moment_water_unit_${_n++}.db';
  created.add(name);
  await LocalDb.close();
  await databaseFactory.deleteDatabase(await _path(name));
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  await LocalDb.instance;
  await LocalDb.putJournal(
      _m.date, '["moment 10:15","moment 15:40"]', 'a note');
}

Future<double?> _water() async =>
    (await LocalDb.journalMetricsForDay(_m.date))['water_ml']?.value;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final created = <String>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(() async {
    await LocalDb.close();
    for (final n in created) {
      await databaseFactory.deleteDatabase(await _path(n));
    }
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _fresh(created);
  });

  test('metric (or no preference saved): one 250 ml glass', () async {
    await _writer.answer(_m, MomentChoice.water, now: _now);
    expect(await _water(), 250);
  });

  test('imperial: one 8 fl oz cup, stored as its exact ml', () async {
    SharedPreferences.setMockInitialValues({'units_system': 'imperial'});
    await _writer.answer(_m, MomentChoice.water, now: _now);
    expect(await _water(), closeTo(WaterUnits.stepMl(UnitSystem.imperial), 1e-9));
    expect(await _water(), isNot(250));
  });

  test('two imperial glasses read as 16 fl oz, whole', () async {
    SharedPreferences.setMockInitialValues({'units_system': 'imperial'});
    await _writer.answer(_m, MomentChoice.water, now: _now);
    await _writer.answer(_m2, MomentChoice.water, now: _now);
    expect(WaterUnits.format((await _water())!, UnitSystem.imperial),
        '16 fl oz');
  });

  test('switching units later does not rewrite what was stored', () async {
    SharedPreferences.setMockInitialValues({'units_system': 'imperial'});
    await _writer.answer(_m, MomentChoice.water, now: _now);
    final stored = (await _water())!;
    expect(stored, closeTo(WaterUnits.stepMl(UnitSystem.imperial), 1e-9));
    SharedPreferences.setMockInitialValues({'units_system': 'metric'});
    await _writer.answer(_m2, MomentChoice.water, now: _now);
    expect(await _water(), closeTo(stored + 250, 1e-9));
  });

  test('imperial still clamps at the 6000 ml ceiling', () async {
    SharedPreferences.setMockInitialValues({'units_system': 'imperial'});
    await LocalDb.putJournalMetrics(_m.date, {
      'water_ml': JournalMetricValue(_max - 10, atMinuteOfDay: 60),
    });
    await _writer.answer(_m, MomentChoice.water, now: _now);
    expect(await _water(), _max);
  });

  test('still no amount accepted for Water', () async {
    expect(() => _writer.answer(_m, MomentChoice.water, value: 100, now: _now),
        throwsArgumentError);
  });
}
