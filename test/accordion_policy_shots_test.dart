// One visual check per custom disclosure family. Existing shot helper only;
// no golden, pixel or frame harness.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/cycle_screen.dart';
import 'package:openstrap_edge/ui2/screens/circadian_detail.dart';
import 'package:openstrap_edge/ui2/screens/driver_breakdown.dart';
import 'package:openstrap_edge/ui2/screens/log_food.dart';
import 'package:openstrap_edge/ui2/screens/ecg.dart';
import 'package:openstrap_edge/ui2/screens/track_editor.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'backup/backup_support.dart';
import 'ecg_transparency/support/cardio_fixtures.dart';
import 'support/as_of_recalc_fakes.dart';
import 'support/live_guide_harness.dart';
import 'support/guide_text.dart';
import 'support/pilot_shots.dart';
import 'support/skeleton_fixture.dart';
import 'tracks/ui_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(skLoadAppFonts);
  testWidgets('custom disclosures fit their expanded contents in dark theme', (t) async {
    final env = (await t.runAsync(() => BackupEnv.create('accordion_shots.db')))!;
    SharedPreferences.setMockInitialValues({}); await Prefs.ensureLoaded();
    final db = (await t.runAsync(() => LocalDb.instance))!;
    final store = ObservedTracksStore(db);
    final app = AppState.forTesting()..repo = GuideFakeRepo();
    skTallView(t, w: 390, h: 1200);
    Future<void> show(String name, Widget screen, {String? focus}) async {
      await t.pumpWidget(pilotShot(perfApp(app, screen, brightness: Brightness.dark)));
      for (var i = 0; i < 12; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump(const Duration(milliseconds: 50));
      }
      if (focus != null) {
        await Scrollable.ensureVisible(t.element(find.byKey(ValueKey(focus))), alignment: 0);
        await t.pump();
      }
      await takePilotShot(t, name);
      expect(t.takeException(), isNull, reason: name);
      await t.pumpWidget(const SizedBox());
    }
    try {
      await show('accordion-cycle', CycleTab(data: CycleData(enabled: true, reproState: 'cycling', phase: 'follicular',
        cycleDay: 8, overlay: [for (var i = 0; i < 14; i++) {'date': '2026-11-${(i+1).toString().padLeft(2,'0')}', 'cycle_day': i+1, 'resting_hr': 54+i%3, 'hrv_rmssd': 55-i%4}])));
      await show('accordion-body-clock', const CircadianDetail(data: CircadianData(chronotypeLabel: 'Intermediate', sriPairs: [
        {'prev_date': '2026-11-12', 'date': '2026-11-13', 'sri': 74.0, 'cases': 12}])));
      await show('accordion-food', const LogFoodSheet(date: '2026-11-13'));
      await show('accordion-ecg', EcgDetailScreen(data: EcgDetailData(reading: cardioReading(), packets: [cardioPacket(0)])), focus: 'ecg-details');
      await show('accordion-drivers', Scaffold(body: SingleChildScrollView(child: DriverBreakdown(driverFacts(
        breakdown: const [{'label':'rhr','used':true,'weight':1.0,'weighted_contribution':3.0,'past_mdc':true}],
        baselines: const {'resting_hr': {'value':52.0,'baseline':56.0,'spread':2.0}},
        charts: {'resting_hr': {'points': [for (var i=0;i<30;i++) {'t':DateTime(2026,11,i+1).millisecondsSinceEpoch~/1000,'v':52.0+i%4}]}})))));
      await show('accordion-track-editor', TrackEditor(store: store, initial: const TrackDefinition(id:'walk',name:'Evening walk',icon:'track',kind:'activity')));
      await show('accordion-guide-help', skHost(Scaffold(body: Align(alignment: Alignment.bottomCenter, child: GuideStepCard(
        model: GuideCardOnStep(number: 2, total: 3, caption: 'Tap **Open details**.',
          missingHelp: GuideFooter(kind: GuideFooterKind.missingTarget, title: fnText((_) => "Don't see it?"), body: fnText((_) => 'Open the menu, then Details.'))),
        onExit: () {}))), brightness: Brightness.dark));
    } finally {
      await t.pumpWidget(const SizedBox()); app.dispose(); await t.runAsync(env.dispose);
    }
  });
}
