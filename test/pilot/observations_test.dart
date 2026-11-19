// why: the chosen pilot removes the repeated weekly summary and duplicate
// detector/day rows. The flag must keep the original presentation available.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_summary.dart';
import 'package:openstrap_edge/ui2/observation_history.dart';
import 'package:openstrap_edge/ui2/screens/pulse_episode.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/findings_log.dart';
import '../support/skeleton_fixture.dart';
import 'package:openstrap_edge/ui2/why_row.dart';
import 'package:shared_preferences/shared_preferences.dart';
const episode = PulseEpisodeSummary(id:'episode-a', startMs:1795000000000,
  endMs:1795000600000, day:'2026-11-17', endDay:'2026-11-18', evidenceStatus:'expired');
void main() {
  // catches: removing unrelated detector flags, retaining covered daily pulse
  // flags, or listing the same episode once per calendar day.
  test('episodes replace only covered daily pulse flags and sort with newer findings', () {
    final history=observationHistory(const [
      Finding(FindingKind.irregularRhythm,'2026-11-17'),
      Finding(FindingKind.irregularRhythm,'2026-11-18'),
      Finding(FindingKind.irregularRhythm,'2026-11-16'),
      Finding(FindingKind.lowReadiness,'2026-11-18',score:22),
    ],const [episode,episode]);
    expect(history.map((e)=>e.day),['2026-11-18','2026-11-17','2026-11-16']);
    expect(history.whereType<PulseObservation>(),hasLength(1));
    expect(history.where((e)=>e.occursOn('2026-11-18')),hasLength(2));
  });
  testWidgets('covered pulse day has one episode row and no duplicate daily row', (t) async {
    SharedPreferences.setMockInitialValues({});await Prefs.reload();
    await PilotFlags.set(PilotFlag.observations,true);skTallView(t);
    await t.pumpWidget(skHost(const FindingsLog([
      Finding(FindingKind.irregularRhythm,'2026-11-18')],
      today:'2026-11-18',episodes:[episode])));
    await t.pump();
    expect(find.byType(PulseEpisodeRow),findsOneWidget);
    expect(find.byKey(const ValueKey('home-why:finding:irregularRhythm:2026-11-18')),findsNothing);
    expect(t.takeException(),isNull);
  });
  // catches: counting duplicate stored flags or restoring the weekly summary.
  testWidgets('simplified observations show each detector once on the selected day', (t) async {
    SharedPreferences.setMockInitialValues({}); await Prefs.reload();
    final findings = [Finding(FindingKind.irregularRhythm, '2026-11-18'),
      Finding(FindingKind.irregularRhythm, '2026-11-18')];
    expect(uniqueObservations(findings), hasLength(1));
    await PilotFlags.set(PilotFlag.observations, true);
    skTallView(t);
    await t.pumpWidget(skHost(FindingsLog(findings, today: '2026-11-18')));
    await t.pump();
    expect(find.byKey(const ValueKey('observations-latest-week')), findsNothing);
    expect(find.byType(WhyRow), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
