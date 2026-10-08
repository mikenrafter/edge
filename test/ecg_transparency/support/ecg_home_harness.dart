// Pumps the real Heart Screener home over a bare AppState and a real LocalDb
// (sqflite_common_ffi), the way test/capabilities_screens_test.dart does.
// Test-only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/feature_flags.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> resetPrefs() async {
  FeatureFlags.resetForTest();
  SharedPreferences.setMockInitialValues({});
  await Prefs.ensureLoaded();
}

Capabilities mgCaps() => Capabilities(CapabilityInputs(
  platform: TargetPlatform.android,
  generation: null,
  ecgPaired: true,
  ecgLive: true,
  connected: true,
  devMode: false,
  flagsOff: const {},
  updateChecksBuild: false,
  healthShareBuild: false,
  healthShareConsent: false,
));

/// [screen] over a bare AppState; waits (in real time, for sqflite) until
/// [ready] shows or ~2 s pass.
Future<AppState> pumpWithApp(
  WidgetTester t,
  Widget screen, {
  Finder? ready,
}) async {
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  t.view.physicalSize = const Size(1170, 12000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MultiProvider(
    key: UniqueKey(),
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider(create: (_) => UnitsController.seed(UnitSystem.metric)),
      ChangeNotifierProvider(
        create: (_) => ThemeController.seed(AppThemeChoice.light, Brightness.light),
      ),
      ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
      Provider<Capabilities>.value(value: mgCaps()),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: screen,
    ),
  ));
  for (var i = 0; i < 100; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
    if (i >= 4 && (ready == null || ready.evaluate().isNotEmpty)) break;
  }
  return app;
}
