// P4c: the staleness line on a screen (Sleep detail stands for the nine that
// place AsOfLabel).
//
// ASSUMED API (see staleness_text_test.dart for the formatter):
//
//   LocalRepository.dayRecordingsThrough(String day) -> Future<DateTime?>
//       (day_recordings_through_test.dart). The screen asks it for the day it
//       shows, once per load of that day.
//   AppState (lib/state/app_state.dart):
//       StaleHold? get staleHold            // staleHoldOf(scheduler.snapshot())
//       DateTime? get lastRecordAt          // exists: SyncController.lastRecTs
//       @visibleForTesting DeriveScheduler get debugDeriveScheduler
//       @visibleForTesting set debugLastRecTs(int? epochSeconds)
//     The scheduler already ticks `notifyListeners` on every hold transition
//     (`onChanged`), so the line follows a hold appearing / clearing with NO
//     database read.
//
// RULES PINNED (Sleep detail, a night is on screen with computed_at 08:42, its
// recordings run through 08:36):
//   * newer recordings exist (lastRecordAt 08:50) AND derive work is held ->
//     the line shows, key 'as-of-label', "Updated 08:42 · recordings through
//     08:36 · <reason>"; Paused during workout for a live workout, Waiting for
//     sync to finish for an offload.
//   * the hold clearing removes the line (no recalc is running, nothing stale
//     is explained), without a reload.
//   * a hold with NO newer recordings (lastRecordAt == recordings-through): no
//     line, there is nothing to explain.
//   * the day's recordings-through unknown (null): no line, whatever is held
//     (never claims newer data it cannot compare).
//   * no hold, no recalc, idle: no line (today's behaviour, unchanged).
//   * while a pass recalculates the shown day the line uses the SAME format
//     ("Updated 08:42 · recordings through 08:36"), not the bare "As of 08:42",
//     when the recordings-through is known; it stays "As of 08:42" when not.
//
// Failure mode today: the new AppState members and dayRecordingsThrough do not
// exist (NoSuchMethodError through dynamic); with them the line is never drawn.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/recalc_state.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import '../fix8ai/support/g1_db.dart';
import '../perf/support/perf_fakes.dart';

const _db = 'p4c_staleness_screen_test.db';
final _label = find.byKey(const ValueKey('as-of-label'));

class _Repo extends SleepRepo {
  _Repo({super.computedAt, this.through});
  DateTime? through;
  final asked = <String>[];

  @override
  Future<DateTime?> dayRecordingsThrough(String day) async {
    asked.add(day);
    return through;
  }
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

Future<AppState> _open(WidgetTester t, _Repo repo,
    {int? newestSec, void Function(AppState a)? arrange}) async {
  _tall(t);
  await t.runAsync(() => g1FreshDb(_db));
  LastResultCache.instance.clear();
  final app = AppState.forTesting()..repo = repo;
  addTearDown(app.dispose);
  if (newestSec != null) (app as dynamic).debugLastRecTs = newestSec;
  arrange?.call(app);
  await t.pumpWidget(perfApp(app, SleepDetail(day: yesterdayId)));
  await settle(t, n: 15);
  return app;
}

dynamic _sched(AppState a) => (a as dynamic).debugDeriveScheduler;

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

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDownAll(() => g1DropDb(_db));

  const line = 'Updated 08:42 · recordings through 08:36';

  testWidgets('newer recordings + a live workout: the line says why',
      (t) async {
    final repo = _Repo(computedAt: todayAtMs(8, 42), through: _at(8, 36));
    final app = await _open(t, repo,
        newestSec: _sec(_at(8, 50)),
        arrange: (a) => _sched(a).setWorkoutActive(true));

    expect(repo.asked, isNotEmpty);
    expect(repo.asked.first, yesterdayId, reason: 'the day the screen shows');
    expect(t.widget<Text>(_label).data, '$line · Paused during workout');

    _sched(app).setWorkoutActive(false); // cancels the hold-cap timer
    await t.pump();
    await _settleDb(t);
  });

