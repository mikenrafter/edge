import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/theme.dart';

import 'support/bundled_fonts.dart';
import 'support/pilot_shots.dart';

void main() {
  setUpAll(loadFonts);

  // why: moving the caption must leave the ring card and all three dials in place.
  for (final scale in [1.0, 1.3]) {
    testWidgets('centres the caption above the dials at ${scale}x', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(390, 420);
      t.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(t.view.reset);
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      const metric = Metric(value: 80, confidence: .8, tier: MetricTier.high);
      const cardKey = ValueKey('ring-card');
      final since = DateTime(2026, 11, 20, 2, 15);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: pilotShot(SingleChildScrollView(child: Padding(
          padding: const EdgeInsets.all(16),
          child: RingTrio(
            key: cardKey, since: since, now: since,
            d: const HomeData(
              dayId: '2026-11-20',
              readiness: metric,
              strain: Metric(value: 7, confidence: .8, tier: MetricTier.high),
              sleepMin: Metric(value: 445, confidence: .8, tier: MetricTier.high),
              sleepNeedMin: Metric(value: 480, confidence: .8, tier: MetricTier.high),
            ),
          ),
        )))),
      ));
      await t.pumpAndSettle();

      final card = t.getRect(find.byKey(cardKey));
      final caption = t.getRect(find.text('since 02:15'));
      final dials = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Dial');
      expect(dials, findsNWidgets(3));
      final dialTop = t.getTopLeft(dials.first).dy;
      final gap = dialTop - card.top;
      // Measured against 90dbb915d with the same font, viewport and data.
      expect(card.height, closeTo(scale == 1.0 ? 228 : 303.4, .01));
      expect(gap, closeTo(scale == 1.0 ? 42 : 47.4, .01));
      await takePilotShot(t, 'ring-$scale-build');
      expect((caption.top - card.top) - (dialTop - caption.bottom), closeTo(0, 1));
    });
  }
}
