// WHY: review the real dark card at phone width for the owner's night shapes.
// Assertions own behavior; exported PNGs are inspected before handoff.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/day_timeline/pilot_flags.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/wake/wake_outcome.dart';
import 'package:openstrap_edge/wake/wake_timeline.dart';
import 'sleep_v6_render_test.dart' show renderApp;
import 'support/pilot_shots.dart';
import 'support/skeleton_fixture.dart';

int sec(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
WakeNightEvent sent(DateTime at, WakeNightEventKind kind) =>
  WakeNightEvent(kind: kind, at: at, wakeEpochSec: 1, confirmedDelivery: true);

void main() {
  setUpAll(skLoadAppFonts);
  setUp(() { DayTimelinePilot.debugOverride[DayTimelinePilot.sleep] = true; ClockFormatController.seed(ClockFormat.h24); });
  tearDown(() { DayTimelinePilot.debugOverride.clear(); ClockFormatController.debugReset(); });
  for (final shape in ['midnight', 'one-day', 'many-alerts', 'overlap']) {
    testWidgets('R2 dark owner night $shape', (t) async {
      skTallView(t, w: 390, h: 1240);
      final start = shape == 'midnight' ? DateTime(2026, 11, 14, 22, 39, 55) : DateTime(2026, 11, 14, 6, 39, 55);
      final end = shape == 'midnight' ? DateTime(2026, 11, 15, 8, 15, 55) : DateTime(2026, 11, 14, 16, 15, 55);
      final ackAt = (shape == 'many-alerts' || shape == 'overlap') ? DateTime(2026, 11, 14, 14, 22, 45) : end;
      final alerts = shape == 'overlap' ? [
        sent(DateTime(2026, 11, 14, 14, 15), WakeNightEventKind.gradual),
        sent(DateTime(2026, 11, 14, 14, 18), WakeNightEventKind.gradual),
        sent(DateTime(2026, 11, 14, 14, 20), WakeNightEventKind.natural),
        sent(DateTime(2026, 11, 14, 14, 21), WakeNightEventKind.gradual),
        sent(DateTime(2026, 11, 14, 14, 22), WakeNightEventKind.repeat),
      ] : shape == 'many-alerts' ? [
        sent(DateTime(2026, 11, 14, 14, 15, 35), WakeNightEventKind.gradual),
        sent(DateTime(2026, 11, 14, 14, 18, 6), WakeNightEventKind.gradual),
        sent(DateTime(2026, 11, 14, 14, 21, 5), WakeNightEventKind.gradual),
        for (final second in [38, 43, 47, 52, 57, 61, 66, 70])
          sent(DateTime(2026, 11, 14, 14, 21, second), WakeNightEventKind.repeat),
      ] : [sent(end.subtract(const Duration(seconds: 48)), WakeNightEventKind.natural)];
      final app = AppState.forTesting(); addTearDown(app.dispose);
      await t.pumpWidget(pilotShot(renderApp(app, SleepDetail(embedded: true, data: SleepData(
        day: shape == 'midnight' ? '2026-11-15' : '2026-11-14', night: {
          'duration_min': 572, 'in_bed_min': 576, 'efficiency': 1.0,
          'onset_ts': sec(start), 'wake_ts': sec(end), 'sleep_source': 'auto',
          'recordings_through': end.millisecondsSinceEpoch,
          // Must never be substituted for the included recording timestamp.
          'computed_at': DateTime(2026, 11, 16, 5, 5).millisecondsSinceEpoch,
        }, unobservedMin: 2, wakeTimeline: WakeNightTimeline(deliveries: alerts, events: [
          WakeNightEvent(kind: WakeNightEventKind.ack, at: ackAt, wakeEpochSec: 1,
            dream: WakeDreamResponse(answer: DreamAnswer.normal, path: WakePath.natural, at: ackAt)),
        ]))))));
      await t.pumpAndSettle();
      expect(find.text('Edit sleep'), findsOneWidget);
      expect(find.textContaining('recordings through'), findsNothing);
      expect(find.text('SUN 15'), shape == 'midnight' ? findsOneWidget : findsNothing);
      if (shape == 'many-alerts') expect(find.text('14:21–14:22 · 8 alerts'), findsOneWidget);
      await takePilotShot(t, 'sleep-r2-$shape');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
}
