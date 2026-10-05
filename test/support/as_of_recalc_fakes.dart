// Shared fixtures for the as-of recalc tests.
//
// This file references NO new symbol on purpose: it must compile before any
// implementation exists, so the screen tests that import it fail for the
// intended reason (the label / recalc API is missing), not because a fixture
// is broken.
//
// Every fake repo here carries the computed time the way the spec says the
// readers will publish it — an epoch-millisecond `'computed_at'` read off the
// row actually served (never "now"):
//   * day bundles: getDaySleepV2 / getDayHrv / getDayStress → `'computed_at'`
//   * getToday → `status.activity_computed_at` / `status.overnight_computed_at`
//     (already emitted today)
//   * getChart (series) → top-level `'computed_at'` (max over the rows in range)

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// Local `DateTime(today, h, m)` as epoch ms — the shape `computed_at` takes.
int todayAtMs(int h, int m) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day, h, m).millisecondsSinceEpoch;
}

/// Local `DateTime(today - [back] days, h, m)` as epoch ms.
int daysAgoAtMs(int back, int h, int m) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - back, h, m).millisecondsSinceEpoch;
}

String get todayId => todayLabel();
String get yesterdayId {
  final n = DateTime.now();
  return dayLabelOf(DateTime(n.year, n.month, n.day - 1));
}

const monthAbbr = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Wraps [child] in the providers every screen reads, under a themed app.
Widget perfApp(AppState app, Widget child, {LocaleController? locale}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<LocaleController>.value(
            value: locale ?? LocaleController.seed(null)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: child),
      ),
    );

/// Real-time poll + pump, for screens whose load goes to sqflite or to a fake
/// repo through several awaits.
///
/// With [until], polls (real time, [within]) until it holds, pumps one more
/// frame, and fails the test naming [what] if it never does. Prefer it over a
/// bare count whenever the test has something it can observe: the count is
/// only a lower bound on real time, so a busy machine can run it out before
/// the load lands.
Future<void> settle(WidgetTester t,
    {int n = 40,
    bool Function()? until,
    String? what,
    Duration within = const Duration(seconds: 10)}) async {
  if (until == null) {
    for (var i = 0; i < n; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await t.pump(const Duration(milliseconds: 16));
    }
    return;
  }
  final end = DateTime.now().add(within);
  while (!until()) {
    if (!DateTime.now().isBefore(end)) {
      throw TestFailure('settle(${what ?? 'condition'}) was not met within '
          '${within.inMilliseconds} ms');
    }
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)));
    await t.pump(const Duration(milliseconds: 16));
  }
  await t.pump(const Duration(milliseconds: 16));
}

// ── Home ────────────────────────────────────────────────────────────────────

/// A `getToday` bundle with its own row (overnight + activity both `ready`
/// and dated today). [readiness] is the overnight value Home prints as text.
Map<String, dynamic> homeBundle({
  num readiness = 70,
  int? overnightAt,
  int? activityAt,
  String? overnightDay,
  bool heldOver = false,
  bool withDaily = true,
}) =>
    {
      'daily': withDaily
          ? {
              'readiness': {'value': readiness, 'confidence': .8, 'tier': 'HIGH'},
              'resting_hr': {'value': 50, 'confidence': .8, 'tier': 'HIGH'},
              'strain': {'value': 5.0, 'confidence': .8, 'tier': 'ESTIMATE'},
              'steps': {'value': 1000, 'confidence': .8, 'tier': 'ESTIMATE'},
            }
          : <String, dynamic>{},
      'sleep': withDaily
          ? {
              'duration_min': {'value': 400, 'confidence': .8, 'tier': 'HIGH'},
            }
          : <String, dynamic>{},
      'status': {
        'today_day': todayId,
        'activity_state': activityAt == null ? 'missing' : 'ready',
        'activity_day': todayId,
        'activity_computed_at': activityAt,
        'overnight_state':
            heldOver ? 'building' : (overnightAt == null ? 'missing' : 'ready'),
        'overnight_day': overnightDay ?? todayId,
        'overnight_computed_at': overnightAt,
        'showing_prior_overnight': heldOver,
      },
    };

class HomeRepo extends LocalRepository {
  HomeRepo(this.today);
  Map<String, dynamic> today;
  int reads = 0;

  @override
  Future<Map<String, dynamic>> getToday() async {
    reads++;
    return today;
  }

  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {'name': 'Alex'};
  @override
  Future<List<String>> availableDays() async => [todayId];
}

// ── SleepDetail ─────────────────────────────────────────────────────────────

