// A deep link asking Health for one of its sub-tabs.
//
// `HealthScreen.tabRequest`, mirroring `WellnessScreen.tabRequest`: a static
// ValueNotifier<int> (-1 = none). HealthScreen reads it in initState (the
// shell re-keyed and built a fresh Health) and listens to it (Health already
// on screen, kept alive by the shell's IndexedStack); the shell clears it a
// frame later. (The Wellness "Last night in Health" row that used to write it
// is gone with the Last night sub-tab; the mechanism stays for deep links.)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

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

  // The Stress row is on Overview (sub-tab 0) and nowhere else.
  int onOverview(WidgetTester t) => t
      .widgetList<MetricRow>(find.byType(MetricRow))
      .where((r) => r.name == 'Stress')
      .length;

  testWidgets('Health already on Trends: a request for 0 switches to Overview',
      (t) async {
    await pumpHealth(t, tab: 2);
    expect(onOverview(t), 0, reason: 'precondition: Trends is not Overview');
    HealthScreen.tabRequest.value = 0;
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(onOverview(t), 1);
  });

  testWidgets('Health mounted after the request (shell re-keyed) opens on Overview',
      (t) async {
    HealthScreen.tabRequest.value = 0;
    await pumpHealth(t, tab: 2);
    expect(onOverview(t), 1);
  });
}
