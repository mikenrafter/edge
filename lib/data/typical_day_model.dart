// RED phase contracts only. The parent replaces placeholders after red.
class ClockWindow {
  const ClockWindow(this.startMinute, this.endMinute);
  final int startMinute, endMinute;
  List<(int, int)> get segments => [];
  bool contains(int minute) => false;
}

class CaffeineDose {
  const CaffeineDose({required this.at, required this.mg});
  final DateTime at;
  final double mg;
}

class CaffeineDay {
  const CaffeineDay({required this.dayId, this.wakeAt, this.bedAt,
    this.doses = const [], this.afternoonDip, this.napsMinutes,
    this.restingHr, this.sleepLatencyMinutes, this.totalSleepMinutes});
  final String dayId;
  final DateTime? wakeAt, bedAt;
  final List<CaffeineDose> doses;
  final double? afternoonDip, napsMinutes, restingHr;
  final double? sleepLatencyMinutes, totalSleepMinutes;
}

class CaffeineTimingSummary {
  const CaffeineTimingSummary({this.dayCount = 0, this.enoughDays = false,
    this.wakeDelayVsDip, this.wakeDelayVsNap, this.wakeDelayVsRestingHr,
    this.residualVsLatency, this.residualVsTotalSleep});
  final int dayCount;
  final bool enoughDays;
  final double? wakeDelayVsDip, wakeDelayVsNap, wakeDelayVsRestingHr;
  final double? residualVsLatency, residualVsTotalSleep;
}

double residualCaffeineMg(List<CaffeineDose> doses, DateTime bedtime) => 0;
CaffeineTimingSummary caffeineTimingSummary(List<CaffeineDay> days) =>
    const CaffeineTimingSummary();

class TypicalMealTimes {
  static Future<List<int>> load() async => [];
  static Future<void> save(List<int> minutes) async {}
}
