import 'dart:async';
// Home used to be fixed to today, with no way to look at yesterday's rings
// without leaving the tab for a detail screen. This pins the switcher: it
// reuses [DayNav] (the same day-stepper the Sleep/Strain/HRV detail screens
// already wear) rather than a new control, and it steps through a PAST day
// on the app's own live-repo path — not an injected `HomeData` — so a real
// regression in the wiring between `HomeScreen` and `HomeData.loadForDay`
// would actually fail this.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'support/as_of_recalc_fakes.dart' show perfApp;
import 'support/shift_run.dart' show phoneSurface;

// The real device day, not a fixed string: `HomeScreen._load` decides
// "today" by comparing the switcher's day against `todayLabel()`, exactly
// as `HomeData.load`'s own callers do, so the fixture has to agree with the
// same clock or "step forward back to today" would (wrongly, for the
// fixture's sake only) take the `loadForDay` path instead.
final _today = todayLabel();
final _yesterday = dayLabelOf(DateTime.now().subtract(const Duration(days: 1)));

/// Two distinct days, each with its own readiness/strain/steps — so a test
/// asserting the switcher actually swapped the screen's numbers, not just
/// re-rendered the same ones.
class _Repo extends LocalRepository {
  Completer<void>? previousDay;

  @override
  Future<Map<String, dynamic>> getToday() async => {
        'daily': {
          'readiness': {'value': 70, 'confidence': .8, 'tier': 'HIGH'},
          'resting_hr': {'value': 50, 'confidence': .8, 'tier': 'HIGH'},
          'strain': {'value': 5.0, 'confidence': .8, 'tier': 'ESTIMATE'},
          'steps': {'value': 1000, 'confidence': .8, 'tier': 'ESTIMATE'},
        },
        'sleep': {
          'duration_min': {'value': 400, 'confidence': .8, 'tier': 'HIGH'},
        },
        'status': {'today_day': _today},
      };
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {'name': 'Alex'};
  @override
  Future<List<String>> availableDays() async => [_today, _yesterday];
  // Nothing waits for review, so Home's card reads "Breakdown of your day".
  @override
  Future<int> pendingActivityCount() async => 0;

  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async {
    await previousDay?.future;
    return {'readiness': 42, 'resting_hr': 60};
  }

  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async =>
      {'strain': 9.9, 'steps': 2500, 'calories': 300, 'calories_total': 2000};

  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async {
    if (date != _today) await previousDay?.future;
    return {'has_sleep': true, 'duration_min': date == _today ? 400 : 250};
  }

  // Sleep detail reads its night as one bundle: the night, and nothing else.
  @override
  Future<SleepDetailBundle> getSleepDetailBundle(
    String day, {
    required List<String> chartKeys,
    required int windowDays,
    String? before,
  }) async => SleepDetailBundle(
    night: await getDaySleepV2(day),
    timeline: const {},
    insights: const {},
    charts: const {},
    windows: const [],
  );
}

Future<void> _settle(WidgetTester t, {int n = 40}) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// Walk the app through [states] one transition at a time, the way the
/// engine reports them.
void _lifecycle(WidgetTester t, List<AppLifecycleState> states) {
  for (final st in states) {
    t.binding.handleAppLifecycleStateChanged(st);
  }
}

/// The wall clock Home reads, frozen until a test moves it.
class _Clock {
  DateTime now = DateTime(2026, 10, 31, 12);
  _Clock() {
    debugHomeWallClock = () => now;
    addTearDown(() => debugHomeWallClock = DateTime.now);
  }
}

/// Send the app to the background, let [away] pass on [clock], and bring it
/// back, through the transitions the engine reports.
void _background(WidgetTester t, _Clock clock, Duration away) {
  _lifecycle(t, const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]);
  clock.now = clock.now.add(away);
  _lifecycle(t, const [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]);
}

