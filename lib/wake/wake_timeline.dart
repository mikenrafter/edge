// P2 RED signatures only. Pure projection; no mutable state owner.
import 'wake_orchestrator.dart' show WakeTraceEntry;
import 'wake_outcome.dart';

enum WakeNightEventKind {
  natural,
  repeat,
  gradual,
  alarm,
  snooze,
  snoozeStop,
  ack,
}

class WakeNightEvent {
  const WakeNightEvent({
    required this.kind,
    required this.at,
    this.count,
    this.reason,
  });
  final WakeNightEventKind kind;
  final DateTime at;
  final int? count;
  final String? reason;
}

class WakeBandAlarm {
  const WakeBandAlarm({
    required this.wakeEpochSec,
    required this.at,
    this.code = 57,
  });
  final int wakeEpochSec;
  final DateTime at;
  final int code;
}

class WakeNightTimeline {
  const WakeNightTimeline({
    this.events = const [],
    this.firstFireAt,
    this.ackAt,
    this.timeToWake,
    this.snoozeCount = 0,
    this.dream,
  });
  final List<WakeNightEvent> events;
  final DateTime? firstFireAt, ackAt;
  final Duration? timeToWake;
  final int snoozeCount;
  final WakeDreamResponse? dream;

  static WakeNightTimeline forEpoch({
    required int wakeEpochSec,
    required List<WakeTraceEntry> trace,
    List<WakeBandAlarm> bandAlarms = const [],
    WakeDreamResponse? dream,
  }) => const WakeNightTimeline();
}
