// The rings card, loaded with ring values but no recovery drivers: it must not
// be an empty reserved box. The "Why?" link is gone (owner CLS DECIDED 3): a
// healthy day shows nothing under the rings, and a pressing ring gets its own
// why panel, which opens that ring, with no invented driver list.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  Widget rings(HomeData d, List<HomeRingKind> opened) => MaterialApp(
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
      );

  testWidgets('rings drawn and no drivers: no Why link, no empty strip',
      (t) async {
    final opened = <HomeRingKind>[];
    await t.pumpWidget(rings(
        HomeData(
          dayId: '2026-10-04',
          // All three rings drawn, so no gap reason fills the strip either.
          readiness: const Metric(value: 74, confidence: .8, tier: MetricTier.high),
          strain: const Metric(value: 8.2, confidence: .8, tier: MetricTier.high),
          sleepMin: const Metric(value: 430, confidence: .8, tier: MetricTier.high),
        ),
        opened));
    await t.pump();
    expect(find.text('Why?'), findsNothing);
    expect(find.textContaining('Why'), findsNothing);
    expect(find.byKey(const ValueKey('home-why:recovery')), findsNothing);
  });

  testWidgets('a pressing ring with no drivers: its why panel replaces the link',
      (t) async {
    final opened = <HomeRingKind>[];
    await t.pumpWidget(rings(
        HomeData(
          dayId: '2026-10-04',
          readiness: const Metric(value: 20, confidence: .8, tier: MetricTier.high),
          strain: const Metric(value: 8.2, confidence: .8, tier: MetricTier.high),
          sleepMin: const Metric(value: 430, confidence: .8, tier: MetricTier.high),
        ),
        opened));
    await t.pump();
    expect(find.text('Why?'), findsNothing);
    final panel = find.byKey(const ValueKey('home-why:recovery'));
    expect(panel, findsOneWidget);
    // No driver list is invented: the plain number only.
    expect(find.text('Recovery 20 of 100'), findsOneWidget);
    await t.tap(panel);
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
