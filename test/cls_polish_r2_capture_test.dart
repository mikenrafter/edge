// why: inspect fresh and retained Home alongside the unchanged Sleep design.
// CLAIM(home-cache-freshness); optional PNG artifacts use CLS_SHOTS_DIR.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'sleep_tab_order_test.dart' show OrderedSleepRepo;
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
  testWidgets('dark Sleep and Home polish renders', (t) async {
    phoneSurface(t);
    final repo = OrderedSleepRepo();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    final sleep = await SleepData.load(repo);
    await t.pumpWidget(
      pilotShot(
        perfApp(
          app,
          SleepDetail(embedded: true, data: sleep),
          brightness: Brightness.dark,
        ),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    await takePilotShot(t, 'sleep-flat');
    await t.pumpWidget(const SizedBox());
    final held = _Held();
    final homeApp = AppState.forTesting()..repo = held;
    addTearDown(homeApp.dispose);
    final home = HomeData(
      dayId: todayLabel(),
      readiness: const Metric(value: 22, confidence: 1),
      sleepMin: const Metric(value: 300, confidence: 1),
      sleepNeedMin: const Metric(value: 480, confidence: 1),
      strain: const Metric(value: 14, confidence: 1),
      strainTarget: const {'low': 8, 'high': 10},
    );
    await t.pumpWidget(
      pilotShot(
        perfApp(homeApp, HomeScreen(data: home), brightness: Brightness.dark),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    await takePilotShot(t, 'home-fresh');
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(
      pilotShot(
        perfApp(homeApp, const HomeScreen(), brightness: Brightness.dark),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 300));
    await takePilotShot(t, 'home-cached-loading');
    expect(find.text('Recovery 22 of 100'), findsOneWidget);
    expect(find.textContaining('Last known'), findsOneWidget);
    held.wait.complete();
    await t.pumpWidget(const SizedBox());
  });
}
