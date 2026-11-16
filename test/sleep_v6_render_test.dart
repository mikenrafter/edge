// Reviewed PNG artifacts accompany behavior tests; no golden is regenerated.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/day_timeline/pilot_flags.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/wake/wake_outcome.dart';
import 'package:openstrap_edge/wake/wake_timeline.dart';
import 'support/pilot_shots.dart';
import 'support/skeleton_fixture.dart';

Widget renderApp(AppState app, Widget child) => MultiProvider(providers: [
  ChangeNotifierProvider<AppState>.value(value: app),
  ChangeNotifierProvider<LocaleController>.value(value: LocaleController.seed(null)),
], child: skHost(Scaffold(body: child), brightness: Brightness.dark));

int epoch(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
final start = DateTime.utc(2026, 11, 13, 22, 21);
final end = DateTime.utc(2026, 11, 14, 7, 12);
SleepData fixture(String state) => SleepData(day: '2026-11-14',
  night: state == 'empty' ? const {} : {
    'duration_min': state == 'partial' ? 380 : 462,
    'in_bed_min': 531, 'efficiency': state == 'partial' ? .86 : .87,
    'onset_ts': epoch(start), 'wake_ts': epoch(end), 'sleep_source': 'auto',
    'hypnogram': [{'t': epoch(start), 'stage': 'light'},
      {'t': epoch(end), 'stage': 'awake'}],
  }, unobservedMin: state == 'partial' ? 90 : null,
  naps: state != 'nap' ? const [] : [
    {'start': epoch(end.add(const Duration(hours: 7))),
      'end': epoch(end.add(const Duration(hours: 7, minutes: 30))), 'duration_min': 30},
    {'start': epoch(end.add(const Duration(hours: 10))),
      'end': epoch(end.add(const Duration(hours: 10, minutes: 20))),
      'duration_min': 20, 'source': 'manual'},
  ], wakeTimeline: state == 'empty' ? const WakeNightTimeline() : WakeNightTimeline(events: [
    WakeNightEvent(kind: WakeNightEventKind.natural,
      at: end.subtract(const Duration(seconds: 48)), wakeEpochSec: 1, confirmedDelivery: true),
    WakeNightEvent(kind: WakeNightEventKind.ack, at: end, wakeEpochSec: 1,
      dream: WakeDreamResponse(answer: DreamAnswer.dream, path: WakePath.natural, at: end)),
  ]));

void main() {
  setUpAll(skLoadAppFonts);
  setUp(() => DayTimelinePilot.debugOverride[DayTimelinePilot.sleep] = true);
  tearDown(() => DayTimelinePilot.debugOverride.clear());
  for (final state in ['normal', 'partial', 'empty', 'nap']) {
    testWidgets('v6 dark Sleep top $state', (t) async {
      skTallView(t, w: 390, h: state == 'nap' ? 1380 : 1050);
      final app = AppState.forTesting(); addTearDown(app.dispose);
      await t.pumpWidget(pilotShot(renderApp(app,
        SleepDetail(embedded: true, data: fixture(state)))));
      await t.pumpAndSettle();
      expect(find.text('Edit sleep'), findsOneWidget);
      expect(find.text('Not sleep'), findsNothing);
      expect(find.text(state == 'empty' ? '—' : state == 'partial' ? '86%' : '87%'), findsWidgets);
      await takePilotShot(t, 'sleep-v6-$state');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
}
