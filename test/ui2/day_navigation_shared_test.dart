import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/profile/gallery.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const past = '2026-05-19';
const days = ['2026-05-22', '2026-05-20', past];

class HeldRepo extends LocalRepository {
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
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light),
    navigatorObservers: [if (observer != null) observer],
    home: app == null ? page : ChangeNotifierProvider<AppState>.value(
      value: app, child: page)));
  await t.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // WHY: every production date page must offer the same escape while its read
  // is pending. Removing one installation must fail. CLAIM(day-navigation-immediate).
  testWidgets('all date pages offer today while available dates are pending', (t) async {
    final pages = <String, Widget>{
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
      expect(find.text('Back to today').hitTestable(), findsOneWidget,
        reason: '${entry.key} must remain navigable before availableDays completes');
      await t.pumpWidget(const SizedBox());
      app.dispose();
    }
  });

  // WHY: Vitals is embedded and must use the same floating control.
  testWidgets('Vitals offers today on a historical day', (t) async {
    await frame(t, const Scaffold(body: HealthScreen(
      data: HealthData(), vitals: VitalsData(day: past, days: days), tab: 3)));
    expect(find.text('Back to today').hitTestable(), findsOneWidget);
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
  });

  // WHY: choosing today explicitly must not resolve to an older completed night.
  test('Sleep explicitly reads today even when it is absent from available days', () async {
    final repo = EmptyTodayRepo();
    final read = await SleepData.load(repo, want: '2026-05-22');
    expect(read.day, '2026-05-22');
    expect(read.night['has_sleep'], isNot(true));
    expect(repo.requested, ['2026-05-22']);
  });

  // WHY: the gallery must demonstrate the production component, not a copy.
  testWidgets('gallery includes back to today', (t) async {
    final cases = galleryCases();
    expect(cases.containsKey('back_to_today'), isTrue);
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
