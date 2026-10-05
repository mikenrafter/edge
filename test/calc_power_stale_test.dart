// The staleness line learns the "Waiting for power" reason.
//
// API (new; see calc_power_wiring_test.dart for the rest)
//
//   StaleHold gains `power` (lib/state/recalc_state.dart):
//       enum StaleHold { workout, sync, background, power }
//   staleHoldOf(snapshot): `snapshot['power_hold'] == true` -> StaleHold.power,
//       AFTER the others: workout, then sync (offload / manual sync), then
//       background, then power. No `power_hold` key (or false) = unchanged.
//   stalenessText: StaleHold.power -> 'Waiting for power', said under the same
//       rule as the other reasons (a hold AND both times known AND the newest
//       recording strictly after what the result covers).
//   DeriveScheduler.setPowerHold(bool)       (calc_power_wiring_test.dart)
//   AppState.setCalcPowerMode / debugPowerSource / debugAttachPower
//
// The earlier test 'no text, in any state, ever mentions power (the power
// hold owns that)' in test/calc_staleness_text_test.dart is superseded by this file and
// has to be updated alongside the implementation.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/as_of.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import 'support/last_result_db.dart';
import 'support/as_of_recalc_fakes.dart';
import 'support/fake_power_source.dart';

const _db = 'power_staleness_test.db';
final _label = find.byKey(const ValueKey('as-of-label'));

final _upd = DateTime(2026, 10, 3, 8, 42);
final _thr = DateTime(2026, 10, 3, 8, 36);
final _newer = DateTime(2026, 10, 3, 8, 50);
final _now = DateTime(2026, 10, 3, 9, 0);

Map<String, dynamic> _snap({
  bool workout = false,
  bool expired = false,
  bool offload = false,
  bool manual = false,
  bool background = false,
  bool? power,
}) =>
    {
      'offload_active': offload,
      'workout_active': workout,
      'workout_hold_expired': expired,
      'background': background,
      'running': false,
      'pending_light': true,
      'pending_heavy': false,
      'manual_sync_hold': manual,
      'power_hold': ?power,
    };

class _Repo extends SleepRepo {
  _Repo({super.computedAt, this.through});
  DateTime? through;
  @override
  Future<DateTime?> dayRecordingsThrough(String day) async => through;
}

DateTime _at(int h, int m) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day, h, m);
}

