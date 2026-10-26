enum GradualPattern { ramp, steady }

bool isValidWakeWindow(int minutes) =>
    minutes >= 0 && minutes <= 120 && minutes % 15 == 0;
bool isValidGradualCadence(int seconds) =>
    seconds >= 60 && seconds <= 900 && seconds % 60 == 0;

class GradualStep {
  const GradualStep(this.index, this.at, this.pulses);
  final int index;
  final DateTime at;
  final int pulses;
}

abstract final class GradualWakeSchedule {
  static List<GradualStep> steps({
    required DateTime wakeAt,
    required int windowMinutes,
    required int cadenceSec,
    required GradualPattern pattern,
  }) {
    if (!isValidWakeWindow(windowMinutes) || !isValidGradualCadence(cadenceSec)) {
      throw ArgumentError('Invalid Gradual window or cadence');
    }
    final seconds = windowMinutes * 60;
    final count = (seconds + cadenceSec - 1) ~/ cadenceSec;
    final start = wakeAt.subtract(Duration(seconds: seconds));
    return List.generate(count, (i) => GradualStep(i,
        start.add(Duration(seconds: i * cadenceSec)),
        pattern == GradualPattern.steady ? 1 : 1 + i * 4 ~/ count));
  }
}

class WakeSettings {
  const WakeSettings({this.naturalEnabled = false,
    this.naturalWindowMinutes = 30, this.gradualEnabled = false,
    this.gradualWindowMinutes = 30, this.gradualCadenceSec = 180,
    this.gradualPattern = GradualPattern.ramp});
  final bool naturalEnabled;
  final int naturalWindowMinutes;
  final bool gradualEnabled;
  final int gradualWindowMinutes, gradualCadenceSec;
  final GradualPattern gradualPattern;

  WakeSettings copyWith({bool? naturalEnabled, int? naturalWindowMinutes,
      bool? gradualEnabled, int? gradualWindowMinutes, int? gradualCadenceSec,
      GradualPattern? gradualPattern}) => WakeSettings(
      naturalEnabled: naturalEnabled ?? this.naturalEnabled,
      naturalWindowMinutes: naturalWindowMinutes ?? this.naturalWindowMinutes,
      gradualEnabled: gradualEnabled ?? this.gradualEnabled,
      gradualWindowMinutes: gradualWindowMinutes ?? this.gradualWindowMinutes,
      gradualCadenceSec: gradualCadenceSec ?? this.gradualCadenceSec,
      gradualPattern: gradualPattern ?? this.gradualPattern);
  void validate() {
    if (naturalWindowMinutes == 0 || !isValidWakeWindow(naturalWindowMinutes) ||
        gradualWindowMinutes == 0 || !isValidWakeWindow(gradualWindowMinutes) ||
        !isValidGradualCadence(gradualCadenceSec)) {
      throw ArgumentError('Invalid wake window or cadence');
    }
  }

  Map<String, Object?> toJson() => {
    'naturalEnabled': naturalEnabled, 'naturalWindowMinutes': naturalWindowMinutes,
    'gradualEnabled': gradualEnabled, 'gradualWindowMinutes': gradualWindowMinutes,
    'gradualCadenceSec': gradualCadenceSec, 'gradualPattern': gradualPattern.name,
  };

  factory WakeSettings.fromJson(Map<String, Object?> json) {
    final settings = WakeSettings(
      naturalEnabled: json['naturalEnabled'] as bool? ?? false,
      naturalWindowMinutes: json['naturalWindowMinutes'] as int? ?? 30,
      gradualEnabled: json['gradualEnabled'] as bool? ?? false,
      gradualWindowMinutes: json['gradualWindowMinutes'] as int? ?? 30,
      gradualCadenceSec: json['gradualCadenceSec'] as int? ?? 180,
      gradualPattern: GradualPattern.values.byName(json['gradualPattern'] as String? ?? 'ramp'));
    settings.validate();
    return settings;
  }
}
