// Import focus, UI side, part 2: a 30-day metric chart, the month grid (on
// What changed) and the Explorer. See ui2_read_paused_test.dart for the rules.
// A series read is never today-or-yesterday, so it is always paused.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/read_paused_fakes.dart';

Future<void> _settle(WidgetTester t, {int n = 40}) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _pump(WidgetTester t, FocusRepo repo, Widget home) async {
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  app.repo = repo;
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<ThemeController>.value(
          value: ThemeController.seed(AppThemeChoice.light, Brightness.light)),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: home),
    ),
  ));
  await _settle(t);
}

void main() {
  setUp(resetFocus);
  tearDown(resetFocus);

  group('metric detail, 30 days', () {
    testWidgets('paused: the line stands where the chart goes, nothing '
        'loops, and one reload when focus ends', (t) async {
      startFocus();
      final repo = FocusRepo();
      await _pump(t, repo, const MetricDetail('strain', initialRange: 30));

      expect(find.text(kPausedLine), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('could not be read'), findsNothing);
      expect(find.textContaining('Try again'), findsNothing);

      final before = repo.reads.length;
      await _settle(t, n: 400);
      expect(repo.reads.length, before, reason: 'no retry loop while paused');

      final charts = repo.count('getChart');
      endFocus();
      await _settle(t);
      expect(find.text(kPausedLine), findsNothing);
      expect(repo.count('getChart'), charts + 1,
          reason: 'one reload of the series when focus ends');
    });
  });

  group('month grid (What changed)', () {
    testWidgets('paused: the grid says older days load later, quietly',
        (t) async {
      startFocus();
      final repo = FocusRepo();
      await _pump(t, repo, const WhatChangedScreen());

      expect(find.text(kPausedLine), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('could not be read'), findsNothing);
      expect(find.textContaining('Try again'), findsNothing);

      final before = repo.reads.length;
      await _settle(t, n: 400);
      expect(repo.reads.length, before, reason: 'no retry loop while paused');
    });

    testWidgets('focus ends: the screen reloads by itself, once', (t) async {
      startFocus();
      final repo = FocusRepo();
      await _pump(t, repo, const WhatChangedScreen());
      final days = repo.count('availableDays');

      endFocus();
      await _settle(t);
      expect(find.text(kPausedLine), findsNothing);
      expect(repo.count('availableDays'), days + 1);
    });
  });


}