class SleepRepo extends LocalRepository {
  SleepRepo({this.computedAt});
  int? computedAt;

  @override
  Future<Map<String, dynamic>> getToday() async =>
      {'status': {'today_day': todayId}};
  @override
  Future<List<String>> availableDays() async => [todayId, yesterdayId];
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async {
    final onset = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 36000;
    return {
      'duration_min': 443,
      'in_bed_min': 486,
      'awake_min': 20,
      'efficiency': .91,
      'onset_ts': onset,
      'wake_ts': onset + 486 * 60,
      'light_min': 170,
      'deep_min': 85,
      'rem_min': 95,
      'hypnogram': [
        {'t': onset, 'stage': 'light'},
        {'t': onset + 3600, 'stage': 'deep'},
        {'t': onset + 7200, 'stage': 'rem'},
        {'t': onset + 486 * 60, 'stage': 'awake'},
      ],
      'computed_at': computedAt,
    };
  }

  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async => const {};
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) async =>
      const {'points': []};
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60}) async =>
      const [];
}

// ── MetricDetail ────────────────────────────────────────────────────────────

class MetricRepo extends LocalRepository {
  MetricRepo({this.computedAt});
  int? computedAt;

  /// When non-null, `getJournalInsights` waits on it — the "recompute is still
  /// running" half of the cache tests.
  Completer<Map<String, dynamic>>? insightsGate;
  int insightsCalls = 0;
  bool insightsThrow = false;

  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) async {
    final n = DateTime.now();
    return {
      'points': [
        for (var back = 6; back >= 0; back--)
          {
            't': DateTime(n.year, n.month, n.day - back, 12)
                    .millisecondsSinceEpoch ~/
                1000,
            'v': 54.0 + back,
          },
      ],
      'computed_at': computedAt,
    };
  }

  @override
  Future<List<String>> availableDays() async => [
        for (var back = 0; back < 10; back++)
          dayLabelOf(DateTime(
              DateTime.now().year, DateTime.now().month, DateTime.now().day - back)),
      ];
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) {
    insightsCalls++;
    if (insightsThrow) return Future.error(StateError('insights failed'));
    final g = insightsGate;
    return g != null ? g.future : Future.value(const {'insights': []});
  }
}

// ── Beats ───────────────────────────────────────────────────────────────────

class BeatsRepo extends LocalRepository {
  BeatsRepo({this.computedAt});
  int? computedAt;

  /// When non-null, the corrected-RR read waits on it.
  Completer<void>? beatsGate;
  int beatsCalls = 0;
  bool beatsThrow = false;
  List<double> nn = [for (var i = 0; i < 400; i++) 880 + (i % 37) * 3.0];

  @override
  Future<Map<String, dynamic>> getToday() async =>
      {'status': {'today_day': todayId}};
  @override
  Future<List<String>> availableDays() async => [todayId, yesterdayId];
  @override
  Future<Map<String, dynamic>> getDayHrv(String date) async =>
      {'computed_at': computedAt};
  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async => const {};
  @override
  Future<({List<double> nn, int rawBeats, double cleanFraction})> getNightBeats(
      String date) async {
    beatsCalls++;
    final g = beatsGate;
    if (g != null) await g.future;
    if (beatsThrow) throw StateError('beats failed');
    return (nn: nn, rawBeats: nn.length + 12, cleanFraction: .97);
  }

  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) async =>
      const {'points': []};
}

// ── Wellness ────────────────────────────────────────────────────────────────

class WellnessRepo extends LocalRepository {
  WellnessRepo({this.computedAt});
  int? computedAt;

  Completer<Map<String, dynamic>>? insightsGate;
  int insightsCalls = 0;
  bool insightsThrow = false;
  Map<String, dynamic> insights = const {'numeric_insights': []};

  @override
  Future<Map<String, dynamic>> getToday() async =>
      {'status': {'today_day': todayId}};
  @override
  Future<Map<String, dynamic>> getDayStress(String date) async => {
        'readiness': {'value': 62.0, 'confidence': 0.8, 'tier': 'HIGH'},
        'stress': {'score': 34},
        'computed_at': computedAt,
      };
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async =>
      {};
  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => const [];
  @override
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) {
    insightsCalls++;
    if (insightsThrow) return Future.error(StateError('insights failed'));
    final g = insightsGate;
    return g != null ? g.future : Future.value(insights);
  }

  @override
  Future<Map<String, dynamic>> getWeekdayEffect(
          {String key = 'readiness'}) async =>
      const {};
}
