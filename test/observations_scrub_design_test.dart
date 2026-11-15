// CLAIM observations-scrub: use the same drag, cursor and detail grammar as
// other charts. Events stay inside the chart's readout, with canonical dates.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/ui2/screens/findings_log.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/ui2/why_row.dart';
import 'support/skeleton_fixture.dart';
void main() {
  testWidgets('standard day scrub shows a cursor and inline dated event rows', (t) async {
    skTallView(t,w:390,h:1200);
    await t.pumpWidget(skHost(const FindingsLog([
      Finding(FindingKind.irregularRhythm,'2026-11-14'),
      Finding(FindingKind.lowReadiness,'2026-11-14',score:22),
    ],today:'2026-11-15')));
    expect(find.byType(ChartScrub),findsOneWidget);
    expect(find.descendant(of:find.byType(ChartFrame),matching:find.byType(WhyRow)),findsNWidgets(2));
    expect(find.byWidgetPredicate((w)=>w is TextButton && w.key==const ValueKey('observation-day:2026-11-14')),findsNothing);
    final plot=t.getRect(find.byType(ChartScrub));
    await t.dragFrom(Offset(plot.left+plot.width*.5,plot.center.dy),Offset(plot.width*.47,0));await t.pump();
    expect(find.byKey(ChartScrub.cursorKey),findsOneWidget);
    expect(t.widget<ChartKeyReadout>(find.byType(ChartKeyReadout)).time,contains('15 November'));
    expect(find.text('Nothing flagged on this day.'),findsOneWidget);
    expect(find.byType(WhyRow),findsNothing);
  });
}
