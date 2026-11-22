// The visible Labs switch drives the ONE persisted HMM choice (fix round 1, F2):
// it reads AppState.sleepHmmStagesEnabled and writes `sleep_hmm_stages`; the
// older fork key is neither read nor written.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _rowKey = ValueKey('experimental-sleep-hmm');

Future<void> _wait(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)));
    await t.pump();
  }
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_hmm_single_choice_settings_test.db';
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  setUp(() async => (await SharedPreferences.getInstance()).clear());

  Future<AppState> pump(WidgetTester t, {bool enabled = false}) async {
    t.view.physicalSize = const Size(360 * 3, 900 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final app = AppState.forTesting()..sleepHmmStagesEnabled = enabled;
    addTearDown(app.dispose);
    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(
            create: (_) => UnitsController.seed(UnitSystem.metric)),
        ChangeNotifierProvider(
            create: (_) =>
                ThemeController.seed(AppThemeChoice.light, Brightness.light)),
        ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
        ChangeNotifierProvider(
            create: (_) => ClockFormatController.seed(ClockFormat.h24)),
        Provider<Capabilities>.value(value: app.capabilities),
      ],
      child: MaterialApp(
          theme: buildTheme(Brightness.light), home: const MoreSettings()),
    ));
    await _wait(t);
    await t.scrollUntilVisible(find.byKey(_rowKey), 300,
        scrollable: find.byType(Scrollable).first);
    await t.pump();
    return app;
  }

  testWidgets('the row shows the persisted upstream choice', (t) async {
    await pump(t, enabled: true);
    expect(find.descendant(of: find.byKey(_rowKey), matching: find.text('On')),
        findsOneWidget);
  });

  testWidgets('tapping the row writes sleep_hmm_stages and not the older key',
      (t) async {
    final app = await pump(t);
    await t.tap(find.byKey(_rowKey));
    await _wait(t);
    expect(app.sleepHmmStagesEnabled, isTrue);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool('sleep_hmm_stages'), isTrue);
    expect(sp.containsKey('compute.experimental_sleep_hmm'), isFalse);
    expect(find.descendant(of: find.byKey(_rowKey), matching: find.text('On')),
        findsOneWidget);
  });
}
