// Pure observed-night projection. No mutable state owner.
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
    this.wakeEpochSec,
  });
  final WakeNightEventKind kind;
  final DateTime at;
  final int? count;
  final String? reason;
  final int? wakeEpochSec;
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

  /// Display projection only. The observed history remains available in [events].
  List<WakeNightEvent> get collapsedEvents {
    final groups = <(int?, WakeNightEventKind), List<WakeNightEvent>>{};
    for (final e in events) {
      final kind = e.kind == WakeNightEventKind.repeat
          ? WakeNightEventKind.natural
          : e.kind;
      groups.putIfAbsent((e.wakeEpochSec, kind), () => []).add(e);
    }
    final out = <WakeNightEvent>[];
    for (final entry in groups.entries) {
      final observations = entry.value..sort((a, b) => a.at.compareTo(b.at));
      final first = observations.first;
      final kind =
          entry.key.$2 == WakeNightEventKind.natural &&
              !observations.any((e) => e.kind == WakeNightEventKind.natural)
          ? WakeNightEventKind.repeat
          : entry.key.$2;
      out.add(
        WakeNightEvent(
          kind: kind,
          at: first.at,
          wakeEpochSec: first.wakeEpochSec,
          reason: first.reason,
          count: observations.length,
        ),
      );
    }
    // Stable insertion order resolves simultaneous stop/ack observations.
    out.sort((a, b) {
      final time = a.at.compareTo(b.at);
      return time != 0 ? time : a.kind.index.compareTo(b.kind.index);
    });
    return List.unmodifiable(out);
  }
  final DateTime? firstFireAt, ackAt;
  final Duration? timeToWake;
  final int snoozeCount;
  final WakeDreamResponse? dream;

  static WakeNightTimeline forEpoch({
    required int wakeEpochSec,
    required List<WakeTraceEntry> trace,
    List<WakeBandAlarm> bandAlarms = const [],
    WakeDreamResponse? dream,
  }) {
    final candidates = <WakeNightEvent>[];
    for (final e in trace) {
      if (e.wakeEpochSec != wakeEpochSec) continue;
      final kind = switch (e.kind) {
        'natural' when e.data['reason'] == 'fire' => WakeNightEventKind.natural,
        'natural_repeat'
            when e.data['phase'] == 'result' && e.data['result'] == 'sent' =>
          WakeNightEventKind.repeat,
        'gradual' when e.data['result'] == 'sent' => WakeNightEventKind.gradual,
        'fallback' when e.data['fired'] == true => WakeNightEventKind.alarm,
        'snooze' => WakeNightEventKind.snooze,
        'snooze_stop' => WakeNightEventKind.snoozeStop,
        'ack' => WakeNightEventKind.ack,
        _ => null,
      };
      if (kind == null) continue;
      candidates.add(
        WakeNightEvent(
          kind: kind,
          wakeEpochSec: wakeEpochSec,
          at: DateTime.fromMillisecondsSinceEpoch(e.atMs, isUtc: true),
          count: (e.data['count'] as num?)?.toInt(),
          reason: e.data['reason'] as String?,
        ),
      );
    }
    for (final alarm in bandAlarms) {
      if (alarm.wakeEpochSec == wakeEpochSec && alarm.code == 57) {
        candidates.add(
          WakeNightEvent(kind: WakeNightEventKind.alarm, at: alarm.at,
            wakeEpochSec: wakeEpochSec),
        );
      }
    }
    // The enum order also puts a stop before an acknowledgement at the same
    // instant. Never sort the caller's trace in place.
    candidates.sort((a, b) {
      final time = a.at.compareTo(b.at);
      return time != 0 ? time : a.kind.index.compareTo(b.kind.index);
    });
    final firstOnly = <WakeNightEventKind>{};
    final events = <WakeNightEvent>[];
    DateTime? firstFire, ack;
    var snoozes = 0;
    for (final e in candidates) {
      switch (e.kind) {
        case WakeNightEventKind.natural:
        case WakeNightEventKind.gradual:
        case WakeNightEventKind.alarm:
        case WakeNightEventKind.ack:
          if (!firstOnly.add(e.kind)) continue;
        case WakeNightEventKind.repeat:
        case WakeNightEventKind.snooze:
        case WakeNightEventKind.snoozeStop:
          break;
      }
      events.add(e);
      if (e.kind == WakeNightEventKind.natural ||
          e.kind == WakeNightEventKind.gradual ||
          e.kind == WakeNightEventKind.alarm) {
        firstFire ??= e.at;
      }
      if (e.kind == WakeNightEventKind.ack) ack = e.at;
      if (e.kind == WakeNightEventKind.snooze) snoozes++;
    }
    return WakeNightTimeline(
      events: List.unmodifiable(events),
      firstFireAt: firstFire,
      ackAt: ack,
      timeToWake: firstFire == null || ack == null || ack.isBefore(firstFire)
          ? null
          : ack.difference(firstFire),
      snoozeCount: snoozes,
      dream: dream,
    );
  }
}
