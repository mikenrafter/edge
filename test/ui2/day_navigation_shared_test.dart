import 'dart:async';
import 'package:flutter/rendering.dart';

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
import 'package:openstrap_edge/ui2/screens/explorer.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import '../support/explorer_harness.dart' show ExplorerRepo, initPrefs, loadType;

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
  setUpAll(() async {
    await initPrefs();
    await loadType();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // WHY: every production date page must offer the same escape while its read
  // is pending, and the escape must actually go to today (a page wired with
  // `onSelect: (_) {}` must fail). Removing one installation must fail.
  // CLAIM(day-navigation-immediate).
  testWidgets('all date pages offer today while available dates are pending', (t) async {
    final pages = <String, (Widget, LocalRepository Function(), Future<void> Function()?)>{
      'Home': (const HomeScreen(data: HomeData()), HeldRepo.new, () async {
        t.widget<DayNav>(find.byType(DayNav)).onDay(past);
        await t.pump();
      }),
      'Sleep': (const SleepDetail(day: past), HeldRepo.new, null),
      'Timeline': (const DayTimelineScreen(day: past), HeldRepo.new, null),
      'Steps': (const DayStepsDetail(day: past), HeldRepo.new, null),
      'Strain': (const DayStrainDetail(day: past), HeldRepo.new, null),
      'Beats': (const Beats(day: past), HeldRepo.new, null),
      'Naps': (const NapsScreen(day: past), HeldRepo.new, null),
      'Investigate': (const Investigate('hrv', day: past), HeldRepo.new, null),
      'What changed': (const WhatChangedScreen(day: past), HeldRepo.new, null),
      'Data explorer': (ExplorerScreen(annotationLoader: (_, _) async => const []), ExplorerRepo.new, () async {
        await t.tap(find.byKey(const ValueKey('explore-scale:day')));
        await t.pump();
        await t.tap(find.byKey(const ValueKey('explore-day-prev')));
        await t.pump();
      }),
    };
    for (final entry in pages.entries) {
      final (page, makeRepo, open) = entry.value;
      final app = AppState.forTesting()..repo = makeRepo();
      await frame(t, page, app: app);
      if (open != null) await open();
      expect(find.text('Back to today').hitTestable(), findsOneWidget,
        reason: '${entry.key} must remain navigable before availableDays completes');
      if (app.repo case final HeldRepo held) {
        held.dates.completeError(const FormatException('locked'));
        await t.pump();
        expect(find.text('Back to today').hitTestable(), findsOneWidget,
          reason: '${entry.key} must remain navigable after read failure');
      }
      await t.tap(find.text('Back to today'));
      await t.pump();
      expect(find.text('Back to today'), findsNothing,
        reason: '${entry.key}: the pill must take the page to today');
      final nav = find.byType(DayNav);
      if (nav.evaluate().isNotEmpty) {
        // Home shows today as a null day.
        expect(t.widget<DayNav>(nav).day, anyOf(isNull, todayLabel()),
          reason: '${entry.key}: the shown day must become today');
      }
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

  // WHY (S1): a pushed page puts the frame outside its Scaffold, so the pill
  // had no Material ancestor and drew MaterialApp's yellow double underline.
  testWidgets('Back to today has no inherited underline on a pushed page', (t) async {
    final app = AppState.forTesting()..repo = HeldRepo();
    late BuildContext origin;
    await frame(t, Builder(builder: (c) {
      origin = c;
      return const Scaffold(body: Text('origin'));
    }), app: app);
    unawaited(go(origin, const DayStepsDetail(day: past,
      data: DayStepsData(day: past, days: days))));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final paragraph = t.renderObject<RenderParagraph>(find.text('Back to today'));
    final decoration = (paragraph.text as TextSpan).style?.decoration;
    expect(decoration == null || decoration == TextDecoration.none, isTrue,
      reason: 'pill text decoration was $decoration');
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });

  // WHY (S2): a double tap must open each destination once; the moment editor
  // must also open at once instead of after two awaited reads.
  testWidgets('route-opening actions on date pages open once on a double tap', (t) async {
    // Two taps before any frame: what a fast double tap does. The row's own
    // handler is called, so a row scrolled off the test surface still counts.
    void tapTwice(Finder label) {
      final press = find.ancestor(of: label, matching: find.byType(Pressable)).first;
      final onTap = t.widget<Pressable>(press).onTap!;
      onTap();
      onTap();
    }
    final sites = <String, Future<void> Function(PushCounter)>{
      'moment editor': (counter) async {
        await frame(t, const DayTimelineScreen(day: past,
          data: TimelineData(day: past, days: days)), observer: counter,
          app: AppState.forTesting()..repo = HeldRepo());
        final state = t.state(find.byType(DayTimelineScreen)) as dynamic;
        const m = Moment(at: 0, title: 'x', icon: Icons.add, editRef: 'moment:2026-05-19 08:00');
        unawaited(state.openRowEditor(m) as Future<void>);
        unawaited(state.openRowEditor(m) as Future<void>);
      },
      'workout editor': (counter) async {
        await frame(t, const DayTimelineScreen(day: past,
          data: TimelineData(day: past, days: days)), observer: counter,
          app: AppState.forTesting()..repo = HeldRepo());
        final state = t.state(find.byType(DayTimelineScreen)) as dynamic;
        const m = Moment(at: 0, title: 'x', icon: Icons.add, editRef: 'session:abc|run');
        unawaited(state.openRowEditor(m) as Future<void>);
        unawaited(state.openRowEditor(m) as Future<void>);
      },
      'briefing': (counter) async {
        await frame(t, const HomeScreen(data: HomeData()), observer: counter,
          app: AppState.forTesting()..repo = HeldRepo());
        tapTwice(find.text('Briefing'));
      },
      'zones': (counter) async {
        await frame(t, DayStrainDetail(day: '2026-05-22',
          data: DayStrainData(day: DateTime(2026, 5, 22), days: days,
            zoneMin: const [10, 20, 30, 5, 1])),
          observer: counter, app: AppState.forTesting()..repo = HeldRepo());
        tapTwice(find.text('How these are set'));
      },
    };
    final wrong = <String>[];
    for (final entry in sites.entries) {
      final counter = PushCounter();
      await entry.value(counter);
      if (counter.pushes != 1) wrong.add('${entry.key}: ${counter.pushes} pushes');
      await t.pumpWidget(const SizedBox());
    }
    expect(wrong, isEmpty, reason: 'each destination must open exactly once');
  });

  // WHY (S4): entering and leaving Vitals must not remount the Health list
  // (scroll offset and sub-tab state would reset).
  testWidgets('switching Health sub-tabs keeps the same list mounted', (t) async {
    t.view.physicalSize = const Size(412, 500);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(ChangeNotifierProvider<ThemeController>(
      create: (_) => ThemeController.seed(AppThemeChoice.light, Brightness.light),
      child: MaterialApp(theme: buildTheme(Brightness.light),
        home: const Scaffold(body: HealthScreen(data: HealthData(),
          vitals: VitalsData(day: past, days: days))))));
    await t.pump();
    final title = t.element(find.byType(ScreenTitle));
    final list = t.state<ScrollableState>(find.byType(Scrollable).first);
    list.position.jumpTo(24);
    await t.pump();
    await t.tap(find.text('Vitals'));
    await t.pump();
    expect(identical(t.element(find.byType(ScreenTitle)), title), isTrue,
      reason: 'entering Vitals remounted the page');
    expect(t.state<ScrollableState>(find.byType(Scrollable).first).position.pixels,
      24, reason: 'entering Vitals reset the scroll offset');
    await t.tap(find.text('Overview'));
    await t.pump();
    expect(identical(t.element(find.byType(ScreenTitle)), title), isTrue,
      reason: 'leaving Vitals remounted the page');
    await t.pumpWidget(const SizedBox());
  });

  // WHY (S5): ordinary landing stays on the newest derived day; only an
  // explicit request for today may resolve to a day with no derived data.
  test('default landing keeps the newest day with data', () {
    final today = todayLabel();
    expect(pickDay([past], null, today), past);
    expect(pickDay([past], today), today);
    expect(pickDay(days, null, today), days.first);
  });

  // NIT: one clock. Under withClock the helpers must agree with the control.
  test('pickDay and dayNavLabel read the injected clock', () {
    withClock(Clock.fixed(DateTime(2031, 3, 4, 12)), () {
      expect(dayNavLabel('2031-03-04'), 'Today');
      expect(pickDay([past], '2031-03-04'), '2031-03-04');
      expect(pickDay([past], null, '2031-03-04'), past);
    });
  });

  // NIT: the pill is one accessibility node announced once.
  testWidgets('Back to today is announced once', (t) async {
    final handle = t.ensureSemantics();
    await frame(t, Scaffold(body: backToTodayControl(
      selectedDay: past, onSelect: (_) {})));
    expect(t.getSemantics(find.byKey(const ValueKey('home-back-to-today'))).label,
      'Back to today');
    handle.dispose();
  });

  // NIT: only framed pages reserve room for the pill.
  testWidgets('detail padding grows only on framed pages', (t) async {
    await frame(t, Builder(builder: (c) => detailScaffold(c, 'T', const [])));
    EdgeInsets padding() => t.widget<ListView>(find.byType(ListView)).padding!
      as EdgeInsets;
    expect(padding().bottom, S.x12);
    await t.pumpWidget(const SizedBox());
    final app = AppState.forTesting()..repo = HeldRepo();
    await frame(t, const DayStepsDetail(day: past,
      data: DayStepsData(day: past, days: days)), app: app);
    expect(padding().bottom, S.x16);
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });

  // HARDENING: an unfocused-but-visible app still crosses midnight.
  testWidgets('midnight pill appears while the app is inactive', (t) async {
    var now = DateTime(2026, 5, 22, 23, 59, 59);
    await withClock(Clock(() => now), () async {
      await frame(t, Scaffold(body: backToTodayControl(
        selectedDay: '2026-05-22', onSelect: (_) {})));
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      now = DateTime(2026, 5, 23);
      await t.pump(const Duration(seconds: 1));
      expect(find.text('Back to today'), findsOneWidget,
        reason: 'an inactive (visible) app missed midnight');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpWidget(const SizedBox());
    });
  });

  // HARDENING: a clock-zone change while resumed is noticed within a bounded
  // time, not at the old zone's midnight.
  testWidgets('midnight pill notices a zone change while resumed', (t) async {
    var now = DateTime(2026, 5, 22, 12);
    await withClock(Clock(() => now), () async {
      await frame(t, Scaffold(body: backToTodayControl(
        selectedDay: '2026-05-22', onSelect: (_) {})));
      expect(find.text('Back to today'), findsNothing);
      now = DateTime(2026, 5, 23, 12); // the zone moved forward a day
      await t.pump(const Duration(minutes: 20));
      expect(find.text('Back to today'), findsOneWidget,
        reason: "a zone change was only noticed at the old zone's midnight");
      await t.pumpWidget(const SizedBox());
    });
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
