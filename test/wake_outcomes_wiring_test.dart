// Wake outcomes, AppState wiring (shadow mode). Real AppState and database;
// the recorder's own rules are in test/wake/outcomes/wake_outcome_recorder_test
// .dart.
//  - gated off (flag off, or developer mode off): nothing is written and Home
//    has nothing to ask;
//  - gated on: a closed wake in the trace store becomes one stored outcome, a
//    rating survives running it again, and Home's pending outcome follows;
//  - the app opening is the foreground catch-up for a wake it was dead for;
//  - Home draws the card in both of its branches, null-safe like the Natural
//    Wake card.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/wake/outcomes/wake_outcome.dart';
import 'package:openstrap_edge/wake/outcomes/wake_outcome_store.dart';
import 'package:openstrap_edge/wake/wake_stores.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_alarm_engine.dart';
import 'wake/outcomes/outcome_rig.dart';

const _dbName = 'openstrap_wake_outcomes_wiring_test.db';

Future<void> _wipe() async {
  await LocalDb.close();
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, _dbName));
}

Future<void> _seed(int wake, {int fireOffsetSec = -20 * 60}) async {
  const store = DbWakeTraceStore();
  for (final r in [
    ...naturalFire(wake, wake + fireOffsetSec),
    closedRow(wake, wake + 1),
  ]) {
    await store.append(r);
  }
}

Future<List<WakeOutcome>> _stored() => WakeOutcomeStore(
      read: LocalDb.wakeMetaGet,
      write: LocalDb.wakeMetaSet,
    ).load();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = _dbName;
  });

  late AppState app;
  var nowSec = kT + 3600;

  Future<void> boot({required bool dev, required bool flag}) async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    // Prefs caches its first SharedPreferences instance, so set, not seed.
    Prefs.setBool(Prefs.devMode, dev);
    Prefs.setBool(Prefs.exploreWakeOutcomes, flag);
    app = AppState.forTesting(engine: FakeAlarmEngine());
    app.debugBackground = false;
    app.debugWakeClock = () => DateTime.fromMillisecondsSinceEpoch(nowSec * 1000);
    addTearDown(app.dispose);
  }

  setUp(() async {
    await _wipe();
    nowSec = kT + 3600;
  });
  tearDownAll(_wipe);

  test('flag off: a closed wake writes nothing and Home has no card',
      () async {
    await boot(dev: true, flag: false);
    await _seed(kT);
    await app.debugRecordWakeOutcome(kT);
    expect(await LocalDb.wakeMetaGet(kWakeOutcomesKey), isNull);
    expect(app.pendingGrogginessOutcome, isNull);
    expect(app.wakeOutcomesOn, isFalse);
  });

  test('developer mode off: the flag alone does nothing', () async {
    await boot(dev: false, flag: true);
    await _seed(kT);
    await app.debugRecordWakeOutcome(kT);
    expect(await LocalDb.wakeMetaGet(kWakeOutcomesKey), isNull);
    expect(app.pendingGrogginessOutcome, isNull);
  });

  test('gated on: one outcome per wake, the rating survives a re-run, Home '
      'follows', () async {
    await boot(dev: true, flag: true);
    await _seed(kT);

    await app.debugRecordWakeOutcome(kT);
    var stored = await _stored();
    expect(stored, hasLength(1));
    expect(stored.single.wakeSec, kT);
    expect(stored.single.firedBy, WakeFiredBy.natural);
    expect(stored.single.delivered, isTrue);
    expect(app.pendingGrogginessOutcome?.wakeSec, kT,
        reason: 'delivered, unrated, an hour old: Home asks');

    await app.rateWakeOutcome(kT, 4);
    expect(app.pendingGrogginessOutcome, isNull, reason: 'rated: Home is done');

    await app.debugRecordWakeOutcome(kT);
    stored = await _stored();
    expect(stored, hasLength(1));
    expect(stored.single.grogginess, 4);
    expect(app.pendingGrogginessOutcome, isNull);
  });

  test('a wake nothing is known about (no fire, no close) stores nothing',
      () async {
    await boot(dev: true, flag: true);
    await const DbWakeTraceStore().append(row(kT, kT - 3600, 'plan', {}));
    await app.debugRecordWakeOutcome(kT);
    expect(await LocalDb.wakeMetaGet(kWakeOutcomesKey), isNull);
  });

  test('opening the app catches up on a wake it was dead for', () async {
    nowSec = kT + 3 * 3600;
    await boot(dev: true, flag: true);
    await _seed(kT);
    await app.noteAppOpened(at: DateTime.fromMillisecondsSinceEpoch(nowSec * 1000));
    await app.debugWakeSignalsSettled();
    expect((await _stored()).map((o) => o.wakeSec), [kT]);
    expect(app.pendingGrogginessOutcome?.wakeSec, kT);
  });

  test('switching the log off removes the prompt and deletes nothing',
      () async {
    await boot(dev: true, flag: true);
    await _seed(kT);
    await app.debugRecordWakeOutcome(kT);
    expect(app.pendingGrogginessOutcome, isNotNull);
    await app.setWakeOutcomesOn(false);
    expect(app.pendingGrogginessOutcome, isNull);
    expect(await _stored(), hasLength(1));
  });

  test('Home draws the card in both of its branches, null-safe without an '
      'AppState', () {
    final src = File('lib/ui2/screens/home_screen.dart').readAsStringSync();
    expect('?_grogginessCard(c),'.allMatches(src), hasLength(2));
    expect(src, contains('on ProviderNotFoundException'));
  });
}