int _sec(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(390 * 3, 2600 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Future<AppState> _open(WidgetTester t, _Repo repo) async {
  _tall(t);
  await t.runAsync(() => g1FreshDb(_db));
  LastResultCache.instance.clear();
  final app = AppState.forTesting()..repo = repo;
  addTearDown(app.dispose);
  (app as dynamic).debugLastRecTs = _sec(_at(8, 50));
  await t.pumpWidget(perfApp(app, SleepDetail(day: yesterdayId)));
  await settle(t, n: 15);
  return app;
}

/// Lets the database reads a hold release started finish. They begin inside the
/// test's fake-async zone, so their replies are only delivered by a pump after
/// real time has passed; a read still in flight when the next test (or
/// tearDownAll) closes the database holds its lock, and the close never ends.
/// (A query of our own cannot wait behind it: it would need that pump too.)
Future<void> _settleDb(WidgetTester t) async {
  for (var i = 0; i < 3; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  setUp(() async => (await SharedPreferences.getInstance()).clear());
  tearDownAll(() => g1DropDb(_db));

  group('staleHoldOf', () {
    test('power_hold alone is the power reason', () {
      expect(staleHoldOf(_snap(power: true)), StaleHold.power);
    });

    test('no key, or false: no hold (today\'s snapshots are unchanged)', () {
      expect(staleHoldOf(_snap()), isNull);
      expect(staleHoldOf(_snap(power: false)), isNull);
      expect(staleHoldOf(const {}), isNull);
    });

    test('every other reason wins over power, in the existing order', () {
      expect(staleHoldOf(_snap(workout: true, power: true)), StaleHold.workout);
      expect(staleHoldOf(_snap(offload: true, power: true)), StaleHold.sync);
      expect(staleHoldOf(_snap(manual: true, power: true)), StaleHold.sync);
      expect(
          staleHoldOf(_snap(background: true, power: true)), StaleHold.background);
      expect(staleHoldOf(_snap(workout: true, expired: true, power: true)),
          StaleHold.power,
          reason: 'a lapsed workout hold no longer counts');
    });
  });

  group('stalenessText', () {
    String? text({DateTime? newest, DateTime? through, StaleHold? hold}) =>
        stalenessText(
            updatedAt: _upd,
            recordingsThrough: through ?? _thr,
            newestRecording: newest,
            hold: hold,
            now: _now);

    test('newer recordings wait on power: the reason is said', () {
      expect(text(newest: _newer, hold: StaleHold.power),
          'Updated 08:42 · recordings through 08:36 · Waiting for power');
    });

    test('no newer recordings: nothing to explain, even under a power hold',
        () {
      expect(text(newest: _thr, hold: StaleHold.power),
          'Updated 08:42 · recordings through 08:36');
      expect(text(hold: StaleHold.power),
          'Updated 08:42 · recordings through 08:36');
    });

    test('recordings-through unknown: no claim of newer data', () {
      expect(
          stalenessText(
              updatedAt: _upd,
              newestRecording: _newer,
              hold: StaleHold.power,
              now: _now),
          'Updated 08:42');
    });

    test('the other three reasons keep their words', () {
      expect(text(newest: _newer, hold: StaleHold.workout),
          endsWith('Paused during workout'));
      expect(text(newest: _newer, hold: StaleHold.sync),
          endsWith('Waiting for sync to finish'));
      expect(text(newest: _newer, hold: StaleHold.background),
          endsWith('Paused in the background'));
    });
  });

  group('on a screen', () {
    const line = 'Updated 08:42 · recordings through 08:36';

    testWidgets('a power hold with newer recordings shows the line; releasing '
        'it clears it, with no further read', (t) async {
      final repo = _Repo(computedAt: todayAtMs(8, 42), through: _at(8, 36));
      final app = await _open(t, repo);
      final sched = (app as dynamic).debugDeriveScheduler;
      expect(_label, findsNothing);

      sched.setPowerHold(true);
      await t.pump();
      expect(t.widget<Text>(_label).data, '$line · Waiting for power');

      sched.setPowerHold(false);
      await t.pump();
      await _settleDb(t);
      expect(_label, findsNothing);
    });

    testWidgets('a power hold with no newer recordings: no line', (t) async {
      final repo = _Repo(computedAt: todayAtMs(8, 42), through: _at(8, 50));
      final app = await _open(t, repo);
      (app as dynamic).debugDeriveScheduler.setPowerHold(true);
      await t.pump();
      expect(_label, findsNothing);
      (app as dynamic).debugDeriveScheduler.setPowerHold(false);
      await t.pump();
      await _settleDb(t);
    });

    testWidgets('end to end: Maximum battery, unplugged, saver on, newer '
        'recordings waiting: the screen says Waiting for power; plugging in '
        'clears it', (t) async {
      final repo = _Repo(computedAt: todayAtMs(8, 42), through: _at(8, 36));
      final app = await _open(t, repo);
      final power = FakePowerSource(charging: false, powerSaver: true);
      (app as dynamic).debugPowerSource = power;
      await t.runAsync(() async {
        await (app as dynamic).setCalcPowerMode(CalcPowerMode.maxBattery);
        await (app as dynamic).debugAttachPower();
      });
      await t.pump();
      expect(t.widget<Text>(_label).data, '$line · Waiting for power');

      power.plug();
      await t.pump();
      expect(_label, findsNothing, reason: 'plugged in: the work is released');
      await t.runAsync(power.close);
    });

    testWidgets('balanced, same power state: never a power reason', (t) async {
      final repo = _Repo(computedAt: todayAtMs(8, 42), through: _at(8, 36));
      final app = await _open(t, repo);
      (app as dynamic).debugPowerSource =
          FakePowerSource(charging: false, powerSaver: true);
      await t.runAsync(() async {
        await (app as dynamic).setCalcPowerMode(CalcPowerMode.balanced);
        await (app as dynamic).debugAttachPower();
      });
      await t.pump();
      expect(_label, findsNothing);
    });
  });
}
