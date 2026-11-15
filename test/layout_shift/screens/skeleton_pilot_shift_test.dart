// WHY: cold reads used to replace whole pages with spinners or empty bodies.
// Catches: restoring an InlineLoading branch, omitting pending page sections,
// or publishing late content that moves controls already on screen.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import '../../backup/backup_support.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/activity/zones.dart';
import 'package:openstrap_edge/ui2/screens/day_review.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/screens/sleep_tab.dart';
import 'package:openstrap_edge/ui2/screens/readiness_detail.dart';
import 'package:openstrap_edge/ui2/screens/day_steps.dart';
import 'package:openstrap_edge/ui2/screens/naps.dart';
import 'package:openstrap_edge/ui2/screens/beats.dart';
import 'package:openstrap_edge/ui2/screens/circadian_detail.dart';
import 'package:openstrap_edge/ui2/screens/investigate.dart';
import 'package:openstrap_edge/ui2/screens/what_changed.dart';
import 'package:openstrap_edge/ui2/screens/typical_day.dart';
import 'package:openstrap_edge/ui2/screens/wellness_screen.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart' show DeviceFilter;
import '../../support/as_of_recalc_fakes.dart';
import '../../support/live_guide_harness.dart';
import '../../support/shift_run.dart';
import '../../support/skeleton_fixture.dart' show skLoadAppFonts;

class _LateRepo extends GuideFakeRepo {
  _LateRepo({this.rich = false});
  final bool rich;
  final gate = Completer<void>();
  int reads = 0;
  Future<T> late<T>(Future<T> Function() read) async {
    reads++;
    await gate.future;
    return read();
  }
  @override
  Future<Map<String, dynamic>> getToday() => late(super.getToday);
  @override
  Future<List<String>> availableDays() => late(super.availableDays);
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String day) =>
      late(() => rich ? SleepRepo().getDaySleepV2(day) : super.getDaySleepV2(day));
  @override
  Future<Map<String, dynamic>> getDayTimeline(String day) =>
      late(() async => rich ? {for (final key in ['hr', 'hrv', 'resp', 'skin_temp']) key: [
      for (var i = 0; i < 98; i++) {'t': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 36000 + i * 300,
        'v': (key == 'hr' ? 55 : key == 'hrv' ? 45 : key == 'resp' ? 14 : 33) + i % 3 * .1},
    ]} : await super.getDayTimeline(day));
  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) => late(() async {
    if (rich) { return {'points': [for (var i = 28; i >= 0; i--) {
      't': DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day - i, 12).millisecondsSinceEpoch ~/ 1000,
      'v': metric == 'sleep' ? 440 + i % 5 : metric == 'deep' ? 80 + i % 5 : metric == 'efficiency' ? 90 + i % 5 : metric == 'unobserved_min' ? 60 : 5,
    }]}; }
    final chart = await MetricRepo().getChart(metric, from: from, to: to, signals: signals);
    return (metric == 'resting_hr' || metric == 'steps') ? chart : const {'points': []};
  });
  @override
  Future<List<Map<String, Object?>>> getDeviceNights(String day) async => rich
    ? [{'device_id': 'watch', 'label': 'Watch', 'family': 'colmi'}] : [];
  @override
  Future<Map<String, dynamic>> getInsights() async => rich ? {
    'sleep_coach': {'need': {'status': 'ok', 'value': {'need_sec': 28800}},
      'bedtime': {'status': 'ok', 'value': {'bedtime_min_of_day': 1320}}},
    'sleep_debt': {'status': 'ok', 'value': {'debt_hours': 1}},
  } : {};
  @override
  Future<Map<String, dynamic>> getZones() => late(super.getZones);
  @override
  Future<Map<String, dynamic>> getDayStrain(String day) => late(() => super.getDayStrain(day));
  @override
  Future<List<ActivitySuggestion>> pendingActivities() => late(super.pendingActivities);
  @override
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) =>
    late(() async => const {'insights': []});
  @override
  Future<Map<String, dynamic>> getWeekdayEffect({String key = 'readiness'}) =>
    late(() async => const {});
  @override
  Future<String?> artifactSignature(String key) => late(() async => null);
  @override
  Future<Map<String, dynamic>> getDayHrv(String day) => late(() async => const {});
  @override
  Future<Map<String, dynamic>> getDaySteps(String day) => late(() async => const {});
  @override
  Future<Map<String, dynamic>> getDayNaps(String day) => late(() async => {'naps': [for (var i = 0; i < 2; i++) {
      'start': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 7200 + i * 3600,
      'end': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 4500 + i * 3600,
      'duration_min': 45, 'source': 'auto',
    }], 'nap_min': 90});
  @override
  Future<({List<double> nn, int rawBeats, double cleanFraction})> getNightBeats(String day) =>
    late(() async => (nn: [for (var i = 0; i < 400; i++) 880 + (i % 37) * 3.0],
      rawBeats: 412, cleanFraction: .97));

}

