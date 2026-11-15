// Manual dark-theme review artifacts, using the existing pilot shot helper.
// No pixel comparison or frame scoring; only render the requested states.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/screens/sleep_tab.dart';
import 'package:openstrap_edge/ui2/screens/track_editor.dart';
import 'package:openstrap_edge/ui2/screens/track_log.dart';
import 'package:openstrap_edge/ui2/screens/track_experiment.dart';
import 'package:openstrap_edge/ui2/screens/tracks_screen.dart';
import 'package:openstrap_edge/ui2/pairing/device_picker.dart';
import 'package:openstrap_edge/ui2/profile/data.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/import_progress_view.dart';
import 'backup/backup_support.dart';
import 'support/as_of_recalc_fakes.dart';
import 'support/live_guide_harness.dart';
import 'support/fake_alarm_engine.dart';
import 'support/pilot_shots.dart';
import 'support/skeleton_fixture.dart' show skLoadAppFonts;

class _HeldRepo extends GuideFakeRepo {
  @override
  Future<Map<String, dynamic>> getToday() => Completer<Map<String, dynamic>>().future;
  @override
  Future<SleepDetailBundle> getSleepDetailBundle(String day, {
    required List<String> chartKeys, required int windowDays, String? before}) =>
      Completer<SleepDetailBundle>().future;
}
class _FullRepo extends GuideFakeRepo {
  _FullRepo(this.night);
  final Map<String, dynamic> night;
  @override
  Future<List<String>> availableDays() async => [todayLabel(), dayLabelBefore(todayLabel(), 1)!];
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String day) async => night;
  @override
  Future<SleepDetailBundle> getSleepDetailBundle(String day, {
    required List<String> chartKeys, required int windowDays, String? before}) async =>
      SleepDetailBundle(night: night, timeline: const {}, insights: const {},
        charts: const {}, windows: const []);
  @override
  Future<DateTime?> dayRecordingsThrough(String day) async {
    final date = DateTime.parse(day);
    return DateTime(date.year, date.month, date.day, 21, 22);
  }
}
class _HeldTracks extends TracksStore {
  _HeldTracks(super.db);
  @override
  Future<Map<String, Map<String, Object?>>> refreshLearning({DateTime? asOf}) => Completer<Map<String, Map<String, Object?>>>().future;
  @override
  Future<List<TrackDefinition>> definitions({bool enabledOnly = false}) => Completer<List<TrackDefinition>>().future;
  @override
  Future<List<TrackSetupRange>> history(String id) => Completer<List<TrackSetupRange>>().future;
  @override
  Future<List<Map<String, Object?>>> experiments({String? trackId}) => Completer<List<Map<String, Object?>>>().future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async { await skLoadAppFonts(); env = await BackupEnv.create('structural_shots.db'); await LocalDb.instance; await Prefs.ensureLoaded(); });
  tearDownAll(() => env.dispose());
  testWidgets('structural screen review shots', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final db = await LocalDb.instance;
    final store = _HeldTracks(db);
    const track = TrackDefinition(id: 'walk', name: 'Evening walk', icon: 'track', kind: 'activity');
    final query = TextEditingController();
    addTearDown(query.dispose);
    final onset = DateTime(2026, 11, 12, 23).millisecondsSinceEpoch ~/ 1000;
    final night = SleepData(day: '2026-11-13', days: const ['2026-11-13'], night: {
      'duration_min': 443, 'in_bed_min': 486, 'efficiency': .91,
      'onset_ts': onset, 'wake_ts': onset + 486 * 60,
      'light_min': 170, 'deep_min': 85, 'rem_min': 95,
      'hypnogram': [for (var i = 0; i < 8; i++) {'t': onset + i * 3600, 'stage': ['light', 'deep', 'rem', 'awake'][i % 4]}],
    });
    final n = DateTime.now();
    final health = HealthData(charts: {for (final key in ['resting_hr', 'hrv', 'sleep']) key:
      [for (var i = 0; i < 30; i++) ChartPoint(t: DateTime(n.year, n.month, n.day - 29 + i).millisecondsSinceEpoch ~/ 1000,
        v: (key == 'sleep' ? 400 : key == 'hrv' ? 70 : 52) + (i % 5).toDouble())]});
    final app = AppState.forTesting(engine: FakeAlarmEngine())..repo = _HeldRepo();
    addTearDown(app.dispose);
    Future<void> show(String name, Widget screen, {String? reveal, String? focus, Future<void> Function()? navigate}) async {
      await t.pumpWidget(pilotShot(perfApp(app, screen, brightness: Brightness.dark)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 250));
      await t.pump(const Duration(milliseconds: 500));
      if (navigate != null) { await navigate(); await t.pump(); }
      if (reveal != null) {
        final accordion = find.byWidgetPredicate((w) => w is SettingsAccordion && w.title == reveal);
        await t.scrollUntilVisible(accordion, 250, scrollable: find.byType(Scrollable).first);
        final header = find.descendant(of: accordion, matching: find.text(reveal)).first;
        await Scrollable.ensureVisible(t.element(header), alignment: 0);
        await t.pump();
        // Open when folded. Before and after show the same section.
        if (find.descendant(of: accordion, matching: find.byType(Divider)).evaluate().isEmpty) {
          await t.tap(header); await t.pump();
        }
        await Scrollable.ensureVisible(t.element(header), alignment: 0);
        await t.pump();
      }
      if (focus != null) {
        await Scrollable.ensureVisible(t.element(find.text(focus).first), alignment: .2);
        await t.pump();
      }
      await takePilotShot(t, name);
      expect(t.takeException(), isNull, reason: name);
      await t.pumpWidget(const SizedBox());
    }
    await show('S2-review-activities', DayTimelineScreen(reviewEntry: true,
      data: TimelineData(day: '2026-11-13', days: const ['2026-11-13'],
        graph: DayGraph(dayStart: onset - 23 * 3600,
          hr: [for(var i = 0; i < 1440; i++) 60 + (i % 60) / 3],
          movement: [for(var i = 0; i < 1440; i++) (i % 15) / 20]))));
    await show('S5-observations-unchanged', const FindingsLog([
      Finding(FindingKind.irregularRhythm, '2026-11-11'),
      Finding(FindingKind.rhrShift, '2026-11-09', risen: false),
      Finding(FindingKind.lowReadiness, '2026-11-08', score: 22),
    ]));
    await show('S1-sleep-night', SleepDetail(data: night), reveal: 'Through the night');
    await show('S1-night-actions', SleepDetail(data: night), reveal: 'Through the night', focus: 'Recalculate this night');
    app.repo = _FullRepo(night.night);
    await show('S3-sleep-tab', const SleepTab(), reveal: 'The Plan');
    await show('S3-sleep-footer', const SleepTab(), focus: 'Naps');
    await show('home-past-day', const HomeScreen(hour: 9), navigate: () async {
      await settle(t, n: 8);
      await t.tap(find.bySemanticsLabel('Previous day'));
      await settle(t, n: 8);
    });
    app.repo = _HeldRepo();
    await show('sleep-pending', const SleepDetail());
    await show('home-pending', const HomeScreen(hour: 9));
    await show('home-loaded', HomeScreen(hour: 9, data: HomeData(dayId: todayLabel(),
      readiness: const Metric(value: 72, confidence: .9),
      sleepMin: const Metric(value: 443, confidence: .9), strain: const Metric(value: 9.4, confidence: .9))));
    await show('S4-health-overview-pending', const HealthScreen());
    await show('S6-health-trends', HealthScreen(data: health, tab: 2));
    await show('tracks-pending', TracksScreen(store: store));
    await show('track-detail-pending', TrackDetailScreen(store: store, track: track));
    await show('track-editor-pending', TrackEditor(store: store, initial: track));
    await show('track-log-pending', TrackLogScreen(store: store));
    await show('track-experiment-pending', ExperimentScreen(store: store, track: track, experimentId: 'one'));
    await show('pairing-scanning', DevicePickerView(query: query, title: 'Add a device', subtitle: 'Choose your device', scanning: true));
    await show('import-preparing', const Scaffold(body: ImportProgressView(ImportPreparing(null))));
    await show('settings-import-busy', const DataScreenView(busy: true, busyStatus: 'Reading the import'));
    await show('S7-alarm-trace', const AlarmScreen(), reveal: 'Timeline and status', focus: 'Last wake decision');
  });
}
