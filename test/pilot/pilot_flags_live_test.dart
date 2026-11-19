// why: Labs toggles must update kept-alive screens without restarting the app.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_summary.dart';
import 'package:openstrap_edge/ui2/screens/findings_log.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/skeleton_fixture.dart';
void main() {
  setUp(() async {SharedPreferences.setMockInitialValues({});await Prefs.reload();});
  // catches: reading the flag once at mount or requiring a route remount.
  testWidgets('Labs sleep summary switches the existing screen on and off', (t) async {
    skTallView(t);
    await t.pumpWidget(skHost(const Scaffold(body:SleepDetail(embedded:true,
      data:SleepData(day:'2026-11-18',night:{'duration_min':400,'in_bed_min':450})))));
    await t.pump();expect(find.byType(SleepSummary),findsNothing);
    await PilotFlags.set(PilotFlag.sleepSummary,true);await t.pump();
    expect(find.byType(SleepSummary),findsOneWidget);
    await PilotFlags.set(PilotFlag.sleepSummary,false);await t.pump();
    expect(find.byType(SleepSummary),findsNothing);
    expect(t.takeException(),isNull);
  });
  testWidgets('Labs observations switches an already open log', (t) async {
    skTallView(t);
    await t.pumpWidget(skHost(const FindingsLog([
      Finding(FindingKind.irregularRhythm,'2026-11-18')],today:'2026-11-18')));
    await t.pump();expect(find.byKey(const ValueKey('observations-latest-week')),findsOneWidget);
    await PilotFlags.set(PilotFlag.observations,true);await t.pump();
    expect(find.byKey(const ValueKey('observations-latest-week')),findsNothing);
    await PilotFlags.set(PilotFlag.observations,false);await t.pump();
    expect(find.byKey(const ValueKey('observations-latest-week')),findsOneWidget);
    expect(t.takeException(),isNull);
  });
}
