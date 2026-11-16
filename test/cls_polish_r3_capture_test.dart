// why: inspect translated age qualifiers on real cached-loading Home screens.
// CLAIM(home-cache-freshness); optional PNG artifacts use CLS_SHOTS_DIR.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/home_snapshot_store.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'support/as_of_recalc_fakes.dart';
import 'support/skeleton_fixture.dart';
import 'support/shift_run.dart';
import 'support/pilot_shots.dart';

class _Held extends HomeRepo {
  _Held() : super(homeBundle(readiness: 22));
  final wait = Completer<void>();
  @override
  Future<Map<String, dynamic>> getTodayStored() async {
    await wait.future;
    return today;
  }
}

void main() {
  setUpAll(skLoadAppFonts);
  for (final language in ['en', 'de']) {
    testWidgets('cached loading Home in $language, dark', (t) async {
      phoneSurface(t);
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      await HomeSnapshotStore.invalidate();
      ClockFormatController.seed(ClockFormat.h12);
      addTearDown(ClockFormatController.debugReset);
      final repo = _Held();
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      final locale = LocaleController.seed(language);
      addTearDown(locale.dispose);
      HomeRingDetailCache.local.record(
        todayLabel(),
        language,
        HomeData(
          dayId: todayLabel(),
          readiness: const Metric(value: 22, confidence: 1),
          sleepMin: const Metric(value: 300, confidence: 1),
          sleepNeedMin: const Metric(value: 480, confidence: 1),
          strain: const Metric(value: 14, confidence: 1),
          strainTarget: const {'low': 8, 'high': 10},
          overnightAt: DateTime(2026, 11, 12, 6, 30),
        ),
        null,
        readAt: DateTime(2026, 11, 12, 8, 14),
      );
      await t.pumpWidget(
        pilotShot(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<AppState>.value(value: app),
              ChangeNotifierProvider<LocaleController>.value(value: locale),
            ],
            child: MaterialApp(
              locale: Locale(language),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: buildTheme(Brightness.dark),
              home: const Scaffold(body: HomeScreen()),
            ),
          ),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(
        find.textContaining(language == 'en' ? 'Last known' : 'Letzter Stand'),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
      await takePilotShot(t, 'home-cached-loading-$language-dark');
      repo.wait.complete();
      await t.pumpWidget(const SizedBox());
    });
  }
}
