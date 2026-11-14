// GuideNavigation owns the declared navigation tree, not the app's navigation
// state. Location is read from mounted page identities even while data loads.
import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import '../app_shell.dart' show AppShell;
import '../grammar.dart' show SubTabs;
import '../screens/metric_detail.dart' show MetricDetail;
import 'guide_target.dart';
import 'guide_labels.dart';
import 'tree_geometry.dart';

enum GuideNode {
  today,
  sleep,
  activity,
  activityOverview,
  activityActivities,
  activityHistory,
  health,
  settings,
  dayStrain,
  zones,
  naps,
  alarm,
  review,
  picker,
  setup,
  live,
  logWorkout,
  workoutSummary,
  daySteps,
  dayTimeline,
  tracks,
  trackDetail,
  recovery,
  stress,
  journal,
  nutrition,
  nutritionLog,
  coach,
  coachSetup,
  circadian,
  sleepDebt,
  sleepConsistency,
  sleepNeed,
  sleepRegularity,
  beats,
  ecg,
  ecgCapture,
  ecgDetail,
  breathing,
  investigate,
  findings,
  drivers,
  whatChanged,
  month,
  advanced,
  profile,
  devices,
  deviceDetail,
  liveDevices,
  deviceLab,
  bandGestures,
  haptics,
  bandNotifications,
  phoneImport,
  devLogs,
  reportIssue,
  help,
  guideDetail,
  metric,
}

enum GuideHopKind { back, tab, subTab, page }

class GuideHop {
  final GuideNode node;
  final GuideHopKind kind;
  const GuideHop(this.node, this.kind);
}

class GuideDestination {
  final GuideNode? parent;
  final List<String> screens;
  const GuideDestination(this.parent, [this.screens = const []]);
}

