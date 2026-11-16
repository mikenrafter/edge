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
import 'package:openstrap_edge/data/day_label.dart' show dayLabelBefore;
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
import 'package:openstrap_edge/ui2/skeleton/async_section.dart'
    show PendingContent;
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;
import 'package:openstrap_edge/ui2/profile/devices.dart' show DeviceFilter;
import '../../support/as_of_recalc_fakes.dart';
import '../../support/live_guide_harness.dart';
import '../../support/scripted_artifact_source.dart';
import '../../support/shift_run.dart';
import '../../support/tail_shift.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/wake/wake_timeline.dart';
import '../../support/skeleton_fixture.dart' show skLoadAppFonts;

class _LateRepo extends GuideFakeRepo {
  _LateRepo({this.rich = false});
  final bool rich;
  @override
  Future<SleepPrimaryRead?> getSleepDetailPrimary(String day) async {
    if (!rich) return null;
    final cd = await getInsights();
    final timeline = {
            for (final key in ['hr', 'hrv', 'resp', 'skin_temp'])
              key: [
                for (var i = 0; i < 98; i++)
                  {
                    't':
                        DateTime.now().millisecondsSinceEpoch ~/ 1000 -
                        36000 +
                        i * 300,
                    'v':
                        (key == 'hr'
                            ? 55
                            : key == 'hrv'
                            ? 45
                            : key == 'resp'
                            ? 14
                            : 33) +
                        i % 3 * .1,
                  },
              ],
          };
    final noon =
        DateTime(
          DateTime.now().year,
          DateTime.now().month,
          DateTime.now().day,
          12,
        ).millisecondsSinceEpoch ~/
        1000;
    return SleepPrimaryRead(
      bundle: SleepDetailBundle(
        night: await SleepRepo().getDaySleepV2(day),
        timeline: timeline,
        insights: cd,
        windows: const [],
        charts: {
          for (final key in [
            'unobserved_min',
            'awakenings',
            'longest_sleep_min',
            'sol_min',
          ])
            key: {
              'points': [
                {'t': noon, 'v': key == 'unobserved_min' ? 60 : 5},
              ],
            },
        },
      ),
      wake: const WakeNightTimeline(),
      historyCount: 28,
      devices: await getDeviceNights(day),
    );
  }

  final gate = Completer<void>();
  int reads = 0;
  Future<T> late<T>(Future<T> Function() read) async {
    reads++;
    await gate.future;
    return read();
  }

