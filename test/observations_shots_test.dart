// Dark visual checks for the approved timeline, RHR curve and shared marker lane.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/models/chart_point.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/findings_log.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'support/as_of_recalc_fakes.dart';
import 'support/pilot_shots.dart';
import 'support/skeleton_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(skLoadAppFonts);
  testWidgets('Observations, RHR changes and annotated Trends design', (
    t,
  ) async {
    skTallView(t, w: 390, h: 1000);
    const findings = [
      Finding(FindingKind.irregularRhythm, '2026-11-14'),
      Finding(FindingKind.lowReadiness, '2026-11-14', score: 22),
      Finding(FindingKind.illness, '2026-11-12'),
      Finding(FindingKind.rhrShift, '2026-11-09', risen: false),
      Finding(FindingKind.tempElevated, '2026-11-05'),
      Finding(FindingKind.rhrShift, '2026-11-03', risen: true),
    ];
    final points = [
      for (var i = 1; i <= 15; i++)
        ChartPoint(
          t: localDayStartSec('2026-11-${i.toString().padLeft(2, '0')}')!,
          v: 54.0 + (i % 4) - (i > 8 ? 5 : 0),
        ),
    ];
    Future<void> show(String name, Widget screen) async {
      await t.pumpWidget(
        pilotShot(skHost(screen, brightness: Brightness.dark)),
      );
      await t.pump(const Duration(milliseconds: 500));
      await takePilotShot(t, name);
      expect(t.takeException(), isNull);
    }

    await show(
      'observations-latest-week',
      FindingsLog(findings, rhr: points, today: '2026-11-15'),
    );
    var plot = t.getRect(find.byType(ChartScrub));
    await t.dragFrom(
      Offset(plot.left + plot.width * .2, plot.center.dy),
      Offset(plot.width * ((5.5 / 7) - .2), 0),
    );
    await t.pump();
    await takePilotShot(t, 'observations-latest-week');
    await t.tap(find.byTooltip('Earlier week'));
    await t.pump();
    plot = t.getRect(find.byType(ChartScrub));
    await t.dragFrom(
      Offset(plot.left + plot.width * .1, plot.center.dy),
      Offset(plot.width * .4, 0),
    );
    await t.pump();
    await takePilotShot(t, 'observations-earlier-week');
    await show(
      'resting-heart-rate-changes',
      RhrChangesScreen(findings: findings, points: points),
    );
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await t.pumpWidget(
      pilotShot(
        perfApp(
          app,
          HealthScreen(
            tab: 2,
            data: HealthData(
              findings: findings,
              charts: {
                for (final key in ['resting_hr', 'hrv', 'sleep']) key: points,
              },
            ),
          ),
          brightness: Brightness.dark,
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 500));
    await takePilotShot(t, 'health-trends-with-rhr-flags');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