/// Canonical entry paths. The root Navigator still owns actual pushed history:
/// unknown routes return through its Back control, never a forced pop.
const guideNavigationTree = <GuideNode, GuideDestination>{
  GuideNode.today: GuideDestination(null, ['HomeScreen']),
  GuideNode.sleep: GuideDestination(null, ['SleepTab', 'SleepDetail']),
  GuideNode.activity: GuideDestination(null, ['WorkoutScreen']),
  GuideNode.activityOverview: GuideDestination(GuideNode.activity),
  GuideNode.activityActivities: GuideDestination(GuideNode.activity),
  GuideNode.activityHistory: GuideDestination(GuideNode.activity),
  GuideNode.health: GuideDestination(null, ['HealthScreen']),
  GuideNode.settings: GuideDestination(null, ['MoreSettings']),
  GuideNode.dayStrain: GuideDestination(GuideNode.today, ['DayStrainDetail']),
  GuideNode.zones: GuideDestination(GuideNode.dayStrain, ['ZonesDetail']),
  GuideNode.daySteps: GuideDestination(GuideNode.today, ['DayStepsDetail']),
  GuideNode.dayTimeline: GuideDestination(GuideNode.today, [
    'DayTimelineScreen',
  ]),
  GuideNode.review: GuideDestination(GuideNode.today, ['DayReviewEntry']),
  GuideNode.recovery: GuideDestination(GuideNode.today, []),
  GuideNode.stress: GuideDestination(GuideNode.today, []),
  GuideNode.journal: GuideDestination(GuideNode.today, ['JournalCompose']),
  GuideNode.nutrition: GuideDestination(GuideNode.today, ['NutritionScreen']),
  GuideNode.nutritionLog: GuideDestination(GuideNode.nutrition, [
    'LogNutrition',
  ]),
  GuideNode.coach: GuideDestination(GuideNode.today, ['CoachScreen']),
  GuideNode.coachSetup: GuideDestination(GuideNode.coach, ['CoachSetup']),
  GuideNode.month: GuideDestination(GuideNode.today, ['MonthGrid']),
  GuideNode.whatChanged: GuideDestination(GuideNode.today, [
    'WhatChangedScreen',
  ]),
  GuideNode.naps: GuideDestination(GuideNode.sleep, ['NapsScreen']),
  GuideNode.alarm: GuideDestination(GuideNode.sleep, ['AlarmScreen']),
  GuideNode.circadian: GuideDestination(GuideNode.sleep, ['CircadianDetail']),
  GuideNode.sleepDebt: GuideDestination(GuideNode.sleep, []),
  GuideNode.sleepConsistency: GuideDestination(GuideNode.sleep, [
    'SleepConsistencyDetail',
  ]),
  GuideNode.sleepNeed: GuideDestination(GuideNode.sleep, []),
  GuideNode.sleepRegularity: GuideDestination(GuideNode.sleep, [
    'SleepRegularityDetail',
  ]),
  GuideNode.picker: GuideDestination(GuideNode.activityOverview, [
    'ActivityPicker',
  ]),
  GuideNode.setup: GuideDestination(GuideNode.picker, ['ActivitySetup']),
  GuideNode.live: GuideDestination(GuideNode.setup, ['LiveShell']),
  GuideNode.logWorkout: GuideDestination(GuideNode.activityHistory, [
    'LogWorkout',
  ]),
  GuideNode.workoutSummary: GuideDestination(GuideNode.activityOverview, [
    'ActivitySummary',
  ]),
  GuideNode.tracks: GuideDestination(GuideNode.activityActivities, [
    'TracksScreen',
  ]),
  GuideNode.trackDetail: GuideDestination(GuideNode.tracks, [
    'TrackDetailScreen',
  ]),
  GuideNode.beats: GuideDestination(GuideNode.health, ['Beats']),
  GuideNode.ecg: GuideDestination(GuideNode.health, ['EcgHomeScreen']),
  GuideNode.ecgCapture: GuideDestination(GuideNode.ecg, ['EcgCaptureScreen']),
  GuideNode.ecgDetail: GuideDestination(GuideNode.ecg, ['EcgDetailScreen']),
  GuideNode.breathing: GuideDestination(GuideNode.health, ['CalmBreathing']),
  GuideNode.investigate: GuideDestination(GuideNode.health, ['Investigate']),
  GuideNode.findings: GuideDestination(GuideNode.health, ['FindingsLog']),
  GuideNode.drivers: GuideDestination(GuideNode.health, ['DriverBreakdown']),
  GuideNode.advanced: GuideDestination(GuideNode.settings, ['AdvancedScreen']),
  GuideNode.profile: GuideDestination(GuideNode.settings, ['EditProfile']),
  GuideNode.devices: GuideDestination(GuideNode.settings, ['MyDevices']),
  GuideNode.deviceDetail: GuideDestination(GuideNode.devices, ['DeviceDetail']),
  GuideNode.liveDevices: GuideDestination(GuideNode.devices, ['LiveDevices']),
  GuideNode.deviceLab: GuideDestination(GuideNode.devices, ['DeviceLab']),
  GuideNode.bandGestures: GuideDestination(GuideNode.settings, [
    'BandGestures',
  ]),
  GuideNode.haptics: GuideDestination(GuideNode.settings, ['HapticsSettings']),
  GuideNode.bandNotifications: GuideDestination(GuideNode.settings, [
    'BandNotifications',
  ]),
  GuideNode.phoneImport: GuideDestination(GuideNode.settings, ['PhoneImport']),
  GuideNode.devLogs: GuideDestination(GuideNode.settings, ['DevLogsPage']),
  GuideNode.reportIssue: GuideDestination(GuideNode.settings, [
    'ReportIssueScreen',
  ]),
  GuideNode.metric: GuideDestination(GuideNode.health),
  GuideNode.help: GuideDestination(GuideNode.settings, ['HelpScreen']),
  GuideNode.guideDetail: GuideDestination(GuideNode.help, [
    'GuideDetailScreen',
  ]),
};

class GuideNavigation {
  static GuideNode? parent(GuideNode node) => guideNavigationTree[node]!.parent;
  static GuideNode tabOf(GuideNode node) {
    var tab = node;
    while (parent(tab) != null) {
      tab = parent(tab)!;
    }
    return tab;
  }

  static bool onPath(GuideNode current, GuideNode target) {
    for (GuideNode? n = target; n != null; n = parent(n)) {
      if (n == current) return true;
    }
    return false;
  }

  static List<GuideNode> _ancestors(GuideNode node) => [
    node,
    if (parent(node) case final GuideNode p) ..._ancestors(p),
  ];

