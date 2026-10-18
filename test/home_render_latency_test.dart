// Home records the time from an insightsRevision bump to the
// first Home commit (setState) that consumed it.
//
// ASSUMED API: `int? AppState.lastHomeRenderMs` (null until measured) and
// `void AppState.recordHomeRender(int ms)`, which stores it and writes ONE
// line `[perf] home render <ms> ms` to `AppState.logLines` (via `_log`). Home
// uses a `RenderLatency` (see derive_perf_test.dart): `revisionBumped()` from
// its revision listener, `committed()` after the setState that consumed it.
// The first (initial) load is not a revision and records nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import 'support/as_of_recalc_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a revision bump -> Home commit is measured and logged',
      (t) async {
    t.view.physicalSize = const Size(390 * 3, 2600 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final repo = HomeRepo(homeBundle(
        overnightAt: todayAtMs(7, 10), activityAt: todayAtMs(8, 42)));
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);

    expect(app.lastHomeRenderMs, isNull, reason: 'not measured yet');
    await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
    await settle(t);
    expect(app.lastHomeRenderMs, isNull,
        reason: 'the first load is not a revision');

    repo.today = homeBundle(
        readiness: 75,
        overnightAt: todayAtMs(9, 15),
        activityAt: todayAtMs(9, 15));
    app.bumpInsights();
    await settle(t);

    expect(find.text('75'), findsOneWidget);
    expect(app.lastHomeRenderMs, isNotNull);
    expect(app.lastHomeRenderMs!, greaterThanOrEqualTo(0));
    expect(app.logLines.where((l) => l.startsWith('[perf] home render')),
        hasLength(1));
  });
}
