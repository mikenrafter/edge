// Navigation data is independent of asynchronously built page content.
import 'package:flutter/widgets.dart';

enum GuideNode {
  today, sleep, activity, activityOverview, activityActivities, activityHistory,
  health, settings, dayStrain, zones, naps, alarm, review, picker, setup, live,
  logWorkout, workoutSummary,
}

enum GuideHopKind { back, tab, subTab, page }

class GuideHop {
  final GuideNode node;
  final GuideHopKind kind;
  const GuideHop(this.node, this.kind);
}

class GuideNavigation {
  static List<GuideHop> route(GuideNode from, GuideNode to) => const [];
  static bool onPath(GuideNode current, GuideNode target) => current == target;
  static GuideNode? location(Element root) => null;
}

class GuideLocation extends StatelessWidget {
  final GuideNode node;
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
  const GuideLocation({super.key, required this.node, required this.child});
}