void main() {
  // WHY: the Sleep day bar must not relabel the old night's duration while
  // the next night's bundle is held. Shared debounce/fade is checked separately.
  testWidgets('Sleep day changes clear the previous duration while reading', (t) async {
    phoneSurface(t);
    final repo = _Repo()..previousDay = Completer<void>();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await t.pumpWidget(perfApp(app, const SleepDetail()));
    await _settle(t);
    expect(find.text('6h 40m'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await t.pump();
    expect(find.text('6h 40m'), findsNothing);
    expect(find.byType(PendingContent), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    repo.previousDay!.complete();
    await _settle(t);
    expect(find.text('4h 10m'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  // WHY: switching day must never leave today's values under yesterday's date;
  // the past-day action floats without adding a row inside the scroll content.
  testWidgets('past-day reads hide old values and use the floating today pill', (t) async {
    final repo = _Repo()..previousDay = Completer<void>();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark),
      home: ChangeNotifierProvider<AppState>.value(value: app,
        child: const Scaffold(body: HomeScreen(hour: 9)))));
    await _settle(t);
    expect(find.text('70'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await t.pump();
    expect(find.text('70'), findsNothing);
    expect(find.byWidgetPredicate((w) => w is PendingContent && w.pending), findsWidgets);
    final pill = find.byKey(const ValueKey('home-back-to-today'));
    expect(find.ancestor(of: pill, matching: find.byType(Positioned)), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Back to today'), findsNothing);
    final list = t.widget<ListView>(find.byType(ListView).first);
    expect((list.padding! as EdgeInsets).bottom, greaterThanOrEqualTo(44 + 12));
    repo.previousDay!.complete();
    await _settle(t);
    expect(find.text('42'), findsOneWidget);
    await t.tap(pill);
    await _settle(t);
    expect(find.text('70'), findsOneWidget);
    expect(pill, findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('stepping to the previous day loads and shows ITS numbers',
      (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _Repo();

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);

    // Today's own readiness ring is showing (its number is real Text, not
    // canvas-painted), and so is the stepper.
    expect(find.text('70'), findsOneWidget);
    expect(find.bySemanticsLabel('Previous day'), findsOneWidget);
    // The newest day: forward is a dead arrow.
    expect(find.bySemanticsLabel('Next day'), findsOneWidget);

    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);

    // Yesterday's readiness (42, off getDayOverview) replaced today's (70) —
    // proof the screen actually reloaded through `HomeData.loadForDay`
    // rather than just relabelling the same data.
    expect(find.text('70'), findsNothing);
    expect(find.text('42'), findsOneWidget);

    // Stepping forward again returns to today's own number.
    await t.tap(find.bySemanticsLabel('Next day'));
    await _settle(t);
    expect(find.text('70'), findsOneWidget);
  });

  test('a past day is kept only for a short absence on the same day', () {
    const day = '2026-10-31';
    expect(
        homeReturnsToToday(
            dayAtHide: day, dayNow: day, away: const Duration(minutes: 5)),
        isFalse);
    expect(
        homeReturnsToToday(
            dayAtHide: day, dayNow: day, away: const Duration(minutes: 29)),
        isFalse);
    expect(
        homeReturnsToToday(dayAtHide: day, dayNow: day, away: kHomeKeepDayAway),
        isTrue);
    // Midnight while away: today, however short the trip.
    expect(
        homeReturnsToToday(
            dayAtHide: day,
            dayNow: '2026-11-01',
            away: const Duration(minutes: 2)),
        isTrue);
    // The leave was never seen: the absence is unknown.
    expect(homeReturnsToToday(dayAtHide: null, dayNow: day, away: Duration.zero),
        isTrue);
  });

  test('a phone asleep while away still counts as away', () {
    // The stopwatch stops while the phone sleeps: an hour locked reads as a
    // minute on it, and only the wall clock sees the hour.
    expect(
        homeAwayFor(
            wall: const Duration(hours: 1),
            monotonic: const Duration(minutes: 1)),
        const Duration(hours: 1));
    // The wall clock set back while away: the stopwatch still has it.
    expect(
        homeAwayFor(
            wall: const Duration(minutes: -50),
            monotonic: const Duration(minutes: 40)),
        const Duration(minutes: 40));
  });

  testWidgets('a quick trip to another app keeps the past day', (t) async {
    final clock = _Clock();
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _Repo();

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    expect(find.text('42'), findsOneWidget);

    _background(t, clock, const Duration(minutes: 2));
    await _settle(t);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('Back to today'), findsOneWidget);
  });

  testWidgets('midnight while away opens on today, however short the trip',
      (t) async {
    final clock = _Clock()..now = DateTime(2026, 10, 31, 23, 59);
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _Repo();

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    expect(find.text('42'), findsOneWidget);

    _background(t, clock, const Duration(minutes: 2));
    await _settle(t);
    expect(find.text('70'), findsOneWidget);
    expect(find.text('Back to today'), findsNothing);
  });

  testWidgets('following today stays on today after any absence', (t) async {
    final clock = _Clock();
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _Repo();

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);
    expect(find.text('70'), findsOneWidget);

    _background(t, clock, const Duration(minutes: 2));
    await _settle(t);
    expect(find.text('70'), findsOneWidget);
    expect(find.text('Back to today'), findsNothing);
  });

  testWidgets('coming back after a long absence opens on today', (t) async {
    // Home lives on in the tab stack, so a day stepped back onto used to
    // survive a night in the background: Saturday morning opened on Friday's
    // rings with "Back to today" under them.
    final clock = _Clock();
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _Repo();

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    expect(find.text('42'), findsOneWidget);

    // A glance at Control Center only makes the app inactive: stay put.
    _lifecycle(t, const [AppLifecycleState.inactive, AppLifecycleState.resumed]);
    await _settle(t);
    expect(find.text('42'), findsOneWidget);

    // Away for half an hour: today, and no "Back to today".
    _background(t, clock, kHomeKeepDayAway);
    await _settle(t);
    expect(find.text('70'), findsOneWidget);
    expect(find.text('42'), findsNothing);
    expect(find.text('Back to today'), findsNothing);
  });

  testWidgets('a failed read on the way back drops the past day', (t) async {
    // The past day's rings must not stay up under today's header while the
    // read runs, nor for good when it fails.
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final repo = _FlakyTodayRepo();
    app.repo = repo;

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    expect(find.text('42'), findsOneWidget);

    repo.failToday = true;
    final clock = _Clock();
    _background(t, clock, const Duration(hours: 8));
    await t.pump();
    expect(find.text('42'), findsNothing);
    await _settle(t);
    expect(find.text('42'), findsNothing);
    expect(find.textContaining('Today could not be read'), findsOneWidget);
  });

  testWidgets('"Back to today" follows today instead of pinning a date',
      (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _Repo();

    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<ThemeController>.value(
            value: ThemeController.seed(
                AppThemeChoice.light, Brightness.light)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    await t.tap(find.text('Back to today'));
    await _settle(t);
    expect(find.text('70'), findsOneWidget);
    // Stored as "today" (null), which is what the day ring opens on — a
    // pinned date would hand the detail screen today's label instead.
    t.widget<RingTrio>(find.byType(RingTrio)).onOpen!(HomeRingKind.sleep);
    await _settle(t);
    expect(t.widget<SleepDetail>(find.byType(SleepDetail)).day, isNull);
  });

  testWidgets('on a past day the day breakdown opens THAT day', (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _Repo();

    // Providers above the app, so the pushed route can see them too.
    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<ThemeController>.value(
            value: ThemeController.seed(
                AppThemeChoice.light, Brightness.light)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);

    final row = find.text('Breakdown of your day');
    await t.scrollUntilVisible(row, 300,
        scrollable: find.byType(Scrollable).first);
    // The rings card now reserves more height, so the row can be BUILT (in
    // the list's cache extent) yet still below the 600 pt viewport, where a
    // tap would miss: bring it on screen before tapping.
    await t.ensureVisible(row);
    await _settle(t);
    await t.tap(row);
    await _settle(t);
    expect(t.widget<DayTimelineScreen>(find.byType(DayTimelineScreen)).day,
        _yesterday);
  });

  testWidgets('outside the shell the today sleep ring keeps the default-night push',
      (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _Repo();

    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<ThemeController>.value(
            value: ThemeController.seed(
                AppThemeChoice.light, Brightness.light)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    await t.tap(find.bySemanticsLabel('Next day'));
    await _settle(t);

    // Today, reached through the switcher, is still today: no explicit day,
    // so Sleep resolves the night the ring is drawn from.
    t.widget<RingTrio>(find.byType(RingTrio)).onOpen!(HomeRingKind.sleep);
    await _settle(t);
    expect(t.widget<SleepDetail>(find.byType(SleepDetail)).day, isNull);
    expect(t.widget<SleepDetail>(find.byType(SleepDetail)).embedded, isFalse,
        reason: 'standalone screens keep their pushed-screen fallback');
  });

  test('a past day carries the learned sleep need, so its ring has a target',
      () async {
    final d = await HomeData.loadForDay(_NeedRepo(), _yesterday);
    expect(d.sleepMin.value, 250);
    expect(d.sleepNeedMin.value, 465);
  });

  test('a past day with no learned need stays without a target', () async {
    final d = await HomeData.loadForDay(_Repo(), _yesterday);
    expect(d.sleepNeedMin.value, isNull);
  });

  testWidgets('a past day with nothing recorded says so, not "sync the band"',
      (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _EmptyPastRepo();

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);

    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);

    // The rings' help strip carries the sentence.
    expect(find.textContaining('No data for this day'), findsOneWidget);
    expect(find.text('Sync the band'), findsNothing);
  });

  testWidgets('a failed read still shows the alarm', (t) async {
    // The alarm lives on AppState, not HomeData, so the error card must not
    // take it down with it.
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _FailingRepo();

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);

    expect(find.textContaining('Today could not be read'), findsOneWidget);
    // The tile is below the fold of the 600 pt test viewport (the rings card
    // reserves more height than it did): scroll to it, then assert it is there.
    await t.scrollUntilVisible(find.text('Set an alarm'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Set an alarm'), findsOneWidget,
        reason: 'the alarm tile in At a glance');
  });

  // A day switch kept the old day on screen while it loaded, and for good if
  // the read threw: the stepper named yesterday while the rings, tiles and
  // greeting date were still today's, and nothing said the read had failed.
  testWidgets('a past day that fails to load does not keep today on screen',
      (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _PastDayThrowsRepo();

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: HomeScreen(hour: 9)),
      ),
    ));
    await _settle(t);
    expect(find.text('70'), findsOneWidget);

    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);

    expect(find.text('70'), findsNothing);
    expect(find.textContaining('could not be read'), findsOneWidget);
    expect(find.textContaining('Today could not be read'), findsNothing);

    await t.ensureVisible(find.text('Back to today'));
    await t.tap(find.text('Back to today'));
    await _settle(t);
    expect(find.text('70'), findsOneWidget);
    expect(find.textContaining('could not be read'), findsNothing);
  });

  // Home is never disposed (the shell's IndexedStack), so "Back to today"
  // storing today's literal date left the tab pinned to that date once the
  // clock crossed midnight.
  test('stepping onto today stores "today", not a date that goes stale', () {
    final evening = DateTime(2026, 10, 16, 22);
    expect(homeSwitcherDay('2026-10-16', now: evening), isNull);
    expect(homeSwitcherDay('2026-10-15', now: evening), '2026-10-15');
    expect(homeSwitcherDay(_today), isNull);
    expect(homeSwitcherDay(_yesterday), _yesterday);
  });
}

/// Today has a real reading; every past day is genuinely bare (no bundle at
/// all, not just an absent field) — the case that used to fall through to
/// the first-run "Sync the band" card regardless of which day it was.
class _EmptyPastRepo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getToday() async => {
        'daily': {
          'readiness': {'value': 70, 'confidence': .8, 'tier': 'HIGH'},
        },
        'sleep': <String, dynamic>{},
        'status': {'today_day': _today},
      };
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
  @override
  Future<List<String>> availableDays() async => [_today, _yesterday];
  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async => const {};
  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async => const {};
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => const {};
}

class _FailingRepo extends _EmptyPastRepo {
  @override
  Future<List<String>> availableDays() async => throw StateError('read failed');
}

/// `getDaySleepV2` as the live repo writes it once a need has been learned:
/// `need_min` is a plain minute count beside the night's duration.
class _NeedRepo extends _Repo {
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async =>
      {'has_sleep': true, 'duration_min': 250, 'need_min': 465};
}

/// Today reads fine; any past day throws on its first per-day read.
class _PastDayThrowsRepo extends _Repo {
  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async =>
      throw StateError('read failed');
}

/// [_Repo] whose today read can be made to throw.
class _FlakyTodayRepo extends _Repo {
  bool failToday = false;
  @override
  Future<Map<String, dynamic>> getToday() async {
    if (failToday) throw StateError('read failed');
    return super.getToday();
  }
}
