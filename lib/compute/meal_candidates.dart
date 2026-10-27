// RED phase API only. Detection is implemented after the parent verifies red.
class MealSample {
  const MealSample({required this.ts, required this.hr, required this.motion,
    required this.minuteOfDay});
  final int ts, minuteOfDay;
  final double? hr, motion;
}

class MealExclusion {
  const MealExclusion(this.startTs, this.endTs);
  final int startTs, endTs;
}

List<Map<String, dynamic>> detectMealCandidates(List<MealSample> samples, {
  List<MealExclusion> sleep = const [],
  List<MealExclusion> workouts = const [],
  List<int> typicalMealMinutes = const [],
  int maxPerDay = 10,
}) => [];
