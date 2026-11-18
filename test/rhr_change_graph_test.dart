// CLAIM rhr-marks: the dedicated graph and other charts project the same flags
// onto actual calendar days, while absent RHR remains absent.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/driver_breakdown.dart';
import 'package:openstrap_edge/ui2/screens/day_steps.dart';
import 'package:openstrap_edge/ui2/screens/beats.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'support/as_of_recalc_fakes.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/models/chart_point.dart';
import 'package:openstrap_edge/ui2/screens/findings_log.dart';
import 'package:openstrap_edge/ui2/screens/metric_annotations.dart';
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
  testWidgets('the same flag reaches driver, steps, strain and Trends graphs', (t) async {
    skTallView(t, w: 390, h: 4000);
    final app = AppState.forTesting(); addTearDown(app.dispose);
    final day = todayLabel(), stamp = localDayStartSec(todayLabel())!;
    final flag = Finding(FindingKind.rhrShift, day, risen: true);
    final marks = rhrChangeAnnotations([flag]);
    final points = [for (var i = 2; i >= 0; i--) ChartPoint(t: localDayStartSec(dayLabelBefore(day, i)!)!, v: 55.0-i)];
    final facts = driverFacts(breakdown: const [{'label':'rhr','used':true,'weight':1.0,'weighted_contribution':3.0,'past_mdc':true}],
      baselines: const {'resting_hr': {'value':55.0,'baseline':52.0,'spread':1.0}}, annotations: marks,
      charts: {'resting_hr': {'points': [for (final p in points) {'t':p.t,'v':p.v}]}});
    final screens = [
      Scaffold(body: DriverBreakdown(facts)),
      DayStepsDetail(data: DayStepsData(day: day, rhrMarks: marks, total: 500, strap: 500,
        spans: [DayStepSpan(startTs: stamp+3600, endTs: stamp+7200, steps: 500, fromBand: true)])),
      DayStrainDetail(data: DayStrainData(day: DateTime.fromMillisecondsSinceEpoch(stamp*1000), rhrMarks: marks, curve: List.filled(1440, 2.0))),
      Beats(data: BeatsData(day: day, rhrMarks: marks, dcPoints: points, rhythmPoints: points)),
      HealthScreen(tab: 2, data: HealthData(findings: [flag], charts: {for (final key in ['resting_hr','hrv','sleep']) key: points})),
    ];
    for (final screen in screens) {
      await t.pumpWidget(perfApp(app, screen)); await t.pump();
      final marked = t.widgetList<ChartFrame>(find.byType(ChartFrame)).where((f) => f.annotations?.items.any((a) => a.id == 'rhr-shift:$day') == true);
      if (screen is DayStepsDetail || screen is DayStrainDetail) {
        expect(
          marked,
          isEmpty,
          reason: 'daily flags cannot claim an intraday time',
        );
        expect(find.byKey(ValueKey('day-rhr-flag:$day')), findsOneWidget);
      } else {
        expect(marked, isNotEmpty, reason: screen.runtimeType.toString());
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    }
    await t.pumpWidget(perfApp(app, Scaffold(body: DriverBreakdown(facts))));
    final frame = t.widget<ChartFrame>(find.byType(ChartFrame));
    expect(frame.annotations!.items.single.at, 2, reason: 'trimmed three-day history must not use the 30-day index');
  });
  testWidgets(
    'Sleep across midnight and the timeline never plot a daily RHR flag as a time',
    (t) async {
      skTallView(t, w: 390, h: 6000);
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final day = todayLabel(), midnight = localDayStartSec(todayLabel())!;
      final marks = rhrChangeAnnotations([
        Finding(FindingKind.rhrShift, day, risen: true),
      ]);
      for (final screen in [
        SleepDetail(
          data: SleepData(
            day: day,
            rhrMarks: marks,
            night: {
              'duration_min': 480,
              'onset_ts': midnight - 3600,
              'wake_ts': midnight + 7 * 3600,
              'hypnogram': [
                {'t': midnight - 3600, 'stage': 'light'},
                {'t': midnight + 7 * 3600, 'stage': 'awake'},
              ],
            },
            timeline: {
              'hr': [
                {'t': midnight - 3600, 'v': 55},
                {'t': midnight + 7 * 3600, 'v': 56},
              ],
            },
          ),
        ),
        DayTimelineScreen(
          data: TimelineData(
            day: day,
            rhrMarks: marks,
            graph: DayGraph(hr: const [55, 56], dayStart: midnight),
          ),
        ),
      ]) {
        await t.pumpWidget(perfApp(app, screen));
        await t.pump();
        final flagsInPlot = t
            .widgetList<ChartFrame>(find.byType(ChartFrame))
            .expand((f) => f.annotations?.items ?? <ChartAnnotation>[])
            .where((a) => a.kind == AnnotationKind.rhrShift);
        expect(
          flagsInPlot,
          isEmpty,
          reason:
              '${screen.runtimeType}: a day-level finding has no midnight episode',
        );
        expect(find.byKey(ValueKey('day-rhr-flag:$day')), findsOneWidget);
        await t.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets('retained daily flags translate in the visible annotation lane', (t) async {
    final projected = dailyAnnotations(rhrChangeAnnotations(flags), ['2026-11-01','2026-11-02']);
    final l = lookupAppLocalizations(const Locale('fr'));
    await t.pumpWidget(skHost(Scaffold(body: ChartAnnotationLane(
      set: AnnotationSet(items: projected, domainStart: 0, domainEnd: 1), cursor: null, plotHeight: 130)), locale: const Locale('fr')));
    await t.tap(find.byKey(ChartAnnotationLane.iconKey('rhr-shift:2026-11-01'))); await t.pump();
    expect(find.textContaining(findingTitle(l, flags.first)), findsOneWidget);
    expect(projected.single.finding, flags.first);
  });

}
