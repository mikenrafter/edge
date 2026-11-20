import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/day_navigation.dart';
import 'package:openstrap_edge/ui2/personal_day.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import '../backup/backup_support.dart';
import 'package:openstrap_edge/data/db.dart';
import '../support/live_guide_harness.dart' show GuideFakeRepo;

// Day 3 is TODAY on the real calendar: Home compares its selected day with the
// real clock, so a frozen fake date would show "Back to today" at the start.
DateTime at(int day, [int hour = 0, int minute = 0]) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - 3 + day, hour, minute);
}

// Three nights (asleep 23:00, awake 08:00): wake-to-wake cycles start 2 days
// ago, yesterday and today at 08:00.
class _Repo extends GuideFakeRepo {
  @override
  Future<Map<String, dynamic>> getTodayStored() => getToday();
  @override
  Future<List<String>> availableDays() async => ['2026-11-03', '2026-11-02'];
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60, String? before}) async => [
    for (final day in [1, 2, 3]) {'date': '2026-11-0${day + 1}',
      'onset_ts': at(day, 23).millisecondsSinceEpoch ~/ 1000,
      'wake_ts': at(day + 1, 8).millisecondsSinceEpoch ~/ 1000},
  ];
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => {
    'duration_min': {'value': date == '2026-11-03' ? 437 : 301,
      'confidence': .9, 'tier': 'HIGH'}};
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await t.pump(const Duration(milliseconds: 20));
  }
}

String _label(WidgetTester t) => t.widget<DayStepBar>(find.byType(DayStepBar)).label;

void main() {
  late BackupEnv env;
  setUpAll(() async {
    env = await BackupEnv.create('wake_days_home_day_bar.db');
    await LocalDb.instance;
  });
  tearDownAll(() => env.dispose());
  // WHY / CLAIM(home-day-bar): owner m294 supersedes CLAIM(home-now)'s "no day
  // picker": Home shows the app's one day bar with a personal day on too, and
  // stepping it moves Home to the neighbouring personal day. Owner m301: the
  // cycles are the selected mode's, as on the Day screen (home_s2s_nav_test).
  // CATCHES: `if (!Prefs.personalDayEnabled)` around the bar, or a Home that
  // only ever reads the current cycle.
  for (final mode in PersonalDayMode.values) {
    for (final totals in [PersonalDayTotals.first, PersonalDayTotals.last]) {
      testWidgets('Home bar steps personal days: ${mode.name} totals=${totals.name}', (t) async {
        SharedPreferences.setMockInitialValues({});
        await Prefs.reload();
        await t.runAsync(() async {
          await Prefs.setPersonalDayMode(mode);
          await Prefs.setPersonalDayTotals(totals);
        });
        final app = AppState.forTesting();
        addTearDown(app.dispose);
        app.repo = _Repo();
        t.binding.platformDispatcher.alwaysUse24HourFormatTestValue = true;
        addTearDown(t.binding.platformDispatcher.clearAlwaysUse24HourTestValue);
        t.view.physicalSize = const Size(430, 1100);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await withClock(Clock.fixed(at(3, 10)), () async {
          await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ChangeNotifierProvider<AppState>.value(value: app,
              child: Scaffold(body: HomeScreen(now: at(3, 10), hour: 10))))); 
          await _settle(t);
          expect(find.byType(DayNav), findsOneWidget);
          final current = _label(t);
          expect(current, isNot(matches(RegExp(r'^\d{4}-\d{2}-\d{2}T'))));
          // WHY: owner m354 removes the personal-day start caption in every mode.
          expect(find.textContaining('Your day started'), findsNothing);
          expect(find.byKey(const ValueKey('home-back-to-today')), findsNothing);
          final bar = t.widget<DayStepBar>(find.byType(DayStepBar));
          expect(bar.onPrevious, isNotNull, reason: 'an earlier personal day exists');
          expect(bar.onNext, isNull, reason: 'the current day is the newest');

          await t.tap(find.byKey(const ValueKey('day-nav-previous')));
          await _settle(t);
          final earlier = _label(t);
          expect(earlier, isNot(current));
          expect(t.widget<DayStepBar>(find.byType(DayStepBar)).onNext, isNotNull);
          expect(find.byKey(const ValueKey('home-back-to-today')), findsOneWidget);

          await t.tap(find.byKey(const ValueKey('day-nav-next')));
          await _settle(t);
          expect(_label(t), current);
          expect(find.byKey(const ValueKey('home-back-to-today')), findsNothing);

          await t.tap(find.byKey(const ValueKey('day-nav-previous')));
          await _settle(t);
          expect(_label(t), earlier);
          await t.tap(find.byKey(const ValueKey('home-back-to-today')));
          await _settle(t);
          expect(_label(t), current);
          expect(find.textContaining('Your day started'), findsNothing);
          await t.pumpWidget(const SizedBox.shrink());
        });
      });
    }
  }
}
