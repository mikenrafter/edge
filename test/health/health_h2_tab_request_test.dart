// 8AF B (red): the Wellness link lands on Health > Last night.
//
// API assumed, mirroring `WellnessScreen.tabRequest`: `HealthScreen.tabRequest`,
// a static ValueNotifier<int> (-1 = none). The Wellness row writes 0 to it;
// HealthScreen reads it in initState (the shell re-keyed and built a fresh
// Health) and listens to it (Health already on screen, kept alive by the shell's
// IndexedStack); the shell clears it a frame later. Isolated in its own file
// because it is the only thing that needs the new symbol.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/wellness_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HealthScreen.tabRequest.value = -1;
  });
  tearDown(() => HealthScreen.tabRequest.value = -1);

  testWidgets('tapping "Last night in Health" asks Health for sub-tab 0',
      (t) async {
    await openWellness(t);
    await t.tap(find.text('Last night in Health'));
    await t.pump();
    expect(HealthScreen.tabRequest.value, 0,
        reason: 'Last night is the first sub-tab');
  });

  Future<void> pumpHealth(WidgetTester t, {required int tab}) async {
    t.view.physicalSize = const Size(390 * 3, 6000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
          body: HealthScreen(
              data: HealthData(today: {
                'sleep': {
                  'duration_min': {
                    'value': 465,
                    'confidence': .8,
                    'tier': 'ESTIMATE',
                    'inputs_used': const <String>[],
                  },
                },
                'stress': {
                  'value': 28,
                  'score': 28,
                  'level': 'Low',
                  'confidence': .55,
                  'tier': 'ESTIMATE',
                },
              }),
              tab: tab)),
    ));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  // "Overnight stress" is a Last night row and nothing else's.
  int onLastNight(WidgetTester t) => t
      .widgetList<MetricRow>(find.byType(MetricRow))
      .where((r) => r.name == 'Overnight stress')
      .length;

  testWidgets('Health already on Trends: a request for 0 switches to Last night',
      (t) async {
    await pumpHealth(t, tab: 2);
    expect(onLastNight(t), 0, reason: 'precondition: Trends is not Last night');
    HealthScreen.tabRequest.value = 0;
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(onLastNight(t), 1);
  });

  testWidgets('Health mounted after the request (shell re-keyed) opens on Last night',
      (t) async {
    HealthScreen.tabRequest.value = 0;
    await pumpHealth(t, tab: 2);
    expect(onLastNight(t), 1);
  });
}
