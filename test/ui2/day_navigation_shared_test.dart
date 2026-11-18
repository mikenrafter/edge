import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/profile/gallery.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const past = '2026-05-19';
const days = ['2026-05-22', '2026-05-20', past];

class HeldRepo extends LocalRepository {
  HeldRepo() { dates.future.ignore(); }
  final dates = Completer<List<String>>();
  @override
  Future<List<String>> availableDays() => dates.future;
  @override
  Future<Map<String, dynamic>> getToday() async => {};
}

class PushCounter extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) pushes++;
  }
}

Future<void> frame(WidgetTester t, Widget page, {AppState? app,
    NavigatorObserver? observer}) async {
  t.view.physicalSize = const Size(412, 1800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(ChangeNotifierProvider<ThemeController>(
    create: (_) => ThemeController.seed(AppThemeChoice.light, Brightness.light),
    child: MaterialApp(theme: buildTheme(Brightness.light),
    navigatorObservers: [?observer],
    home: app == null ? page : ChangeNotifierProvider<AppState>.value(
      value: app, child: page))));
  await t.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // WHY: every production date page must offer the same escape while its read
  // is pending. Removing one installation must fail. CLAIM(day-navigation-immediate).
  testWidgets('all date pages offer today while available dates are pending', (t) async {
    final pages = <String, Widget>{
      'Home': const HomeScreen(data: HomeData()),
      'Sleep': const SleepDetail(day: past),
      'Timeline': const DayTimelineScreen(day: past),
      'Steps': const DayStepsDetail(day: past),
      'Strain': const DayStrainDetail(day: past),
      'Beats': const Beats(day: past),
      'Naps': const NapsScreen(day: past),
      'Investigate': const Investigate('hrv', day: past),
      'What changed': const WhatChangedScreen(day: past),
    };
    for (final entry in pages.entries) {
      final app = AppState.forTesting()..repo = HeldRepo();
      await frame(t, entry.value, app: app);
      if (entry.key == 'Home') {
        t.widget<DayNav>(find.byType(DayNav)).onDay(past);
        await t.pump();
      }
      expect(find.text('Back to today').hitTestable(), findsOneWidget,
        reason: '${entry.key} must remain navigable before availableDays completes');
      (app.repo as HeldRepo).dates.completeError(const FormatException('locked'));
      await t.pump();
      expect(find.text('Back to today').hitTestable(), findsOneWidget,
        reason: '${entry.key} must remain navigable after read failure');
      await t.pumpWidget(const SizedBox());
      app.dispose();
    }
  });

  // WHY: Vitals is embedded and must use the same floating control.
  testWidgets('Vitals offers today on a historical day', (t) async {
    await frame(t, const Scaffold(body: HealthScreen(
      data: HealthData(), vitals: VitalsData(day: past, days: days), tab: 3)));
    expect(find.text('Back to today').hitTestable(), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    final app = AppState.forTesting()..repo = HeldRepo();
    await frame(t, const Scaffold(body: HealthScreen(tab: 3)), app: app);
    expect(find.byType(DayNav), findsOneWidget,
      reason: 'Vitals navigation cannot wait for the Health overview read');
    t.widget<DayNav>(find.byType(DayNav)).onDay(past);
    await t.pump();
    expect(find.text('Back to today').hitTestable(), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });

  // WHY: rapid route callbacks must push once and unlock after return.
  testWidgets('go latches repeated pushes until return', (t) async {
    final counter = PushCounter();
    late BuildContext origin;
    await frame(t, Builder(builder: (c) {
      origin = c;
      return const Scaffold(body: Text('origin'));
    }), observer: counter);
    final first = go(origin, const Scaffold(body: Text('destination')));
    final duplicate = go(origin, const Scaffold(body: Text('destination')));
    await t.pumpAndSettle();
    expect(counter.pushes, 1);
    Navigator.of(origin).pop();
    await t.pumpAndSettle();
    await first;
    await duplicate;
    final next = go(origin, const Scaffold(body: Text('destination')));
    await t.pumpAndSettle();
    expect(counter.pushes, 2);
    Navigator.of(origin).pop();
    await t.pumpAndSettle();
    await next;
    final picker = chooseDay(origin, days, past);
    final duplicatePicker = chooseDay(origin, days, past);
    await t.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    Navigator.of(origin).pop(DateTime(2026, 5, 20));
    await t.pumpAndSettle();
    expect(await picker, '2026-05-20');
    expect(await duplicatePicker, isNull);
  });

  // WHY: choosing today explicitly must not resolve to an older completed night.
  testWidgets('Sleep explicitly reads today even when it is absent from available days', (t) async {
    final repo = EmptyTodayRepo();
    final read = await SleepData.load(repo, want: '2026-05-22');
    expect(read.day, '2026-05-22');
    expect(read.night['has_sleep'], isNot(true));
    expect(repo.requested, ['2026-05-22']);
    final today = todayLabel();
    final held = HeldRepo();
    final app = AppState.forTesting()..repo = held;
    await frame(t, SleepDetail(day: past, data: SleepData(
      day: past, latestDay: today, days: [today, past])), app: app);
    await t.tap(find.text('Back to today'));
    await t.pump();
    expect(t.widget<DayNav>(find.byType(DayNav)).day, today);
    expect(find.text('Back to today'), findsNothing);
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });

  // WHY: a date switch must remove the prior measurements on the next frame,
  // and must allow another arrow before that read finishes.
  testWidgets('rapid arrows show placeholders for the final selected day', (t) async {
    final repo = StepsRepo();
    final app = AppState.forTesting()..repo = repo;
    await frame(t, const DayStepsDetail(day: '2026-05-22',
      data: DayStepsData(day: '2026-05-22', days: days,
        dayTotal: 987, daySource: 'strap_counter')), app: app);
    await t.tap(find.byKey(const ValueKey('day-nav-previous')));
    await t.pump();
    expect(t.widget<DayNav>(find.byType(DayNav)).day, '2026-05-20');
    expect(find.byType(PendingChart), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('day-nav-previous')));
    await t.pump();
    expect(t.widget<DayNav>(find.byType(DayNav)).day, past);
    expect(find.byType(PendingChart), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });

  // WHY: an older read finishing last must not paint its measurements under
  // the final selected date. CLAIM(day-navigation-immediate).
  testWidgets('late prior day read cannot replace the final day', (t) async {
    final repo = StepsRepo();
    final app = AppState.forTesting()..repo = repo;
    await frame(t, const DayStepsDetail(day: '2026-05-22',
      data: DayStepsData(day: '2026-05-22', days: days)), app: app);
    t.widget<DayNav>(find.byType(DayNav)).onDay('2026-05-20');
    await t.pump();
    t.widget<DayNav>(find.byType(DayNav)).onDay(past);
    await t.pump();
    repo.oldest.complete({'day_total': 222, 'day_source': 'strap_counter'});
    await repo.oldest.future;
    await t.pump();
    await t.pump();
    expect(find.textContaining('222 steps'), findsOneWidget,
      reason: t.widgetList<Text>(find.byType(Text)).map((w) => w.data).join(' | '));
    repo.middle.complete({'day_total': 111, 'day_source': 'strap_counter'});
    await repo.middle.future;
    await t.pump();
    await t.pump();
    expect(find.textContaining('222 steps'), findsOneWidget,
      reason: t.widgetList<Text>(find.byType(Text)).map((w) => w.data).join(' | '));
    expect(find.textContaining('111 steps'), findsNothing);
    expect(t.widget<DayNav>(find.byType(DayNav)).day, past);
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });

  // WHY: a kept-alive page must reveal today after midnight and refresh on
  // foreground even when no repository read or parent rebuild occurs.
  testWidgets('today visibility refreshes at midnight and resume', (t) async {
    var now = DateTime(2026, 5, 22, 23, 59, 59);
    await withClock(Clock(() => now), () async {
      final picked = <String>[];
      await frame(t, Scaffold(body: backToTodayControl(
        selectedDay: '2026-05-22', onSelect: picked.add)));
      expect(find.text('Back to today'), findsNothing);
      now = DateTime(2026, 5, 23);
      await t.pump(const Duration(seconds: 1));
      expect(find.text('Back to today'), findsOneWidget);
      final button = find.byKey(const ValueKey('home-back-to-today'));
      expect(t.getSize(button).height, greaterThanOrEqualTo(48));
      await t.tap(button);
      expect(picked, ['2026-05-23']);
      now = DateTime(2026, 5, 22, 15);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      expect(find.text('Back to today'), findsNothing);
      await t.pumpWidget(const SizedBox());
    });
  });

  // WHY: every page must keep its arrows live while a replacement read is
  // pending. A fresh date list must not be needed for the next tap.
  testWidgets('all seeded date pages accept another arrow during a read', (t) async {
    final pages = <String, Widget>{
      'Sleep': const SleepDetail(day: '2026-05-22',
        data: SleepData(day: '2026-05-22', days: days)),
      'Timeline': const DayTimelineScreen(day: '2026-05-22',
        data: TimelineData(day: '2026-05-22', days: days)),
      'Steps': const DayStepsDetail(day: '2026-05-22',
        data: DayStepsData(day: '2026-05-22', days: days)),
      'Strain': DayStrainDetail(day: '2026-05-22',
        data: DayStrainData(day: DateTime(2026, 5, 22), days: days)),
      'Beats': const Beats(day: '2026-05-22',
        data: BeatsData(day: '2026-05-22', days: days)),
      'Investigate': const Investigate('hrv', day: '2026-05-22',
        data: InvestigateData(day: '2026-05-22', days: days)),
      'What changed': const WhatChangedScreen(day: '2026-05-22',
        data: WhatChangedData(day: '2026-05-22', days: days)),
      'Vitals': const Scaffold(body: HealthScreen(data: HealthData(),
        vitals: VitalsData(day: '2026-05-22', days: days), tab: 3)),
    };
    for (final entry in pages.entries) {
      final app = AppState.forTesting()..repo = HeldRepo();
      await frame(t, entry.value, app: app);
      t.widget<DayNav>(find.byType(DayNav)).onDay('2026-05-20');
      await t.pump();
      expect(t.widget<DayNav>(find.byType(DayNav)).days, days,
        reason: '${entry.key} lost its arrows during a read');
      await t.tap(find.byKey(const ValueKey('day-nav-previous')));
      await t.pump();
      expect(t.widget<DayNav>(find.byType(DayNav)).day, past,
        reason: '${entry.key} blocked a second arrow');
      await t.pumpWidget(const SizedBox());
      app.dispose();
    }
  });

  // WHY: the gallery must demonstrate the production component, not a copy.
  testWidgets('gallery includes back to today', (t) async {
    final cases = galleryCases();
    expect(cases.containsKey('back_to_today'), isTrue);
    expect(cases['back_to_today'].runtimeType,
      backToTodayControl(selectedDay: past, onSelect: (_) {}).runtimeType);
    await frame(t, Scaffold(body: cases['back_to_today']));
    expect(find.text('Back to today'), findsOneWidget);
  });
}

class EmptyTodayRepo extends LocalRepository {
  final requested = <String>[];
  @override
  Future<List<String>> availableDays() async => [past];
  @override
  Future<Map<String, dynamic>> getToday() async => {};
  @override
  Future<SleepDetailBundle> getSleepDetailBundle(String day,
      {required List<String> chartKeys, required int windowDays, String? before}) async {
    requested.add(day);
    return const SleepDetailBundle(night: {}, timeline: {}, insights: {}, charts: {}, windows: []);
  }
}

class StepsRepo extends LocalRepository {
  final middle = Completer<Map<String, dynamic>>();
  final oldest = Completer<Map<String, dynamic>>();
  @override
  Future<List<String>> availableDays() async => days;
  @override
  Future<Map<String, dynamic>> getInsights() async => {};
  @override
  Future<Map<String, dynamic>> getDaySteps(String day) =>
    day == past ? oldest.future : middle.future;
}