  @override
  Future<Map<String, dynamic>> getToday() =>
      rich ? super.getToday() : late(super.getToday);
  @override
  Future<List<String>> availableDays() => rich
      ? Future.value([for (var i = 0; i < 28; i++) dayLabelBefore(todayId, i)!])
      : late(
          () async => [
            for (var i = 0; i < 28; i++) dayLabelBefore(todayId, i)!,
          ],
        );
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String day) => late(
    () => rich ? SleepRepo().getDaySleepV2(day) : super.getDaySleepV2(day),
  );
  @override
  Future<Map<String, dynamic>> getDayTimeline(String day) => late(
    () async => rich
        ? {
            for (final key in ['hr', 'hrv', 'resp', 'skin_temp'])
              key: [
                for (var i = 0; i < 98; i++)
                  {
                    't':
                        DateTime.now().millisecondsSinceEpoch ~/ 1000 -
                        36000 +
                        i * 300,
                    'v':
                        (key == 'hr'
                            ? 55
                            : key == 'hrv'
                            ? 45
                            : key == 'resp'
                            ? 14
                            : 33) +
                        i % 3 * .1,
                  },
              ],
          }
        : await super.getDayTimeline(day),
  );
  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) => late(() async {
    if (rich) {
      return {
        'points': [
          for (var i = 28; i >= 0; i--)
            {
              't':
                  DateTime(
                    DateTime.now().year,
                    DateTime.now().month,
                    DateTime.now().day - i,
                    12,
                  ).millisecondsSinceEpoch ~/
                  1000,
              'v': metric == 'sleep'
                  ? 440 + i % 5
                  : metric == 'deep'
                  ? 80 + i % 5
                  : metric == 'efficiency'
                  ? 90 + i % 5
                  : metric == 'unobserved_min'
                  ? 60
                  : 5,
            },
        ],
      };
    }
    final chart = await MetricRepo().getChart(
      metric,
      from: from,
      to: to,
      signals: signals,
    );
    return (metric == 'resting_hr' || metric == 'steps')
        ? chart
        : const {'points': []};
  });
  @override
  Future<List<Map<String, Object?>>> getDeviceNights(String day) async => rich
      ? [
          {'device_id': 'watch', 'label': 'Watch', 'family': 'colmi'},
        ]
      : [];
  @override
  Future<Map<String, dynamic>> getInsights() async => rich
      ? {
          'sleep_coach': {
            'need': {
              'status': 'ok',
              'value': {'need_sec': 28800},
            },
            'bedtime': {
              'status': 'ok',
              'value': {'bedtime_min_of_day': 1320},
            },
          },
          'sleep_debt': {
            'status': 'ok',
            'value': {'debt_hours': 1},
          },
        }
      : {};
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({
    int days = 60,
    String? before,
  }) async => rich
      ? [
          for (var i = 1; i <= 28; i++)
            {
              'date': dayLabelBefore(todayId, i)!,
              'onset_ts':
                  DateTime(
                    DateTime.now().year,
                    DateTime.now().month,
                    DateTime.now().day - i - 1,
                    23,
                  ).millisecondsSinceEpoch ~/
                  1000,
            },
        ]
      : [];
  @override
  Future<Map<String, dynamic>> getZones() => late(super.getZones);
  @override
  Future<Map<String, dynamic>> getDayStrain(String day) => late(
    () async => {
      ...await super.getDayStrain(day),
      'curve': [
        for (var m = 0; m < 1440; m += 30)
          {
            't':
                DateTime(
                      DateTime.now().year,
                      DateTime.now().month,
                      DateTime.now().day,
                    ).millisecondsSinceEpoch ~/
                    1000 +
                m * 60,
            'v': m / 1440 * 9.4,
          },
      ],
    },
  );
  @override
  Future<List<ActivitySuggestion>> pendingActivities() =>
      late(super.pendingActivities);
  @override
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) =>
      late(() async => const {'insights': []});
  @override
  Future<Map<String, dynamic>> getWeekdayEffect({String key = 'readiness'}) =>
      late(() async => const {});
  @override
  Future<String?> artifactSignature(String key) =>
      late(() async => key == 'circadian' ? 'pilot-circadian' : null);
  @override
  Future<Map<String, dynamic>> getDayHrv(String day) =>
      late(() async => const {});
  @override
  Future<Map<String, dynamic>> getDaySteps(String day) =>
      late(() async => const {});
  @override
  Future<Map<String, dynamic>> getDayNaps(String day) => late(
    () async => {
      'naps': [
        for (var i = 0; i < 2; i++)
          {
            'start':
                DateTime.now().millisecondsSinceEpoch ~/ 1000 - 7200 + i * 3600,
            'end':
                DateTime.now().millisecondsSinceEpoch ~/ 1000 - 4500 + i * 3600,
            'duration_min': 45,
            'source': 'auto',
          },
      ],
      'nap_min': 90,
    },
  );
  @override
  Future<({List<double> nn, int rawBeats, double cleanFraction})> getNightBeats(
    String day,
  ) => late(
    () async => (
      nn: [for (var i = 0; i < 400; i++) 880 + (i % 37) * 3.0],
      rawBeats: 412,
      cleanFraction: .97,
    ),
  );
}

class _SourcesApp extends AppState {
  _SourcesApp() : super.forTesting();
  @override
  List<Map<String, Object?>> get sensors => [
    for (var i = 0; i < 2; i++)
      {
        'id': 'band-$i',
        'label': 'Band $i',
        'adapter_id': 'gen4',
        'tier': 'wristOptical',
      },
  ];
}

