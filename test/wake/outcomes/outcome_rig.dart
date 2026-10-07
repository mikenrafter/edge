// Shared builders for the wake-outcome tests: trace rows in the exact shapes
// lib/wake/wake_orchestrator.dart writes them (data maps copied from its
// `_trace` call sites), and outcome fixtures. Every time is epoch seconds.

import 'package:openstrap_edge/wake/outcomes/wake_outcome.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';

/// T for most tests. Arbitrary; nothing here depends on the local timezone.
const int kT = 1780000000;

WakeTraceEntry row(int wake, int sec, String kind, Map<String, Object?> data) =>
    WakeTraceEntry(
        wakeEpochSec: wake, atMs: sec * 1000, kind: kind, data: data);

/// A Natural fire that reached the band: the forced 'natural' row with
/// reason 'fire', the request row, and the delivered result row at [fireSec]
/// (the fire time). Request and 'natural' rows land two seconds earlier.
List<WakeTraceEntry> naturalFire(
  int wake,
  int fireSec, {
  String stage = 'rem',
  double evidenceAgeMs = 30000,
  // RED-EDIT (P2 band delivery): the orchestrator's `delivered` is
  // WakeHapticResult.delivered = the transport's TARGETS ('band', 'phone'),
  // not an event id. The old fixture put the event id there, which hid that the
  // assembler never reads it. Default is the band-reached case.
  List<String> targets = const ['band'],
}) =>
    [
      row(wake, fireSec - 2, 'natural', {
        'reason': 'fire',
        'samples': 'current',
        'stage': stage,
        'confidence': 0.5,
        'runSec': 150.0,
        'evidenceAgeMs': evidenceAgeMs,
        'abstention': null,
      }),
      row(wake, fireSec - 2, 'natural_haptic', {
        'phase': 'request',
        'eventId': 'wake:natural:$wake',
        'stage': stage,
        'confidence': 0.5,
        'runSec': 150.0,
      }),
      row(wake, fireSec, 'natural_haptic', {
        'phase': 'result',
        'eventId': 'wake:natural:$wake',
        'result': 'sent',
        'delivered': targets, // RED-EDIT: was ['wake:natural:$wake']
        'suppression': null,
        'error': null,
      }),
    ];

/// A Natural fire whose haptic never reached the band.
List<WakeTraceEntry> naturalNotDelivered(int wake, int atSec) => [
      row(wake, atSec - 2, 'natural_haptic', {
        'phase': 'request',
        'eventId': 'wake:natural:$wake',
        'stage': 'rem',
        'confidence': 0.5,
        'runSec': 150.0,
      }),
      row(wake, atSec, 'natural_haptic', {
        'phase': 'result',
        'eventId': 'wake:natural:$wake',
        'result': 'notDelivered',
        'delivered': <String>[],
        'suppression': null,
        'error': 'TimeoutException',
      }),
    ];

WakeTraceEntry repeatStart(int wake, int sec) => row(wake, sec,
    'natural_repeat', {'phase': 'start', 'retryWaitSec': 5});

WakeTraceEntry repeatStop(int wake, int sec, String reason) =>
    row(wake, sec, 'natural_repeat', {
      'phase': 'stop',
      'reason': reason,
      'delivered': 3,
      'notDelivered': 0,
    });

WakeTraceEntry gradualRow(int wake, int sec, int index, String result,
        // RED-EDIT (P2 band delivery): `delivered` holds transport targets, as
        // in the orchestrator, not the event id the fixture used to put there.
        {List<String> targets = const ['band']}) =>
    row(wake, sec, 'gradual', {
      'index': index,
      'eventId': 'wake:gradual:$wake:$index',
      'result': result,
      'delivered': result == 'sent' ? targets : <String>[],
      'suppression': null,
      'error': null,
    });

WakeTraceEntry fallbackRow(int wake, int sec,
        {bool armed = true, bool confirmed = true, bool rearmed = false}) =>
    row(wake, sec, 'fallback',
        {'armed': armed, 'confirmed': confirmed, 'rearmed': rearmed});

/// The once-per-run 'plan' row (wake_orchestrator.dart, `planLogged`);
/// `naturalMinutes` is the configured Natural window for that night.
WakeTraceEntry planRow(int wake, int sec, {int naturalMinutes = 60}) =>
    row(wake, sec, 'plan', {
      'configuration': 'natural',
      'naturalMinutes': naturalMinutes,
      'gradualMinutes': 0,
      'gradualPattern': 'ramp',
      'gradualCadenceSec': 60,
      'upgradePending': false,
      'wakeAtMs': wake * 1000,
      'utcOffsetMin': 0,
    });

WakeTraceEntry ackRow(int wake, int sec) => row(wake, sec, 'ack',
    {'cancelNative': false, 'cancelled': null, 'fallbackArmed': true});

WakeTraceEntry closedRow(int wake, int sec) => row(wake, sec, 'closed',
    {'naturalFired': false, 'gradualSteps': 0, 'acknowledged': false});

/// A finished outcome for store, policy and screen tests.
WakeOutcome outcome(
  int wakeSec, {
  WakeFiredBy firedBy = WakeFiredBy.natural,
  double? minutesBeforeT = 20,
  String? stageAtFire = 'rem',
  int? stageAgeSec = 30,
  bool delivered = true,
  int? grogginess,
  List<WakeExclusion> exclusions = const [],
  Map<WakeResponseKind, int?>? latencySec,
  // The configured Natural window recorded for that night. WakeOutcome has no
  // such field yet, so it goes in through fromJson ('configuredWindowMinutes',
  // nullable int): this compiles now and keeps working once the field exists.
  int? configuredWindowMinutes,
}) {
  final built = WakeOutcome(
      wakeSec: wakeSec,
      firedBy: firedBy,
      firedAtSec: minutesBeforeT == null
          ? null
          : wakeSec - (minutesBeforeT * 60).round(),
      stageAtFire: stageAtFire,
      stageAgeSec: stageAgeSec,
      delivered: delivered,
      latencySec: latencySec ??
          const {
            WakeResponseKind.deliberateAck: null,
            WakeResponseKind.appInteraction: null,
            WakeResponseKind.movement: null,
          },
      grogginess: grogginess,
      minutesBeforeT: minutesBeforeT,
      exclusions: exclusions,
    );
  if (configuredWindowMinutes == null) return built;
  return WakeOutcome.fromJson({
    ...built.toJson(),
    'configuredWindowMinutes': configuredWindowMinutes,
  });
}