  // CLAIM(guide-navigation-hops): each hop is an actual control, not a virtual
  // container node [guide_r3_navigation_test]. Activity's sub-tabs are siblings.
  static List<GuideHop> route(GuideNode from, GuideNode to) {
    if (from == to) return const [];
    final up = _ancestors(from), down = _ancestors(to);
    final common = up.where(down.contains).firstOrNull;
    final hops = <GuideHop>[];
    var current = from;
    while (current != common && parent(current) != null) {
      final p = parent(current)!;
      if (p == GuideNode.activity)
        break; // no Back from a sub-tab to its container
      hops.add(GuideHop(p, GuideHopKind.back));
      current = p;
    }
    if (tabOf(current) != tabOf(to)) {
      final tab = tabOf(to);
      current = tab == GuideNode.activity ? GuideNode.activityOverview : tab;
      hops.add(GuideHop(current, GuideHopKind.tab));
    }
    if (current == to) return hops;
    final path = down.reversed.toList();
    for (final next in path) {
      if (next == GuideNode.activity ||
          next == current ||
          onPath(next, current))
        continue;
      hops.add(
        GuideHop(
          next,
          parent(next) == GuideNode.activity
              ? GuideHopKind.subTab
              : GuideHopKind.page,
        ),
      );
      current = next;
    }
    return hops;
  }

  /// Screen identity is present during loading. The marker is available for
  /// pages whose selected branch changes independently of their root widget.
  static GuideNode? location(Element root) {
    GuideNode? found;
    var inActivity = false;
    for (final e in onstageElements(root)) {
      final w = e.widget;
      if (w is GuideLocation) return w.node;
      if (w is MetricDetail) return switch (w.metricKey) {
        'recovery' => GuideNode.recovery, 'stress' => GuideNode.stress,
        'sleep_debt' => GuideNode.sleepDebt, 'sleep_consistency' => GuideNode.sleepConsistency,
        'sleep_need' => GuideNode.sleepNeed, 'sleep_regularity' => GuideNode.sleepRegularity,
        'steps' => GuideNode.daySteps, _ => GuideNode.metric,
      };
      if (w is SubTabs && inActivity) {
        return [
          GuideNode.activityOverview,
          GuideNode.activityActivities,
          GuideNode.activityHistory,
        ][w.index];
      }
      final name = w.runtimeType.toString();
      for (final entry in guideNavigationTree.entries) {
        if (entry.value.screens.contains(name)) {
          found ??= entry.key;
          if (entry.key == GuideNode.activity) inActivity = true;
          break;
        }
      }
      if (w is IndexedStack &&
          found == null &&
          e.findAncestorWidgetOfExactType<AppShell>() != null) {
        found = [
          GuideNode.today,
          GuideNode.sleep,
          GuideNode.activity,
          GuideNode.health,
          GuideNode.settings,
        ][w.index ?? 0];
      }
    }
    return found;
  }

  static int? tabIndex(GuideNode node) => switch (tabOf(node)) {
    GuideNode.today => 0,
    GuideNode.sleep => 1,
    GuideNode.activity => 2,
    GuideNode.health => 3,
    GuideNode.settings => 4,
    _ => null,
  };
  static int? subTabIndex(GuideNode node) => switch (node) {
    GuideNode.activityOverview => 0,
    GuideNode.activityActivities => 1,
    GuideNode.activityHistory => 2,
    _ => null,
  };

  static TargetFound? entry(Element page, GuideHop hop, AppLocalizations l) {
    final label = switch (hop.node) {
      GuideNode.dayStrain => ScreenLabel.homeRingStrain,
      GuideNode.zones => ScreenLabel.dayStrainHowSet,
      GuideNode.naps => ScreenLabel.sleepDetailEditNaps,
      GuideNode.alarm => ScreenLabel.settingsAlarmRowTitle,
      GuideNode.review => ScreenLabel.homeReviewActivities,
      GuideNode.picker => ScreenLabel.workoutStartSessionLabel,
      GuideNode.logWorkout => ScreenLabel.workoutLogPastFix,
      _ => null,
    };
    if (label == null) return null;
    final result = GuideTarget.label(label).resolve(page, l);
    return result is TargetFound ? result : null;
  }
}

/// A declaration only: adds no render object, layout or semantics node.
class GuideLocation extends StatelessWidget {
  final GuideNode node;
  final Widget child;
  const GuideLocation({super.key, required this.node, required this.child});
  @override
  Widget build(BuildContext context) => child;
}
