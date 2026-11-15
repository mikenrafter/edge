// CLAIM rhr-marks: the dedicated graph and other charts project the same flags
// onto actual calendar days, while absent RHR remains absent.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/models/chart_point.dart';
import 'package:openstrap_edge/ui2/screens/findings_log.dart';
import 'package:openstrap_edge/ui2/screens/explorer_annotations.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'support/skeleton_fixture.dart';

const flags = [Finding(FindingKind.rhrShift, '2026-11-01', risen: false), Finding(FindingKind.lowReadiness, '2026-11-02', score: 20)];
void main() {
  test('shared annotation source dates and filters RHR flags without an episode time', () {
    final timed = rangeAnnotations(from: '2026-10-31', to: '2026-11-02', findings: flags);
    expect(timed, hasLength(1));
    expect(timed.single.at, localDayStartSec('2026-11-01'));
    expect(timed.single.until, isNull);
    expect(timed.single.kind, AnnotationKind.rhrShift);
    final daily = dailyAnnotations(timed, ['2026-10-31', '2026-11-01', '2026-11-02']);
    expect(daily.single.at, 1);
    expect(daily.single.id, timed.single.id);
    expect(rangeAnnotations(from: '2026-11-02', to: '2026-11-03', findings: flags), isEmpty);
  });
  testWidgets('RHR curve has gaps and every flagged change uses the shared annotation lane', (t) async {
    skTallView(t);
    await t.pumpWidget(skHost(RhrChangesScreen(findings: flags, points: [
      ChartPoint(t: localDayStartSec('2026-10-31')!, v: 57),
      ChartPoint(t: localDayStartSec('2026-11-02')!, v: 51),
    ])));
    final frame = t.widget<ChartFrame>(find.byType(ChartFrame));
    expect(frame.series, [57, null, 51]);
    expect(frame.annotations!.items.single.at, 1);
    expect(find.byKey(ChartAnnotationLane.iconKey('rhr-shift:2026-11-01')), findsOneWidget);
    expect(find.byType(ChartKeyReadout), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('a flag with no RHR reading never fabricates a curve', (t) async {
    await t.pumpWidget(skHost(const RhrChangesScreen(findings: flags, points: [])));
    final frame = t.widget<ChartFrame>(find.byType(ChartFrame));
    expect(frame.series.every((v) => v == null), isTrue);
    expect(frame.annotations!.items, hasLength(1));
    expect(find.text('No resting heart rate readings stored.'), findsOneWidget);
  });
}
