import 'package:flutter/material.dart';
import '../screens/day_timeline.dart' show DayGraph;
import '../chart_annotations.dart';
import 'timeline_controller.dart';
export 'timeline_controller.dart';
Widget timelineChart({required TimelineController controller, required DayGraph graph,
    required List<ChartAnnotation> annotations, required ValueChanged<String> onAnnotationSelected}) =>
    const SizedBox(key: ValueKey('timeline-chart-placeholder'));
class TimelineZoomControls extends StatelessWidget {
  const TimelineZoomControls({super.key, required this.controller});
  final TimelineController controller;
  @override
  Widget build(BuildContext context) => const Text('Zoom');
}
