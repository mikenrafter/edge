// Wellness keeps its own sub-tabs (Mind, Habits, Medication, and Cycle
// while cycle tracking is on).
//
// The "Last night in Health" link row that once replaced Recovery's content
// is gone: Health has no Last night sub-tab to land on any more, and the
// sleep plan (Recovery) moved to the Sleep tab with its drivers and sleep
// need (ui2_wellness_recovery_paint_test pins those). What stays pinned here: no sub-tab grows a dead link, and the
// tabs come up without a framework error.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/ui2/screens/start_card.dart';

import 'support/wellness_link_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Wellness sub-tabs', () {
    testWidgets('the other Wellness sub-tabs are all still there and none grows the link',
        (t) async {
      await openWellness(t, tab: 'Mind');
      for (final name in const ['Mind', 'Habits', 'Medication']) {
        expect(find.text(name), findsWidgets, reason: 'Wellness sub-tab "$name"');
      }
      // The sleep plan lives on the Sleep tab now, not here.
      expect(find.text('Sleep plan'), findsNothing);
      expect(find.text('Last night in Health'), findsNothing);
    });

    testWidgets('the Mind tab comes up with no framework error (StartCard Spacer)',
        (t) async {
      // The harness no longer swallows FlutterError.onError, so an error while
      // the screen came up fails here via takeException.
      await openWellness(t, tab: 'Mind');
      expect(find.byType(StartCard), findsOneWidget);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(t.takeException(), isNull);
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
