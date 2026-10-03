// 8AF B (red): Wellness > Recovery stops being a second readiness/sleep hub and
// becomes one LINK row, "Last night in Health". Wellness-only content (Mind,
// Habits, Medication, Cycle) stays. What the row asks Health for is pinned in
// health_h2_tab_request_test.dart, which is the only file that needs the new
// `HealthScreen.tabRequest`; this one compiles today and fails on content.
//
// The shell is asked to switch domain the way every other deep link does it:
// `AppState.navRequest` with a tab index whose `domainForTab` is Health.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/app.dart' show domainForTab;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/wellness_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Wellness > Recovery is a link into Health', () {
    testWidgets('it shows one "Last night in Health" row; tapping it asks the shell for Health',
        (t) async {
      final app = await openWellness(t);
      expect(find.text('Last night in Health'), findsOneWidget);

      await t.tap(find.text('Last night in Health'));
      await t.pump();

      expect(domainForTab(app.navRequest.value), ShellDomain.health,
          reason: 'the shell must be asked to switch to the Health domain');
    });

    testWidgets('it no longer carries its own readiness or sleep content',
        (t) async {
      await openWellness(t);
      expect(find.text('Review last night'), findsNothing);
      expect(find.byType(DriverBreakdown), findsNothing);
      expect(find.text('What raised and lowered your readiness'), findsNothing);
      expect(find.text('No readiness drivers yet'), findsNothing);
      expect(find.text('Sleep need tonight'), findsNothing,
          reason: 'sleep need moved to Health > Last night under Sleep');
      expect(find.textContaining('Turn in by'), findsNothing);
      expect(find.byType(Recommendation), findsNothing);
    });

    testWidgets('the other Wellness sub-tabs are all still there and none grows the link',
        (t) async {
      await openWellness(t, tab: 'Mind');
      for (final name in const ['Mind', 'Recovery', 'Habits', 'Medication']) {
        expect(find.text(name), findsWidgets, reason: 'Wellness sub-tab "$name"');
      }
      expect(find.text('Last night in Health'), findsNothing);
    });

    testWidgets('Habits and Medication still render without the link or an error',
        (t) async {
      for (final tab in const ['Habits', 'Medication']) {
        await openWellness(t, tab: tab);
        expect(find.text('Last night in Health'), findsNothing, reason: tab);
        expect(find.byType(ErrorWidget), findsNothing, reason: tab);
      }
    });
  });
}
