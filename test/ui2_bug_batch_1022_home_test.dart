// RED (owner UI feedback 2026-10-22, B1): the "Updated … · recordings through
// … · Waiting for sync to finish" line renders TWICE under the Home overview
// card. `_homeAsOf` places two AsOfHolds (overnight row, activity row); when
// both rows were computed together the second returns null from `asOf` for the
// live-recalc case, but the staleness-hold path (`newer ? pausedAt`) ignores
// that and shows its own copy of the same sentence.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import 'support/as_of_recalc_fakes.dart';

final _label = find.byKey(const ValueKey('as-of-label'));

class _HomeRepo extends HomeRepo {
  _HomeRepo(super.today, this.through);
  final DateTime through;
  @override
  Future<DateTime?> dayRecordingsThrough(String day) async => through;
}

DateTime _at(int h, int m) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day, h, m);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const dbName = 'openstrap_bug_batch_1022_home.db';
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = dbName;
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), dbName));
  });
  tearDownAll(() async {
    await LastResultCache.instance.flush();
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), dbName));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LastResultCache.instance.clear();
  });

  testWidgets('B1: the staleness line is on Home once, not once per row',
      (t) async {
    t.view.physicalSize = const Size(390 * 3, 2600 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    // Overnight and activity rows computed together (16:08), covering
    // recordings through 16:04; a newer recording (16:19) exists and an
    // offload holds the derive: "Waiting for sync to finish".
    final ms = todayAtMs(16, 8);
    final app = AppState.forTesting()
      ..repo = _HomeRepo(homeBundle(overnightAt: ms, activityAt: ms), _at(16, 4));
    addTearDown(app.dispose);
    (app as dynamic).debugLastRecTs =
        _at(16, 19).millisecondsSinceEpoch ~/ 1000;
    (app as dynamic).debugDeriveScheduler.setOffloadActive(true);

    await t.pumpWidget(perfApp(app, const HomeScreen(hour: 16)));
    await settle(t, n: 15);

    expect(find.textContaining('Waiting for sync to finish'), findsOneWidget,
        reason: 'the same sentence must not be drawn by both AsOfHolds');
    expect(_label, findsOneWidget);

    (app as dynamic).debugDeriveScheduler.setOffloadActive(false);
    await t.pump();
  });
}
