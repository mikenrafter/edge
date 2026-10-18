// Layout shift of the refresh landing: a screen paints the stored row (another
// day's, so today's figures read "—"), then the freshness refresh lands and
// the figures arrive. No user action: nothing is in-window, so any movement
// counts. Measurement tests (fake pumps only).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import '../../support/as_of_recalc_fakes.dart';
import '../../support/shift_refresh_fakes.dart';
import '../../support/shift_run.dart';

// The landing must not move anything: no shift finding at all (the default
// policy only fails on errors; warnings are what the landing used to cost).
void _expectHeldStill(ShiftRun run, String name) {
  final moved = run.score().findings.where((f) => f.rule == 'shift').toList();
  expect(moved.where((f) => f.severity.name != 'none'), isEmpty,
      reason: '$name: the refresh landing moved '
          '${moved.map((f) => '${f.elementId}@${f.atMs}=${f.score.toStringAsFixed(3)}').join(', ')}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  RefreshRepo repo() => RefreshRepo(storedElsewhere(),
      homeBundle(readiness: 70, overnightAt: todayAtMs(8, 42), activityAt: todayAtMs(8, 42)));

  // Opens [screen], waits for the stored paint, then measures from there:
  // the refresh (300 ms) lands and the screen reads again inside [frames].
  Future<void> landing(WidgetTester t, Widget screen, String name,
      {int expectReads = 1, bool still = false}) async {
    phoneSurface(t);
    final r = repo();
    final app = AppState.forTesting()..repo = r;
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, screen));
    run.opened();
    await run.frames(); // open: loading -> stored paint, refresh asked
    await t.pump(const Duration(seconds: 3)); // landed + reread
    expect(r.refreshCalls, greaterThanOrEqualTo(expectReads),
        reason: 'the stored row must have asked for the refresh');
    run.expectNoErrors(name);
    if (still) _expectHeldStill(run, name);
  }

  // Same, but the measured window starts AFTER the stored paint settles, so
  // only the landing itself is scored.
  Future<void> landingOnly(WidgetTester t, Widget screen, String name) async {
    phoneSurface(t);
    final r = repo();
    final app = AppState.forTesting()..repo = r;
    addTearDown(app.dispose);
    r.delayMs = 0;
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, screen));
    // Hold the refresh back: stored paint settles, then it lands.
    await t.pump(const Duration(milliseconds: 50));
    run.now = 0;
    run.snap();
    await run.frames();
    await t.pump(const Duration(seconds: 3));
    expect(r.refreshed, isTrue, reason: 'the refresh must have landed');
    run.expectNoErrors(name);
  }

  testWidgets('Home: stored row then refresh landing (open)', (t) async {
    await landing(t, const HomeScreen(hour: 9), 'home refresh landing (open)');
  });

  testWidgets('Home: refresh landing alone (absent -> values)', (t) async {
    await landingOnly(
        t, const HomeScreen(hour: 9), 'home refresh landing (swap only)');
  });

  testWidgets('Health: open + refresh landing', (t) async {
    await landing(t, const HealthScreen(), 'health refresh landing',
        still: true);
  });

  testWidgets('Readiness detail: open + refresh landing', (t) async {
    await landing(t, const ReadinessDetail(), 'readiness refresh landing',
        still: true);
  });
}
