// The rings card's help strip, loaded with a ring value but no recovery
// drivers: it must not be an empty reserved box. It shows the "Why?" link to
// the recovery breakdown, with no invented driver list.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  testWidgets('rings drawn and no drivers: the strip has a Why link',
      (t) async {
    final opened = <HomeRingKind>[];
    final d = HomeData(
      dayId: '2026-10-04',
      // All three rings drawn, so no gap reason fills the strip either.
      readiness: const Metric(value: 74, confidence: .8, tier: MetricTier.high),
      strain: const Metric(value: 8.2, confidence: .8, tier: MetricTier.high),
      sleepMin: const Metric(value: 430, confidence: .8, tier: MetricTier.high),
    );
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: RingTrio(
            d: d,
            now: DateTime(2026, 10, 4, 15),
            onOpen: opened.add,
          ),
        ),
      ),
    ));
    await t.pump();

    final why = find.text('Why?');
    expect(why, findsOneWidget, reason: 'the strip is not an empty box');
    await t.tap(why);
    expect(opened, [HomeRingKind.recovery]);
  });

  testWidgets('no ring has a value: no Why link', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: RingTrio(
            d: const HomeData(dayId: '2026-10-04'),
            now: DateTime(2026, 10, 4, 15)),
      ),
    ));
    await t.pump();
    expect(find.text('Why?'), findsNothing);
  });
}
