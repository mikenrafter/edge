// Layout shift budget on Home: cold open (loading -> data) and a background
// refresh while on screen. Measurement test: it fails where Home really moves.
//
// Time: fake-async pumps only. The repo answers after a fixed fake-clock delay
// (a stand-in for the database read); nothing reads a real clock.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Map<String, dynamic> bundle(num readiness, int h, int m) => homeBundle(
      readiness: readiness, overnightAt: todayAtMs(h, m), activityAt: todayAtMs(h, m));

  testWidgets('Home cold open: loading -> data', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()..repo = _SlowHomeRepo(bundle(70, 8, 42));
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
    run.snap();
    await run.frames();
    // Drain anything left so no timer outlives the test.
    await t.pump(const Duration(seconds: 5));
    run.expectNoErrors('home cold open');
  });

  testWidgets('Home background refresh (no user action)', (t) async {
    phoneSurface(t);
    final repo = _SlowHomeRepo(bundle(70, 8, 42), delayMs: 0);
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
    await t.pump(const Duration(seconds: 1));
    run.now = 0;
    run.snap();
    // A sync lands: new numbers, fresher computed_at. No Interaction.
    repo.today = bundle(82, 9, 15);
    repo.delayMs = 150;
    app.bumpInsights();
    await run.frames();
    await t.pump(const Duration(seconds: 5));
    run.expectNoErrors('home background refresh');
  });
}
