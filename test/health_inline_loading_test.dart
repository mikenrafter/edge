// The Health tab's waiting sections use the inline
// loading card, never a bare full-width spinner.
//
// USER REPORT (APK f88d230c, Health > Trends): the three trend cards, then a
// bare CircularProgressIndicator floating under them. The sub-tab bodies that
// wait on their own read (Explore's measure counts, Vitals, Labs) and the
// first page read each returned
// `Center(child: CircularProgressIndicator())`, the pattern removed from
// every calculation screen but did not list health_screen.dart.
//
// WHY/CLAIM(health-pending-structure): pending sub-tabs retain the real layout
// and its controls, using the app's pending paint rather than spinners.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _pending = find.byWidgetPredicate(
  (w) => w is PendingContent && w.pending,
  description: 'pending content',
);

Future<void> _pump(WidgetTester t, int tab) async {
  t.view.physicalSize = const Size(390, 3000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  await t.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(
          create: (_) => UnitsController.seed(UnitSystem.metric),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              ThemeController.seed(AppThemeChoice.light, Brightness.light),
        ),
        ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
        Provider<Capabilities>.value(
          value: Capabilities(const CapabilityInputs()),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        // Only the main read is handed over: the sub-tab's own read is pending.
        home: Scaffold(
          body: HealthScreen(data: const HealthData(), tab: tab),
        ),
      ),
    ),
  );
  // The first frame only: the sub-tab's own read has been asked for and has
  // not landed (a second pump would let it fail against the missing store).
}

void main() {
  // The sub-tabs with a read of their own. Overview and Trends draw from the
  // main read, which is handed over here.
  for (final (tab, name) in [(1, 'Explore'), (3, 'Vitals'), (4, 'Labs')]) {
    testWidgets('$name while its read is pending: an inline card, and the '
        'title and tabs stay', (t) async {
      await _pump(t, tab);
      expect(find.text('Health'), findsWidgets);
      expect(_pending, findsWidgets, reason: '$name is waiting on a read');
      expect(
        find.byWidgetPredicate((w) => w is ProgressIndicator),
        findsNothing,
      );
      for (final entry in _pending.evaluate()) {
        expect(
          find.ancestor(
            of: find.byElementPredicate((e) => identical(e, entry)),
            matching: find.byType(Surface),
          ),
          findsWidgets,
          reason: '$name keeps its pending content inside the card',
        );
      }
      expect(find.byType(InlineLoading), findsOneWidget);
      for (final label in ['Overview', 'Explore', 'Trends', 'Vitals', 'Labs']) {
        expect(find.text(label), findsWidgets);
      }
    });
  }
}