  testWidgets('newer recordings + an offload: waiting for sync', (t) async {
    final repo = _Repo(computedAt: todayAtMs(8, 42), through: _at(8, 36));
    final app = await _open(t, repo,
        newestSec: _sec(_at(8, 50)),
        arrange: (a) => _sched(a).setOffloadActive(true));
    expect(t.widget<Text>(_label).data, '$line · Waiting for sync to finish');
    _sched(app).setOffloadActive(false);
    await t.pump();
    await _settleDb(t);
  });

  testWidgets('the hold clearing removes the line, with no further read',
      (t) async {
    final repo = _Repo(computedAt: todayAtMs(8, 42), through: _at(8, 36));
    final app = await _open(t, repo,
        newestSec: _sec(_at(8, 50)),
        arrange: (a) => _sched(a).setWorkoutActive(true));
    expect(_label, findsOneWidget);
    final reads = repo.asked.length;

    _sched(app).setWorkoutActive(false);
    await t.pump();
    await _settleDb(t);
    expect(_label, findsNothing,
        reason: 'nothing is held and nothing recalculates');
    expect(repo.asked.length, reads, reason: 'it listens to the scheduler, '
        'not to the database');
  });

  testWidgets('a hold appearing later shows the line without a reload',
      (t) async {
    final repo = _Repo(computedAt: todayAtMs(8, 42), through: _at(8, 36));
    final app = await _open(t, repo, newestSec: _sec(_at(8, 50)));
    expect(_label, findsNothing);
    final reads = repo.asked.length;

    _sched(app).setOffloadActive(true);
    await t.pump();
    expect(t.widget<Text>(_label).data, '$line · Waiting for sync to finish');
    expect(repo.asked.length, reads);

    _sched(app).setOffloadActive(false);
    await t.pump();
    await _settleDb(t);
  });

  testWidgets('a hold but no newer recordings: nothing to explain',
      (t) async {
    final repo = _Repo(computedAt: todayAtMs(8, 42), through: _at(8, 36));
    final app = await _open(t, repo,
        newestSec: _sec(_at(8, 36)),
        arrange: (a) => _sched(a).setWorkoutActive(true));
    expect(_label, findsNothing);
    _sched(app).setWorkoutActive(false);
    await t.pump();
    await _settleDb(t);
  });

  testWidgets('recordings-through unknown: no line, whatever is held',
      (t) async {
    final repo = _Repo(computedAt: todayAtMs(8, 42), through: null);
    final app = await _open(t, repo,
        newestSec: _sec(_at(8, 50)),
        arrange: (a) => _sched(a).setWorkoutActive(true));
    expect(_label, findsNothing);
    expect(find.textContaining('Paused during workout'), findsNothing);
    _sched(app).setWorkoutActive(false);
    await t.pump();
    await _settleDb(t);
  });

  testWidgets('idle, nothing held, nothing recalculating: no line (unchanged)',
      (t) async {
    final repo = _Repo(computedAt: todayAtMs(8, 42), through: _at(8, 36));
    await _open(t, repo, newestSec: _sec(_at(8, 50)));
    expect(_label, findsNothing);
  });

  testWidgets('while the shown day recalculates: the same format, with what '
      'the recordings cover', (t) async {
    final repo = _Repo(computedAt: todayAtMs(8, 42), through: _at(8, 36));
    final app = await _open(t, repo, newestSec: _sec(_at(8, 36)));
    app.debugSetRecalc(RecalcState(
        days: {yesterdayId}, passStartedAt: _at(8, 55), crossDay: false));
    await t.pump();
    expect(t.widget<Text>(_label).data, line);
  });

  testWidgets('while recalculating with recordings-through unknown: the '
      'bare "As of", as before', (t) async {
    final repo = _Repo(computedAt: todayAtMs(8, 42), through: null);
    final app = await _open(t, repo);
    app.debugSetRecalc(RecalcState(
        days: {yesterdayId}, passStartedAt: _at(8, 55), crossDay: false));
    await t.pump();
    expect(t.widget<Text>(_label).data, 'As of 08:42');
  });
}