const _sleepSections = [
  'card:answer',
  'section:night',
  'card:stages',
  'card:versus',
  'card:unusual',
  'card:overnight',
  'card:tonight',
];
final _captureKey = GlobalKey();

Future<void> shot(WidgetTester t, String name) async {
  final dir = Platform.environment['CLS_SHOTS_DIR'];
  if (dir == null) return;
  final boundary = t.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(dir).create(recursive: true);
    await File(
      '$dir/${name.replaceAll(':', '-')}.png',
    ).writeAsBytes(data!.buffer.asUint8List());
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
    for (final section in _sleepSections)
      'rich-sleep-$section': () => const SleepDetail(),
  };
  for (final entry in screens.entries) {
    // The old loading page has no lower sections to scroll to. Its first
    // viewport is captured once for each route; rich cases measure the fix.
    if (Platform.environment['CLS_BASELINE'] == '1' &&
        entry.key.startsWith('rich-')) {
      continue;
    }
    for (final delay in entry.key.startsWith('rich-') ? [2500] : [150, 2500]) {
      testWidgets(
        '${entry.key}: ${delay}ms pending has no spinner and stays still',
        (t) async {
          phoneSurface(t);
          final rich = entry.key.startsWith('rich-');
          final repo = _LateRepo(rich: rich);
          final app =
              (entry.key == 'metric-sources'
                    ? _SourcesApp()
                    : AppState.forTesting())
                ..repo = repo;
          if (entry.key == 'body-clock') {
            app.debugArtifactSource = FakeArtifactSource()
              ..sigs['circadian'] = 'pilot-circadian'
              ..results['circadian'] = {
                'chronotype': {
                  'value': {'type_label': 'Intermediate'},
                },
                'social_jetlag': {
                  'value': {
                    'abs_hours': 1.2,
                    'mid_sleep_free_h': 4.5,
                    'mid_sleep_work_h': 3.3,
                    'n_free': 8,
                    'n_work': 20,
                  },
                },
                'regularity': {
                  'value': {'sri': 76},
                },
              };
          }
          addTearDown(app.dispose);
          final run = ShiftRun(t);
          await t.pumpWidget(
            perfApp(
              app,
              Theme(
                data: buildTheme(Brightness.dark),
                child: RepaintBoundary(
                  key: _captureKey,
                  child: ColoredBox(
                    color: buildTheme(Brightness.dark).scaffoldBackgroundColor,
                    child: entry.value(),
                  ),
                ),
              ),
            ),
          );
          await t.pump();
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump();
          if (rich) {
            final anchor = find.byKey(
              ValueKey(entry.key.substring('rich-sleep-'.length)),
            );
            await t.scrollUntilVisible(
              anchor,
              300,
              scrollable: find.byType(Scrollable).first,
            );
            // Finish the setup gesture without waiting on the perpetual pulse.
            // Elastic scroll recovery is user motion, not late-data movement.
            final position = t.state<ScrollableState>(find.byType(Scrollable).first).position;
            position.jumpTo(position.pixels.clamp(0, position.maxScrollExtent));
            await t.pump(const Duration(milliseconds: 16));
          }
          await settleHeight(t);
          // The owner's expanded-section rule permits unknown tails to grow.
          // Pin the primary real shape rather than hiding that growth in a slot.
          final prefixKey = switch (entry.key) {
            'rich-sleep-section:night' => 'sleep-night-plot',
            'rich-sleep-card:stages' => 'sleep-stage-rows',
            'rich-sleep-card:answer' => 'card:answer',
            'typical-day' => 'typical-primary-plot',
            'naps' => 'naps-primary-action',
            'heart-rate-zones' => 'zones-primary-rows',
          'day-strain' => 'day-strain-primary',
          'rich-sleep-card:versus' => 'sleep-versus-primary',
          'rich-sleep-card:unusual' => 'card:unusual',
          'rich-sleep-card:overnight' => 'card:overnight',
          'rich-sleep-card:tonight' => 'card:tonight',
          _ => null,
          };
          final prefix = prefixKey == null ? null : find.byKey(ValueKey(prefixKey));
          final beforePrefix = prefix == null ? null : t.getRect(prefix);
          run.opened();
          // Sample through debounce/fade rather than jumping directly to its first
          // animation frame at 2.5 s; screenshots must show the painted pending state.
          await run.frames(delay == 2500 ? [0, 16, 200, 216, 466, delay] : [0, 16, delay]);
          final spinners = find
              .byType(CircularProgressIndicator)
              .evaluate()
              .length;
          final filters = find.byType(DeviceFilter).evaluate().length;
          if (delay == 2500) await shot(t, entry.key);
          expect(
            repo.reads,
            greaterThan(0),
            reason: 'the real screen must reach its repository',
          );
        final pendingFrame = run.probe.frames.last;
        final verdict = find.byKey(const ValueKey('sleep-unusual-pending'));
        final tailTop =
            entry.key == 'rich-sleep-card:unusual' &&
                verdict.evaluate().isNotEmpty
            ? t.getRect(verdict).top
            : prefix == null
            ? null
            : t.getRect(prefix).bottom;
        repo.gate.complete();
          await run.frames([0, 16, 50, 100, 300, 1000]);
          // Drain SQLite and independent reads too, capturing every publication.
          for (var i = 0; i < 30; i++) {
            await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await run.frames([16]);
          }
          expect(
            find.byWidgetPredicate((w) => w is PendingContent && w.pending),
            findsNothing,
            reason:
                'the fixture must settle; a permanently pending page cannot pass',
          );
          // Load latency is reported separately from CLS. A 2.5-second fixture
          // deliberately incurs latency even when every pixel stays in place.
          final result = run.score(
            ShiftPolicy.standard.copyWith(loadWeight: 0, colorWeight: 0),
          );
          debugPrint(
            formatShiftReport(entry.key, result, run.probe.frames.length),
          );
          // Existing metric-detail bounds. Keep slow arrivals outside the free
          // interaction window, so moving content cannot hide behind latency.
          if (entry.key == 'metric-sources') {
            expect(
              filters,
              greaterThan(0),
              reason: 'known paired sources reserve controls before data',
            );
            expect(find.byType(DeviceFilter), findsOneWidget);
          }
          expect(
            spinners,
            0,
            reason: '${entry.key} uses a spinner while reading',
          );
          final hasUnknownTail = rich || ['heart-rate-zones', 'day-strain'].contains(entry.key);
        if (prefix != null) {
          expect(
            t.getRect(prefix),
            beforePrefix,
            reason: '${entry.key} primary rect',
          );
        }
        if (hasUnknownTail) {
          expect(
            tailTop,
            isNotNull,
            reason: '${entry.key} needs a measured tail boundary',
          );
          final measured = checkGrowingTail(
            scenario: run.probe.scenario(shiftViewport),
            pending: pendingFrame,
            tailTop: tailTop!,
            route: entry.key,
          );
          debugPrint(
            'TAIL ${entry.key}: prefix=${measured.prefix.total.toStringAsFixed(4)} tail=${measured.tail.total.toStringAsFixed(4)}',
          );
          // Cold SQL does not expose a count/size before the read. Tails fit
            // their contents after the primary shape/header. Report their FULL
            // cost above; do not pretend this is a near-zero global score.
            expect(find.descendant(of: find.byType(SettingsAccordion), matching: find.byWidgetPredicate((w) => w is Scrollable && (w.axisDirection == AxisDirection.down || w.axisDirection == AxisDirection.up))), findsNothing);
          }
          for (final finding in result.findings.where(
            (f) => f.rule == 'shift' && !hasUnknownTail,
          )) {
            expect(
              finding.score,
              lessThan(0.002),
              reason: '${entry.key}: ${finding.elementId}',
            );
          }
          if (!hasUnknownTail) { expect(
            result.total,
            lessThan(0.016),
            reason: '${entry.key} total layout cost',
          ); }
          await t.pumpWidget(const SizedBox());
          await t.pump(const Duration(seconds: 3));
        },
      );
    }
  }
}
