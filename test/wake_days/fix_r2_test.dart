import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/personal_day.dart';
import 'package:openstrap_edge/ui2/personal_day_inputs.dart';
import 'package:openstrap_edge/ui2/personal_day_widgets.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import '../backup/backup_support.dart';
import '../support/live_guide_harness.dart' show GuideFakeRepo;

DateTime t(int d, [int h = 0, int m = 0]) => DateTime(2026, 11, d, h, m);

PersonalDay current(List<PersonalDay> days, DateTime now) =>
    days.singleWhere((d) => d.contains(now));

class _Repo extends GuideFakeRepo {
  @override
  Future<List<String>> availableDays() async => ['2026-11-03', '2026-11-02'];
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60, String? before}) async => [
    {'date': '2026-11-02', 'onset_ts': t(1, 23).millisecondsSinceEpoch ~/ 1000,
      'wake_ts': t(2, 8).millisecondsSinceEpoch ~/ 1000},
    {'date': '2026-11-03', 'onset_ts': t(2, 23).millisecondsSinceEpoch ~/ 1000,
      'wake_ts': t(3, 8).millisecondsSinceEpoch ~/ 1000},
  ];
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => date == '2026-11-03'
      ? {'duration_min': {'value': 437, 'confidence': .9, 'tier': 'HIGH'}}
      : {'duration_min': {'value': 301, 'confidence': .9, 'tier': 'HIGH'}};
  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async => {
    'date': date, 'day_start': DateTime.parse(date).millisecondsSinceEpoch ~/ 1000,
  };
}

