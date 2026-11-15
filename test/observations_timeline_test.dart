// CLAIM obs-timeline: a week can be explored without losing its latest summary
// or changing the detector's dated explanation.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/ui2/screens/findings_log.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'support/skeleton_fixture.dart';

void main() {
  testWidgets('Observations opens a graph and keeps a latest-week summary', (t) async {
    await t.pumpWidget(skHost(const FindingsLog([
      Finding(FindingKind.irregularRhythm, '2026-11-14'),
      Finding(FindingKind.rhrShift, '2026-11-05', risen: true),
    ])));
    await t.pump();
    expect(find.byType(ChartFrame), findsOneWidget);
    expect(find.byKey(const ValueKey('observations-latest-week')), findsOneWidget);
    expect(find.byTooltip('Earlier week'), findsOneWidget);
  });
}
