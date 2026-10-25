// Layout shift budget on Home when marked moments are waiting: Home's one
// Review activities card counts them, read from the real database (LocalDb), so this file uses a real
// sqflite_ffi database and lets it answer between fake-clock pumps.
//
// Time: every capture is stamped with the offset the test asked for. The test
// yields REAL time (runAsync) once so the database can answer; that real wait
// is never stamped (see _framesWithDb).
//
// Order matters: the "without moments" test runs first against the empty
// database; the later tests seed it.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import '../../support/as_of_recalc_fakes.dart';
import '../../support/shift_run.dart';

class _SlowHomeRepo extends HomeRepo {
  _SlowHomeRepo(super.today, {this.delayMs = 150});
  int delayMs;
  @override
  Future<Map<String, dynamic>> getToday() async {
    await Future<void>.delayed(Duration(milliseconds: delayMs));
    return super.getToday();
  }
}

Map<String, dynamic> _bundle(num readiness, int h, int m) => homeBundle(
    readiness: readiness, overnightAt: todayAtMs(h, m), activityAt: todayAtMs(h, m));

/// Lets the card's database reads finish WITHOUT moving the fake clock. Each
/// read's continuation runs in the test's fake zone, so it needs a pump (of
/// zero duration) after every real wait.
Future<void> _drainDb(WidgetTester t) async {
  for (var i = 0; i < 30; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    await t.pump();
  }
}

/// Like ShiftRun.frames, but yields real time so the real database can answer:
/// once, before the second pump, long enough for the moment card's three reads.
/// So the card is charged as landing at the first frame after open (before the
/// 150 ms fake Home read), which is an assumption: the real order depends on
/// the device's disk.
Future<void> _framesWithDb(WidgetTester t, ShiftRun run,
    [List<int> offsets = shiftOffsets]) async {
  final base = run.now;
  for (final o in offsets) {
    if (o == 16) await _drainDb(t);
    await t.pump(Duration(milliseconds: base + o - run.now));
    run.now = base + o;
    run.snap();
  }
}

Future<void> _enable(WidgetTester t, AppState app) => t.runAsync(() async {
      await app.gestureSettings.setFollowUpMoments(true,
          now: DateTime.now().subtract(const Duration(days: 3)));
    }) as Future<void>;

Future<void> _seed(WidgetTester t) => t.runAsync(() async {
      await LocalDb.putJournal(
          yesterdayId,
          jsonEncode(['moment 09:15', 'moment 10:05', 'moment 14:30']),
          '');
      await LocalDb.logAssumedWater(
          date: yesterdayId, atMin: 600, ml: 250, loggedAtMs: 1);
    }) as Future<void>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const dbName = 'openstrap_home_moments_shift_test.db';
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = dbName;
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, dbName));
    // Open in the real zone: an open started under a test's fake clock never
    // completes.
    await LocalDb.instance;
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, dbName));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Home cold open WITHOUT pending moments (setting on)', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()..repo = _SlowHomeRepo(_bundle(70, 8, 42));
    addTearDown(app.dispose);
    await _enable(t, app);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
    run.opened();
    await _framesWithDb(t, run);
    await _drainDb(t);
    await t.pump(const Duration(seconds: 5));
    expect(find.text('Breakdown of your day'), findsOneWidget);
    expect(find.text('Review activities'), findsNothing);
    run.expectNoErrors('home cold open, no moments');
  });

  testWidgets('Home cold open WITH pending moments', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()..repo = _SlowHomeRepo(_bundle(70, 8, 42));
    addTearDown(app.dispose);
    await _enable(t, app);
    await _seed(t);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
    run.opened();
    await _framesWithDb(t, run);
    await _drainDb(t);
    await t.pump(const Duration(seconds: 5));
    expect(find.text('Review activities'), findsOneWidget,
        reason: 'the seeded moments must turn the Home card into the review card');
    run.expectNoErrors('home cold open, with moments');
  });

  testWidgets('Home: a sync lands while the review card is visible', (t) async {
    phoneSurface(t);
    final repo = _SlowHomeRepo(_bundle(70, 8, 42), delayMs: 0);
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await _enable(t, app);
    await _seed(t);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
    await settle(t,
        until: () => find.text('Review activities').evaluate().isNotEmpty,
        what: 'the review card');
    await t.pump(const Duration(seconds: 1));
    run.now = 0;
    run.snap();
    repo.today = _bundle(82, 9, 15);
    repo.delayMs = 150;
    app.bumpInsights();
    await _framesWithDb(t, run);
    await _drainDb(t);
    await t.pump(const Duration(seconds: 5));
    run.expectNoErrors('home sync lands with the review card');
  });
}
