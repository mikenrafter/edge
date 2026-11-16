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
    this.confirmedDelivery = false,
    this.dream,
    this.technologyVersion,
  });
  final WakeNightEventKind kind;
  final DateTime at;
  final int? count;
  final String? reason;
  final int? wakeEpochSec;
  /// Successful transport dispatch or a band-reported alarm. This does not
  /// confirm physical buzzing [AppState._sendWakeHaptic, wake_timeline_test].
  final bool confirmedDelivery;
  final WakeDreamResponse? dream;
  final String? technologyVersion;
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

// Method evidence is shared by answer writes and read projections. A stored
// path label alone never proves that an alert was delivered before the ack.
WakePath? _pathBeforeAck(Iterable<WakeNightEvent> events, DateTime? ack) {
  final kinds = events.where((e) => e.confirmedDelivery && ack != null && !e.at.isAfter(ack))
      .map((e) => e.kind).toSet();
  return kinds.contains(WakeNightEventKind.natural) || kinds.contains(WakeNightEventKind.repeat)
      ? WakePath.natural : kinds.contains(WakeNightEventKind.gradual)
      ? WakePath.gradual : kinds.contains(WakeNightEventKind.alarm) ? WakePath.alarm : null;
}

class WakeNightTimeline {
  const WakeNightTimeline({
    this.events = const [],
    this.deliveries = const [],
    this.firstFireAt,
    this.ackAt,
    this.acknowledgedPath,
    this.timeToWake,
    this.snoozeCount = 0,
    this.dream,
    this.adjustedFor = const {},
  });
  final List<WakeNightEvent> events;
  /// Every successful dispatch, including each Gradual step, for the detailed
  /// summary. [events] retains the legacy first-per-method projection.
  final List<WakeNightEvent> deliveries;
  final Set<String> adjustedFor;

  /// Evidence preceding this projection's selected first acknowledgement.
  final WakePath? acknowledgedPath;

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
          confirmedDelivery: first.confirmedDelivery,
          dream: first.dream,
          technologyVersion: first.technologyVersion,
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
        // A decision is persisted before delivery. Only a successful transport
        // result proves dispatch, not physical buzzing [wake_timeline_test].
        'natural_haptic'
            when e.data['phase'] == 'result' && e.data['result'] == 'sent' =>
          WakeNightEventKind.natural,
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
          confirmedDelivery: kind == WakeNightEventKind.natural ||
              kind == WakeNightEventKind.repeat || kind == WakeNightEventKind.gradual ||
              kind == WakeNightEventKind.alarm,
          dream: kind == WakeNightEventKind.ack ? dream : null,
          technologyVersion: e.data['technologyVersion']?.toString(),
        ),
      );
    }
    for (final alarm in bandAlarms) {
      if (alarm.wakeEpochSec == wakeEpochSec && alarm.code == 57) {
        candidates.add(
          WakeNightEvent(kind: WakeNightEventKind.alarm, at: alarm.at,
            wakeEpochSec: wakeEpochSec, confirmedDelivery: true),
        );
      }
    }
    // The enum order also puts a stop before an acknowledgement at the same
    // instant. Never sort the caller's trace in place.
    candidates.sort((a, b) {
      final time = a.at.compareTo(b.at);
      return time != 0 ? time : a.kind.index.compareTo(b.kind.index);
    });
    final deliveries = <WakeNightEvent>[];
    final reportedAlarms = <DateTime>{};
    for (final e in candidates.where((e) => e.confirmedDelivery)) {
      // The same band alarm can be present in both band_events and its trace.
      // Separate Gradual steps remain separate, even at the same timestamp.
      if (e.kind == WakeNightEventKind.alarm && !reportedAlarms.add(e.at)) continue;
      deliveries.add(e);
    }
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
      if (e.confirmedDelivery) {
        firstFire ??= e.at;
      }
      if (e.kind == WakeNightEventKind.ack) ack = e.at;
      if (e.kind == WakeNightEventKind.snooze) snoozes++;
    }
    // CLAIM(wake-answer-first-ack): an answer survives missing path metadata.
    // Only successful deliveries before this epoch's first ack identify its
    // method; historical labels alone cannot establish one.
    final path = _pathBeforeAck(candidates, ack);
    final response = dream == null || ack == null ? null
        : WakeDreamResponse(answer: dream.answer, path: path, at: dream.at);
    final answeredEvents = [for (final e in events)
      if (e.kind == WakeNightEventKind.ack)
        WakeNightEvent(kind: e.kind, at: e.at, wakeEpochSec: e.wakeEpochSec, dream: response)
      else e];
    return WakeNightTimeline(
      events: List.unmodifiable(answeredEvents),
      deliveries: List.unmodifiable(deliveries),
      firstFireAt: firstFire,
      ackAt: ack,
      acknowledgedPath: path,
      timeToWake: firstFire == null || ack == null || ack.isBefore(firstFire)
          ? null
          : ack.difference(firstFire),
      snoozeCount: snoozes,
      dream: response,
      adjustedFor: {for (final e in trace)
        if (e.wakeEpochSec == wakeEpochSec && e.kind == 'natural')
          for (final label in e.data['adjustedFor'] as List? ?? const [])
            if (label is String) label},
    );
  }
}
