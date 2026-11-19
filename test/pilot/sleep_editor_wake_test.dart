// why: the phone crashed opening an observed night because enum extensions
// were invoked dynamically. Exercise the route's repository load, not read=.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/pilot/sleep_editor.dart';
import 'package:openstrap_edge/pilot/timeline_chart.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:openstrap_edge/wake/wake_timeline.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NightRepository extends LocalRepository {
  @override
  Future<SleepEditorRead> readSleepEditor(String day) async => SleepEditorRead(
    dayId: day, entries: const [], revision: null, draftGeneration: 0);
  @override
  Future<Map<String, dynamic>> getDayTimeline(String day) async => {};
  @override
  Future<SleepPrimaryRead?> getSleepDetailPrimary(String day) async => SleepPrimaryRead(
    bundle: const SleepDetailBundle(night: {}, timeline: {}, insights: {}, charts: {}, windows: []),
    wake: WakeNightTimeline(events: [
      for (final kind in [WakeNightEventKind.natural, WakeNightEventKind.gradual,
          WakeNightEventKind.alarm, WakeNightEventKind.ack])
        WakeNightEvent(kind: kind, at: DateTime(2026, 11, 18, 7, kind.index)),
    ]));
}
class NightApp extends AppState {
  NightApp() : super.forTesting();
  @override
  final LocalRepository repo = NightRepository();
}
void main() {
  // catches: restoring dynamic enum.name or displaying raw enum labels.
  testWidgets('pilot sleep editor loads natural gradual alarm and ack annotations', (t) async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.reload();
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final app = NightApp();
    await t.pumpWidget(ChangeNotifierProvider<AppState>.value(value: app,
      child: MaterialApp(theme: buildTheme(Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const PilotSleepEditor(day: '2026-11-18'))));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.byType(PilotTimelineChart), findsOneWidget);
    final chart = t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart));
    expect(chart.annotations.map((e) => e.label).toList(),
      ['Natural wake', 'Gradual wake', 'Alarm', "I'm up"]);
    expect(chart.annotations.map((e) => e.id.split(':')[1]).toList(),
      ['natural', 'gradual', 'alarm', 'ack']);
    await t.pumpWidget(const SizedBox());
    app.dispose();
  });
}
