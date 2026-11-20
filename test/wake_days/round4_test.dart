import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import '../support/failing_preferences_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/personal_day.dart';
import 'package:openstrap_edge/ui2/personal_day_inputs.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart' show DayNav;
import 'package:openstrap_edge/ui2/ui2.dart';
import '../backup/backup_support.dart';
import '../support/live_guide_harness.dart' show GuideFakeRepo;

DateTime at(int day, [int hour = 0, int minute = 0]) =>
    DateTime(2026, 11, day, hour, minute);

class CycleRepo extends GuideFakeRepo {
  CycleRepo({this.wakeHour = 8, this.hasSleep = true});
  final int wakeHour;
  final bool hasSleep;
  @override
  Future<List<String>> availableDays() async => ['2026-11-03', '2026-11-02'];
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60, String? before}) async =>
    !hasSleep ? [] : [for (final day in [1, 2, 3]) {
      'date': '2026-11-0${day + 1}',
      'onset_ts': at(day, 23).millisecondsSinceEpoch ~/ 1000,
      'wake_ts': at(day + 1, wakeHour).millisecondsSinceEpoch ~/ 1000,
    }];
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => {
    'duration_min': {'value': date == '2026-11-03' ? 437 : 301,
      'confidence': .9, 'tier': 'HIGH'}};
}

