import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';

import 'support/themed_settings_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'experimental HMM row starts off, explains limits, and reports the toggle',
    (t) async {
      g123View(t, height: 3000);
      var on = false;
      await t.pumpWidget(
        g123App(
          StatefulBuilder(
            builder: (context, setState) {
              return MoreSettingsView(
                experimentalSleepHmm: on,
                onToggleExperimentalSleepHmm: () => setState(() => on = !on),
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
      expect(on, isFalse);
      await t.tap(row);
      await g123Settle(t);
      expect(
        find.descendant(of: row, matching: find.text('On')),
        findsOneWidget,
      );
      expect(on, isTrue);
      await t.tap(row);
      await g123Settle(t);
      expect(on, isFalse);
    },
  );
}
