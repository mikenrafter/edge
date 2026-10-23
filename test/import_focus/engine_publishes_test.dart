// Import focus: the engine publishes TODAY's and YESTERDAY's read models to
// ImportFocus.days right after it derives each, and only those two, and only
// while focus is active (no screen can read the database meanwhile).
//
// Lightest setup that derives a day: raw 1 Hz rows (the helper of
// settled_validity_test.dart) and DerivationEngine.runDays.
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/import_focus.dart';

const _profile = Profile(
  ageYears: 35,
  sex: 'm',
  weightKg: 75,
  heightCm: 178,
  restingHrManual: 55,
);

int _localSec(String day, int hour) {
  final d = DateTime.parse(day);
  return DateTime(d.year, d.month, d.day, hour).millisecondsSinceEpoch ~/ 1000;
}

Future<void> _insertDay(String day, {int wakeMin = 400, int hour = 9}) async {
  final db = await LocalDb.instance;
  final start = _localSec(day, hour);
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

Future<bool> _hasResult(String day) async => (await (await LocalDb.instance)
        .query('day_result', where: 'day_id = ?', whereArgs: [day]))
    .isNotEmpty;

Future<void> _clear() async {
  final db = await LocalDb.instance;
  for (final t in const [
    'decoded_onehz',
    'decoded_rr',
    'day_result',
    'metric_series',
    'metric_series_version',
    'compute_freshness',
    'sleep_override',
  ]) {
    await db.delete(t);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String today;
  late String yesterday;
  late String older;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_import_focus_engine_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    today = todayLabel();
    yesterday = dayLabelBefore(today, 1)!;
    older = dayLabelBefore(today, 3)!;
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  setUp(() async {
    ImportFocus.debugReset();
    await _clear();
    await _insertDay(older);
    await _insertDay(yesterday);
    await _insertDay(today, wakeMin: 90, hour: 0);
  });
  tearDown(ImportFocus.debugReset);

  const slow = Timeout(Duration(minutes: 8));

  test('during focus, a derive of today and yesterday publishes both',
      () async {
    ImportFocus.enter();
    await DerivationEngine()
        .runDays(_profile, {older, yesterday, today}, force: true);

    expect(await _hasResult(yesterday), isTrue,
        reason: 'precondition: yesterday was derived and stored');
    expect(await _hasResult(today), isTrue,
        reason: 'precondition: today was derived and stored');
    final days = ImportFocus.days.value;
    expect(days.keys.toSet(), {today, yesterday},
        reason: 'exactly those two; an older day is never published');
    expect(days[today], isNotEmpty);
    expect(days[yesterday], isNotEmpty);
  }, timeout: slow);

  test('the days notifier fires as each one is published', () async {
    final seen = <Set<String>>[];
    void l() => seen.add(ImportFocus.days.value.keys.toSet());
    ImportFocus.days.addListener(l);
    addTearDown(() => ImportFocus.days.removeListener(l));
    ImportFocus.enter();
    await DerivationEngine().runDays(_profile, {yesterday, today}, force: true);
    expect(seen, isNotEmpty);
    expect(seen.last, {today, yesterday});
  }, timeout: slow);

  test('with no import running, nothing is published', () async {
    await DerivationEngine().runDays(_profile, {yesterday, today}, force: true);
    expect(await _hasResult(yesterday), isTrue,
        reason: 'precondition: the derive ran');
    expect(ImportFocus.days.value, isEmpty);
  }, timeout: slow);
}