void main() {
  late BackupEnv env;
  setUpAll(() async {
    env = await BackupEnv.create('wake_days_round4.db');
    await LocalDb.instance;
  });
  tearDownAll(() => env.dispose());
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.reload();
  });

  // WHY / CLAIM(home-steps-mode): owner m301 supersedes the 2026-11-18 "Home
  // reads the current wake cycle whatever the timeline setting" (CLAIM(home-now)
  // for the mode part): Home reads and steps the SAME cycles the Day screen
  // shows for the selected mode, so the bar never skips a day the timeline has.
  // The cycle holding now is that mode's: sleep to sleep starts at the last
  // onset, calendar offset at the last noon. Its numbers still come from the one
  // calendar day it is named for, so the in-bed Home keeps Nov 3 past midnight.
  // Calendar offset before noon is the noon-to-noon cycle that began yesterday:
  // Nov 2, as the Day screen shows it (the one place the old claim's "never
  // yesterday in the morning" no longer holds; see pilot5/report.md).
  // Catches: forcing wake cycles on Home again, or a Home that names another
  // day than its own cycle.
  for (final mode in PersonalDayMode.values) {
    for (final now in [at(3, 10), at(4, 0, 30)]) {
      final morning = now == at(3, 10);
      final start = switch (mode) {
        PersonalDayMode.wakeToWake => at(3, 8),
        PersonalDayMode.sleepToSleep => morning ? at(2, 23) : at(3, 23),
        PersonalDayMode.calendarOffset => morning ? at(2, 12) : at(3, 12),
      };
      final day = mode == PersonalDayMode.calendarOffset && morning ? '2026-11-02' : '2026-11-03';
      test('Home reads the ${mode.name} cycle holding now: $day at $now', () async {
        await Prefs.setPersonalDayMode(mode);
        await Prefs.setPersonalDayTotals(PersonalDayTotals.last);
        final home = await withClock(Clock.fixed(now), () => HomeData.load(CycleRepo()));
        expect(home.dayId, day);
        expect(home.personalDay!.start, start);
        expect(home.personalDay!.scoreDay, day);
        expect(home.sleepMin.value, day == '2026-11-03' ? 437 : 301);
      });
    }
  }

  // WHY / CLAIM(home-day-bar): owner m294 supersedes the 2026-11-18 "no day
  // picker" half of CLAIM(home-now): Home shows the app's one day bar in
  // personal-day mode too, plus the start caption (stepping is in
  // home_day_bar_test.dart). Owner m301: sleep to sleep starts the day at the
  // onset, so the caption says 23:00 here. Catches: dropping the bar, or a
  // mode-labelled picker (the title row stays off Home).
  testWidgets('Home has a start caption and the day bar', (tester) async {
    await Prefs.setPersonalDayMode(PersonalDayMode.sleepToSleep);
    final now = at(3, 10);
    final home = (await tester.runAsync(() =>
        withClock(Clock.fixed(now), () => HomeData.load(CycleRepo()))))!;
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    tester.binding.platformDispatcher.alwaysUse24HourFormatTestValue = true;
    addTearDown(tester.binding.platformDispatcher.clearAlwaysUse24HourTestValue);
    tester.view.physicalSize = const Size(430, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(value: app,
      child: MaterialApp(theme: buildTheme(Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: HomeScreen(data: home, now: now, hour: 10)))));
    expect(find.byType(DayNav), findsOneWidget);
    expect(find.text('Your day started 23:00'), findsOneWidget);
    expect(find.text('Your day (sleep to sleep)'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // WHY / CLAIM(personal-global-totals): a late wake's completed cycle runs
  // Nov 3 08:00 -> Nov 4 18:00: 16h first, 18h last. Older cycles
  // mostly cover their first date. Use the latest choice everywhere,
  // including old cycles and after reloading/changing modes.
  test('latest majority seeds one persistent choice before a historical read', () async {
    await Prefs.setPersonalDayMode(PersonalDayMode.wakeToWake);
    final now = at(4, 20);
    final view = await readPersonalDay(_ChangingWakeRepo(), at(2, 8).toIso8601String(), now: now);
    expect(Prefs.personalDayTotals, PersonalDayTotals.last);
    expect(view!.day.scoreDay, '2026-11-03');
    await Prefs.reload();
    expect(Prefs.personalDayTotals, PersonalDayTotals.last);
    await Prefs.setPersonalDayMode(PersonalDayMode.calendarOffset);
    expect(Prefs.personalDayTotals, PersonalDayTotals.last);
  });

  // WHY / CLAIM(personal-global-totals): sleep-to-sleep can also cover mostly
  // its first date. Nov 2 01:00 -> Nov 3 01:00 is 23h first and 1h last.
  test('early onset seeds first even though sleep mode defaults to last', () async {
    await Prefs.setPersonalDayMode(PersonalDayMode.sleepToSleep);
    await readPersonalDay(_EarlySleepRepo(), '2026-11-03', now: at(4, 10));
    expect(Prefs.personalDayTotals, PersonalDayTotals.first);
    await Prefs.setPersonalDayMode(PersonalDayMode.wakeToWake);
    expect(Prefs.personalDayTotals, PersonalDayTotals.first);
  });

  // WHY: no-data installs retain the chosen mode's first/last default.
  test('no sleep data does not lock the new-install default', () async {
    await Prefs.setPersonalDayMode(PersonalDayMode.wakeToWake);
    await readPersonalDay(CycleRepo(hasSleep: false), '2026-11-03', now: at(3, 10));
    expect(Prefs.personalDayTotals, PersonalDayTotals.first);
    await Prefs.setPersonalDayMode(PersonalDayMode.sleepToSleep);
    expect(Prefs.personalDayTotals, PersonalDayTotals.last);
  });

  // WHY: a saved user choice must win over automatic initialization.
  test('explicit first wins over a late-wake majority', () async {
    await Prefs.setPersonalDayMode(PersonalDayMode.wakeToWake);
    await Prefs.setPersonalDayTotals(PersonalDayTotals.first);
    await readPersonalDay(CycleRepo(wakeHour: 18), '2026-11-03', now: at(4, 20));
    expect(Prefs.personalDayTotals, PersonalDayTotals.first);
  });

  // WHY: a failed default write must leave neither cache nor disk locked to
  // that choice; the next read must retry instead of silently claiming success.
  test('automatic totals persistence failure rolls back and retries', () async {
    await Prefs.setPersonalDayMode(PersonalDayMode.wakeToWake);
    final store = SharedPreferencesStorePlatform.instance;
    addTearDown(() => SharedPreferencesStorePlatform.instance = store);
    SharedPreferencesStorePlatform.instance = FailingPreferencesStore(store,
        key: Prefs.personalDayLearnedTotalsKey, throws: false);
    await expectLater(readPersonalDay(_ChangingWakeRepo(), '2026-11-03', now: at(4, 20)),
        throwsStateError);
    expect(Prefs.personalDayTotals, PersonalDayTotals.first);
    await Prefs.reload();
    expect(Prefs.personalDayTotals, PersonalDayTotals.first);
    await readPersonalDay(_ChangingWakeRepo(), '2026-11-03', now: at(4, 20));
    expect(Prefs.personalDayTotals, PersonalDayTotals.last);
  });

  // WHY / CLAIM(home-now): the production Home read must consume qualified
  // wake evidence even with a calendar timeline and an unscored night. Owner
  // m301: the cycle itself is the selected mode's (calendar offset: the noon
  // that began it), not the wake cycle; the wake evidence still ends pre-sleep.
  test('acknowledged wake ends Home pre-sleep without inventing sleep', () async {
    await Prefs.setPersonalDayMode(PersonalDayMode.calendarOffset);
    await LocalDb.putWakeEvidence(onsetSec: at(2, 23).millisecondsSinceEpoch ~/ 1000,
        kind: 'alarmAcknowledged', atSec: at(3, 7).millisecondsSinceEpoch ~/ 1000);
    final home = await withClock(Clock.fixed(at(3, 7, 30)),
        () => HomeData.load(_NoScoreRepo()));
    expect(home.wakeObserved, isTrue);
    expect(home.personalDay!.start, at(2, 12));
    expect(home.sleepMin.value, isNull);
  });
}

class _NoScoreRepo extends CycleRepo {
  @override
  Future<Map<String, dynamic>> getToday() async => {'status': {'today_day': '2026-11-03'}};
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => {};
}

class _EarlySleepRepo extends CycleRepo {
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60, String? before}) async =>
    [for (final day in [1, 2, 3, 4]) {
      'date': '2026-11-0$day',
      'onset_ts': at(day, 1).millisecondsSinceEpoch ~/ 1000,
      'wake_ts': at(day, 8).millisecondsSinceEpoch ~/ 1000,
    }];
}

class _ChangingWakeRepo extends CycleRepo {
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60, String? before}) async =>
    [for (final day in [1, 2, 3]) {
      'date': '2026-11-0${day + 1}',
      'onset_ts': at(day, 23).millisecondsSinceEpoch ~/ 1000,
      'wake_ts': at(day + 1, day == 3 ? 18 : 8).millisecondsSinceEpoch ~/ 1000,
    }];
}
