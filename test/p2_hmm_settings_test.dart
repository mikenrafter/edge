import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/themed_settings_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  tearDown(() => Prefs.setExperimentalSleepHmm(false));

  testWidgets(
    'experimental HMM row starts off, explains limits, and selects HMM',
    (t) async {
      g123View(t, height: 3000);
      await t.pumpWidget(
        g123App(
          StatefulBuilder(
            builder: (context, setState) {
              return MoreSettingsView(
                experimentalSleepHmm: Prefs.experimentalSleepHmm,
                onToggleExperimentalSleepHmm: () => setState(() {
                  Prefs.setExperimentalSleepHmm(!Prefs.experimentalSleepHmm);
                }),
              );
            },
          ),
        ),
      );
      await g123Settle(t);
      final row = find.byKey(const ValueKey('experimental-sleep-hmm'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.text('Experimental sleep staging (HMM)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('Off')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('Not medical advice'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.textContaining('finalized nights stay unchanged'),
        ),
        findsOneWidget,
      );
      expect(Prefs.sleepStagingMethod, ana.StagingMethod.cardio);
      await t.tap(row);
      await g123Settle(t);
      expect(
        find.descendant(of: row, matching: find.text('On')),
        findsOneWidget,
      );
      expect(Prefs.sleepStagingMethod, ana.StagingMethod.hmm628);
      await t.tap(row);
      await g123Settle(t);
      expect(Prefs.experimentalSleepHmm, isFalse);
      expect(Prefs.sleepStagingMethod, ana.StagingMethod.cardio);
    },
  );
}