class _SourcesApp extends AppState {
  _SourcesApp() : super.forTesting();
  @override
  List<Map<String, Object?>> get sensors => [
    for (var i = 0; i < 2; i++) {'id': 'band-$i', 'label': 'Band $i',
      'adapter_id': 'gen4', 'tier': 'wristOptical'},
  ];
}

const _sleepSections = ['card:answer', 'section:night', 'card:stages', 'card:versus',
  'card:unusual', 'card:overnight', 'card:tonight'];
final _captureKey = GlobalKey();

Future<void> shot(WidgetTester t, String name) async {
  final dir = Platform.environment['CLS_SHOTS_DIR'];
  if (dir == null) return;
  final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(dir).create(recursive: true);
    await File('$dir/${name.replaceAll(':', '-')}.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async {
    await skLoadAppFonts();
    env = await BackupEnv.create('skeleton_pilot.db');
    await LocalDb.instance;
  });
  tearDownAll(() => env.dispose());
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final screens = <String, Widget Function()>{
    'sleep-detail': () => const SleepDetail(),
    'sleep-tab': () => const SleepTab(),
    'metric-resting-hr': () => const MetricDetail('resting_hr'),
    'metric-steps': () => const MetricDetail('steps'),
    'metric-sources': () => const MetricDetail('resting_hr'),
    'day-strain': () => const DayStrainDetail(),
    'heart-rate-zones': () => const ZonesDetail(),
    'day-review': () => const DayReviewEntry(moments: []),
    'day-timeline': () => const DayTimelineScreen(),
    'recovery': () => const ReadinessDetail(),
    'day-steps': () => const DayStepsDetail(),
    'naps': () => const NapsScreen(),
    'beats': () => const Beats(),
    'body-clock': () => const CircadianDetail(),
    'nerd-stats': () => const Investigate('resting_hr'),
    'what-changed': () => const WhatChangedScreen(),
    'typical-day': () => const TypicalDayScreen(),
    'journal-findings': () => const JournalFindings(),
    for (final section in _sleepSections) 'rich-sleep-$section': () => const SleepDetail(),
  };
  for (final entry in screens.entries) {
    // The old loading page has no lower sections to scroll to. Its first
    // viewport is captured once for each route; rich cases measure the fix.
    if (Platform.environment['CLS_BASELINE'] == '1' && entry.key.startsWith('rich-')) { continue; }
    for (final delay in entry.key.startsWith('rich-') ? [2500] : [150, 2500]) {
      testWidgets('${entry.key}: ${delay}ms pending has no spinner and stays still', (t) async {
        phoneSurface(t);
        final rich = entry.key.startsWith('rich-');
        final repo = _LateRepo(rich: rich);
        final app = (entry.key == 'metric-sources' ? _SourcesApp() : AppState.forTesting())..repo = repo;
        addTearDown(app.dispose);
        final run = ShiftRun(t);
        await t.pumpWidget(perfApp(app, Theme(data: buildTheme(Brightness.dark),
          child: RepaintBoundary(key: _captureKey, child: ColoredBox(
            color: buildTheme(Brightness.dark).scaffoldBackgroundColor, child: entry.value())))));
        await t.pump();
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
        if (rich) {
          final anchor = find.byKey(ValueKey(entry.key.substring('rich-sleep-'.length)));
          await t.scrollUntilVisible(anchor, 300, scrollable: find.byType(Scrollable).first);
          await t.pumpAndSettle();
        }
        run.opened();
        await run.frames([0, 16, delay]);
        final spinners = find.byType(CircularProgressIndicator).evaluate().length;
        final filters = find.byType(DeviceFilter).evaluate().length;
        if (delay == 2500) await shot(t, entry.key);
        expect(repo.reads, greaterThan(0), reason: 'the real screen must reach its repository');
        repo.gate.complete();
        await run.frames([0, 16, 50, 100, 300, 1000]);
        // Drain SQLite and independent reads too, capturing every publication.
        for (var i = 0; i < 30; i++) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await run.frames([16]);
        }
        // Load latency is reported separately from CLS. A 2.5-second fixture
        // deliberately incurs latency even when every pixel stays in place.
        final result = run.score(ShiftPolicy.standard.copyWith(loadWeight: 0, colorWeight: 0));
        debugPrint(formatShiftReport(entry.key, result, run.probe.frames.length));
        // Existing metric-detail bounds. Keep slow arrivals outside the free
        // interaction window, so moving content cannot hide behind latency.
        if (entry.key == 'metric-sources') {
          expect(filters, greaterThan(0), reason: 'known paired sources reserve controls before data');
          expect(find.byType(DeviceFilter), findsOneWidget);
        }
        expect(spinners, 0, reason: '${entry.key} uses a spinner while reading');
        for (final finding in result.findings.where((f) => f.rule == 'shift')) {
          expect(finding.score, lessThan(0.002), reason: '${entry.key}: ${finding.elementId}');
        }
        expect(result.total, lessThan(0.016), reason: '${entry.key} total layout cost');
        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(seconds: 3));
      });
    }
  }
}
