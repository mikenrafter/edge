// P2 RED data contracts. DbWakeJournal will own persisted outcomes.
enum WakePath { natural, gradual, alarm }

enum DreamAnswer { dream, normal }

enum WakeSubstance { alcohol, cannabis }

class WakeDreamResponse {
  const WakeDreamResponse({
    required this.answer,
    required this.path,
    required this.at,
  });
  final DreamAnswer answer;
  final WakePath path;
  final DateTime at;
}

class WakeNightOutcome {
  const WakeNightOutcome({
    required this.dayId,
    required this.wakeEpochSec,
    this.timeToWake,
    this.snoozeCount,
    this.dream,
    this.recovery,
    this.mainSleepTst,
    this.substance,
    this.confounderTrack = 0,
    this.contextKnown = true,
  });
  // Canonical main-sleep day identity; several alarm epochs can share it.
  final String dayId;
  final int wakeEpochSec;
  final Duration? timeToWake;
  final int? snoozeCount;
  final WakeDreamResponse? dream;
  final double? recovery;
  final Duration? mainSleepTst;
  final WakeSubstance? substance;
  final int confounderTrack;
  final bool contextKnown;
  int get track =>
      confounderTrack | (substance == WakeSubstance.alcohol ? 1 : 0);
}
