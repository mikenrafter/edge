import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import '../support/chart_harness.dart' show ChartRepo, initPrefs, loadType;

const past = '2026-05-19';
const days = ['2026-05-22', '2026-05-20', past];

Future<void> host(WidgetTester t, Widget page, {AppState? app}) async {
  t.view.physicalSize = const Size(412, 1800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(ChangeNotifierProvider<ThemeController>(
    create: (_) => ThemeController.seed(AppThemeChoice.light, Brightness.light),
    child: MaterialApp(theme: buildTheme(Brightness.light),
      home: app == null ? Scaffold(body: page) : ChangeNotifierProvider<AppState>.value(
        value: app, child: page))));
  await t.pump();
}

void main() {
  setUpAll(() async {
    await initPrefs();
    await loadType();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  // WHY: Overview has no selected day; midnight must never create a pill.
  // catches: passing a captured today label instead of null off Vitals.
  testWidgets('Health Overview after midnight shows no pill', (t) async {
    var now = DateTime(2026, 5, 22, 23, 59, 59);
    await withClock(Clock(() => now), () async {
      await host(t, const HealthScreen(data: HealthData(),
        vitals: VitalsData(day: past, days: days)));
      expect(find.text('Back to today'), findsNothing, reason: 'before midnight');
      now = DateTime(2026, 5, 23, 0, 0, 1);
      await t.pump(const Duration(seconds: 2));
      await t.pump();
      expect(find.text('Back to today'), findsNothing,
        reason: 'Overview (not a date page) grew a Back to today pill at midnight');
      await t.pumpWidget(const SizedBox());
    });
  });

  // WHY: the daily scale shows a range, so midnight cannot create a day action.
  // catches: replacing the absent explorer day with a captured today label.


  // WHY: a remembered day scale must publish its date on first mount, so a
  // kept-alive view offers today after midnight. CLAIM(day-navigation-immediate).
  // catches: deleting the post-frame publication or reading the host clock.


}
