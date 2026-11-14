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
import '../../backup/backup_support.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/activity/zones.dart';
import 'package:openstrap_edge/ui2/screens/day_review.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/screens/sleep_tab.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import '../../support/as_of_recalc_fakes.dart';
import '../../support/live_guide_harness.dart';
import '../../support/shift_run.dart';

class _LateRepo extends GuideFakeRepo {
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
      late(() => super.getDaySleepV2(day));
  @override
  Future<Map<String, dynamic>> getDayTimeline(String day) =>
      late(() => super.getDayTimeline(day));
  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) => late(() async {
    final chart = await MetricRepo().getChart(metric, from: from, to: to, signals: signals);
    return (metric == 'resting_hr' || metric == 'steps') ? chart : const {'points': []};
  });
  @override
  Future<Map<String, dynamic>> getZones() => late(super.getZones);
  @override
  Future<List<ActivitySuggestion>> pendingActivities() => late(super.pendingActivities);
  @override
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) async => const {'insights': []};
}

Future<void> shot(WidgetTester t, String name) async {
  final dir = Platform.environment['CLS_SHOTS_DIR'];
  if (dir == null) return;
  final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('pilot-shot')));
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(dir).create(recursive: true);
    await File('$dir/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async {
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
    'day-strain': () => const DayStrainDetail(),
    'heart-rate-zones': () => const ZonesDetail(),
    'day-review': () => const DayReviewEntry(moments: []),
    'day-timeline': () => const DayTimelineScreen(),
  };
  for (final entry in screens.entries) {
    for (final delay in [150, 2500]) {
      testWidgets('${entry.key}: ${delay}ms pending has no spinner and stays still', (t) async {
        phoneSurface(t);
        final repo = _LateRepo();
        final app = AppState.forTesting()..repo = repo;
        addTearDown(app.dispose);
        final run = ShiftRun(t);
        await t.pumpWidget(perfApp(app, Theme(data: buildTheme(Brightness.dark),
          child: RepaintBoundary(key: const ValueKey('pilot-shot'), child: entry.value()))));
        await t.pump();
        run.opened();
        await run.frames([0, 16, delay]);
        final spinners = find.byType(CircularProgressIndicator).evaluate().length;
        if (delay == 2500) await shot(t, entry.key);
        expect(repo.reads, greaterThan(0), reason: 'the real screen must reach its repository');
        repo.gate.complete();
        await run.frames([0, 16, 50, 100, 300, 1000]);
        // Drain SQLite and independent reads too, capturing every publication.
        for (var i = 0; i < 30; i++) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await run.frames([16]);
        }
        final result = run.score();
        debugPrint(formatShiftReport(entry.key, result, run.probe.frames.length));
        // Existing metric-detail bounds. Keep slow arrivals outside the free
        // interaction window, so moving content cannot hide behind latency.
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