void main() {
  late BackupEnv env;
  setUpAll(() async { env = await BackupEnv.create('wake_days_r2.db'); await LocalDb.instance; });
  tearDownAll(() => env.dispose());
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.reload();
  });

  // WHY / CLAIM(personal-open-cycle): review r2 S1. The cycle the user is in
  // right now must score today's majority day at every default, otherwise Home
  // shows nothing or tomorrow all day. Literal dates, no computed oracle.
  // catches: first/last on the open cycle (null, or the next day).
  // calendarOffset at 10:00 is still inside the noon-to-noon cycle that began
  // Nov 2 12:00 (12 h each side, tie goes to the earlier date), so it is Nov 2.
  for (final mode in PersonalDayMode.values) {
    for (final now in [t(3, 10), t(3, 14), t(4, 0, 30)]) {
      final day = mode == PersonalDayMode.calendarOffset && now == t(3, 10)
          ? '2026-11-02' : '2026-11-03';
      test('${mode.name} at default totals scores the current cycle on $day ($now)', () {
        final days = personalDays(from: mode == PersonalDayMode.calendarOffset
                ? t(1, 12) : mode == PersonalDayMode.sleepToSleep ? t(1, 23) : t(2, 8),
            until: now.add(const Duration(minutes: 1)),
            sleeps: [MainSleep(t(1, 23), t(2, 8)), MainSleep(t(2, 23), t(3, 8))]
                .where((s) => !s.onset.isAfter(now)).toList(), mode: mode);
        expect(days.map((d) => d.scoreDay),
            mode == PersonalDayMode.calendarOffset
                ? (now == t(3, 10) ? ['2026-11-01', '2026-11-02']
                    : ['2026-11-01', '2026-11-02', '2026-11-03'])
                : ['2026-11-02', '2026-11-03']);
        expect(current(days, now).scoreDay, day);
      });
    }
  }
  // WHY / CLAIM(personal-open-cycle): r3 S2 reserves the current date before
  // closed cycles claim dates. An explicit last must not blank Home.
  // catches: closed cycles stealing the open cycle's date, or a pref ignored.
  test('closed cycles keep first/last and an explicit choice overrides', () {
    final w = personalDays(from: t(2, 8), until: t(3, 10, 1), mode: PersonalDayMode.wakeToWake,
        sleeps: [MainSleep(t(1, 23), t(2, 8)), MainSleep(t(2, 23), t(3, 8))]);
    expect(w.map((d) => d.scoreDay), ['2026-11-02', '2026-11-03']);
    final s = personalDays(from: t(1, 23), until: t(3, 10, 1), mode: PersonalDayMode.sleepToSleep,
        sleeps: [MainSleep(t(1, 23), t(2, 8)), MainSleep(t(2, 23), t(3, 8))]);
    expect(s.map((d) => d.scoreDay), ['2026-11-02', '2026-11-03']);
    final explicit = personalDays(from: t(2, 8), until: t(3, 10, 1),
        mode: PersonalDayMode.wakeToWake, totals: PersonalDayTotals.last,
        sleeps: [MainSleep(t(1, 23), t(2, 8)), MainSleep(t(2, 23), t(3, 8))]);
    expect(explicit.map((d) => d.scoreDay), [null, '2026-11-03']);
  });
  // WHY: the totals pref is "unset" until chosen; the effective value follows
  // the mode. catches: a hard-coded `last` for every mode.
  test('unset totals follow the mode and an explicit pref wins', () async {
    await Prefs.setPersonalDayMode(PersonalDayMode.wakeToWake);
    expect(Prefs.personalDayTotals, PersonalDayTotals.first);
    await Prefs.setPersonalDayMode(PersonalDayMode.calendarOffset);
    expect(Prefs.personalDayTotals, PersonalDayTotals.first);
    await Prefs.setPersonalDayMode(PersonalDayMode.sleepToSleep);
    expect(Prefs.personalDayTotals, PersonalDayTotals.last);
    await Prefs.setPersonalDayTotals(PersonalDayTotals.first);
    expect(Prefs.personalDayTotals, PersonalDayTotals.first);
  });
  testWidgets('settings marks the derived totals value as the default', (tester) async {
    await Prefs.setPersonalDayMode(PersonalDayMode.wakeToWake);
    Future<void> mount() => tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: PersonalDaySettings())));
    await mount();
    expect(find.text('First calendar day (default)'), findsOneWidget);
    await Prefs.setPersonalDayTotals(PersonalDayTotals.first);
    await tester.pumpWidget(const SizedBox.shrink());
    await mount();
    expect(find.text('First calendar day'), findsOneWidget);
  });
  // WHY: the pure helper is not the production path. Home must show Nov 3's
  // sleep in wake-to-wake with nothing in the totals pref (the owner's first
  // session). catches: "—" / "No calendar totals" all day.
  for (final now in [t(3, 10), t(4, 0, 30)]) {
    test('Home through the production loader shows Nov 3 at $now', () async {
      await Prefs.setPersonalDayMode(PersonalDayMode.wakeToWake);
      await withClock(Clock.fixed(now), () async {
        final home = await HomeData.load(_Repo());
        expect(home.personalDay!.scoreDay, '2026-11-03');
        expect(home.sleepMin.value, 437);
        expect(home.dayId, '2026-11-03');
      });
    });
  }
  // WHY / CLAIM(personal-open-cycle): r3 S2 must work through the saved pref,
  // production loader and ring. 437 minutes is literally 7h 17m.
  // catches: reserving the date only in a helper unused by Home.
  for (final totals in [null, PersonalDayTotals.last]) {
    testWidgets('wake-to-wake sleep ring prints 7h 17m with totals $totals', (tester) async {
      SharedPreferences.setMockInitialValues({
        Prefs.personalDayModeKey: 'wakeToWake',
        if (totals != null) Prefs.personalDayTotalsKey: totals.name,
      });
      await Prefs.reload();
      final now = t(3, 10);
      final home = await tester.runAsync(() =>
          withClock(Clock.fixed(now), () => HomeData.load(_Repo())));
      expect(home!.personalDay!.scoreDay, '2026-11-03');
      await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: RingTrio(now: now, d: home))));
      expect(find.textContaining('7h 17m'), findsWidgets);
      expect(find.textContaining('No calendar totals'), findsNothing);
    });
  }
  // WHY / CLAIM(personal-open-cycle): the closed loser must abstain instead of
  // showing the current cycle's totals. catches: retaining duplicate claims.
  testWidgets('closed cycle losing its date shows a dash through the loader', (tester) async {
    await Prefs.setPersonalDayMode(PersonalDayMode.wakeToWake);
    await Prefs.setPersonalDayTotals(PersonalDayTotals.last);
    final now = t(3, 10);
    final home = await tester.runAsync(() => withClock(Clock.fixed(now),
        () => HomeData.loadForDay(_Repo(), '2026-11-02')));
    expect(home!.personalDay!.scoreDay, isNull);
    expect(home.sleepMin.value, isNull);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: RingTrio(now: now, d: home))));
    expect(find.text('—'), findsWidgets);
    expect(find.textContaining('7h 17m'), findsNothing);
  });

  // WHY: review r2 S2. With the band off, a wake is observed but nothing was
  // derived; the ring must not claim work in progress. catches: "being processed".
  testWidgets('unscored night says so and does not claim processing', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: RingTrio(now: t(3, 10),
        d: HomeData(dayId: '2026-11-03', wakeObserved: true,
          personalMode: PersonalDayMode.wakeToWake)))));
    expect(find.textContaining('being processed'), findsNothing);
    expect(find.textContaining("Last night isn't scored yet"), findsWidgets);
  });

  // WHY: review r2 S4. A date shadowed by a longer cycle still has data; the
  // deep link selects the cycle holding that date's local noon.
  // catches: an empty "band was probably off" timeline.
  test('a calendar label that is no cycle majority opens the cycle holding its noon', () async {
    await Prefs.setPersonalDayMode(PersonalDayMode.wakeToWake);
    // 34 h stay-up: one cycle Nov 2 08:00 -> Nov 3 18:00 is labelled Nov 3,
    // so Nov 2 matches no cycle label.
    final repo = _StayUpRepo();
    final view = await readPersonalDay(repo, '2026-11-02', now: t(5, 12));
    expect(view, isNotNull);
    expect(view!.day.start, t(2, 8));
    expect(view.day.label, '2026-11-03');
  });
}

class _StayUpRepo extends _Repo {
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60, String? before}) async => [
    {'date': '2026-11-02', 'onset_ts': t(1, 23).millisecondsSinceEpoch ~/ 1000,
      'wake_ts': t(2, 8).millisecondsSinceEpoch ~/ 1000},
    {'date': '2026-11-03', 'onset_ts': t(3, 10).millisecondsSinceEpoch ~/ 1000,
      'wake_ts': t(3, 18).millisecondsSinceEpoch ~/ 1000},
  ];
}
