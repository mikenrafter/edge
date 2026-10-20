// Fixtures for the screen-level layout consistency tests (tabs, revisit,
// first launch): the real AppShell with its real four tabs, and repos that
// serve loaded data to all of them.
//
// Time is the fake-async clock only: `settleShell` pumps fixed fake durations.
// Nothing reads a real clock except the `todayAtMs` fixtures the other shift
// tests already use.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/app_shell.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Pressable;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/screens/sleep_tab.dart';
import 'package:openstrap_edge/ui2/theme.dart';

import 'as_of_recalc_fakes.dart';
import 'layout_shift_probe.dart';
import 'shift_run.dart';

/// Home bundle + a sleep night + empty charts: every tab has loaded data.
class TabsRepo extends HomeRepo {
  TabsRepo(super.today);
  final _sleep = SleepRepo();
  final _well = WellnessRepo();

  @override
  Future<Map<String, dynamic>> getDayStress(String date) =>
      _well.getDayStress(date);
  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async => const {};
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async =>
      {};
  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => const [];
  @override
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) =>
      _well.getJournalInsights(range: range);
  @override
  Future<Map<String, dynamic>> getWeekdayEffect(
          {String key = 'readiness'}) async =>
      const {};

  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) =>
      _sleep.getDaySleepV2(date);
  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async => const {};
  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) async =>
      const {'points': []};
  @override
  Future<List<Map<String, dynamic>>> sleepWindows(
          {int days = 60, String? before}) async =>
      const [];
  @override
  Future<List<String>> availableDays() async => [todayId, yesterdayId];
  // The Health overview read needs these; a throw now shows the retry card.
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
  @override
  Future<int> pendingActivityCount() async => 0;
}

/// The real shell with the same tab builder app.dart uses.
Widget shellApp(AppState app, {ShellDomain initial = ShellDomain.today}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<LocaleController>.value(
            value: LocaleController.seed(null)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: AppShell(
          initial: initial,
          builder: (c, d) => switch (d) {
            ShellDomain.today => const HomeScreen(hour: 9),
            ShellDomain.sleep => const SleepTab(),
            ShellDomain.activity => const WorkoutScreen(),
            ShellDomain.health => const HealthScreen(),
          },
        ),
      ),
    );

/// Lets every async load land and every animation finish, in fake time.
Future<void> settleShell(WidgetTester t) async {
  for (var i = 0; i < 30; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump(const Duration(milliseconds: 100));
  }
  await t.pump(const Duration(seconds: 3));
}

/// Taps a tab-bar entry and settles.
Future<void> goTab(WidgetTester t, ShellDomain d) async {
  await t.tap(find.widgetWithText(Pressable, d.label).last);
  await settleShell(t);
}

/// A fresh probe capture of what is on screen now (offstage tabs excluded).
Frame captureFrame(WidgetTester t, {ShiftRect viewport = shiftViewport}) {
  final p = ShiftProbe(trackUnkeyed: true, visibleOnly: viewport);
  return p.capture(t, atMs: 0);
}

/// Findings at or above the policy's warnAt, formatted for a failure message.
String worst(String name, ShiftReport r, ShiftPolicy p) {
  final bad = r.findings.where((f) => f.score >= p.warnAt).toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  final b = StringBuffer('$name: ${bad.length} finding(s) >= warnAt '
      '(${p.warnAt}) of ${r.findings.length}\n');
  for (final f in bad.take(12)) {
    b.writeln('  ${f.elementId}  ${f.score.toStringAsFixed(4)}');
  }
  return b.toString();
}

/// Top findings (any severity) for the report the test prints.
String top(String name, ShiftReport r, {int n = 8}) {
  final s = [...r.findings]..sort((a, b) => b.score.compareTo(a.score));
  final b = StringBuffer('$name: ${r.findings.length} findings\n');
  for (final f in s.take(n)) {
    b.writeln('  ${f.elementId}  ${f.score.toStringAsFixed(4)}');
  }
  return b.toString();
}

/// First launch: the database is open and holds nothing at all. Every read
/// answers with an empty result (not an error), the way a fresh install does.
class EmptyTabsRepo extends TabsRepo {
  EmptyTabsRepo()
      : super({
          'daily': <String, dynamic>{},
          'sleep': <String, dynamic>{},
          'status': {
            'today_day': todayId,
            'activity_state': 'missing',
            'activity_day': todayId,
            'overnight_state': 'missing',
            'overnight_day': todayId,
            'showing_prior_overnight': false,
          },
        });

  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => const {};
  @override
  Future<Map<String, dynamic>> getDayStress(String date) async => const {};
  @override
  Future<List<String>> availableDays() async => const [];
}

/// Cards that may appear or disappear with the user's data, by design (the
/// community asks, and detected activities when there is something to review),
/// so they are not part of the "same cards in the same places" contract.
bool _optionalCard(String id) =>
    id.startsWith('card:nudge') || id == 'card:detected';

/// The ids `only` should keep for the empty-vs-loaded comparison.
bool cardOrShared(String id) =>
    (id.startsWith('card:') && !_optionalCard(id)) || id.startsWith('shared:');

Set<String> cardIds(Frame f) => {
      for (final e in f.elements)
        if (e.id.startsWith('card:') && !_optionalCard(e.id)) e.id
    };
