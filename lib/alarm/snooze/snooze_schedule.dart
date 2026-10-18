// snooze_schedule.dart — the escalating, erratic re-alarm pattern per snooze.
//
// Pinned by test/alarm_snooze/snooze_schedule_test.dart.
//
// Index is 1-based: the re-alarm that follows the n-th snooze. Dynamics are
// only mf / f / ff. Snooze 1 is the mildest, 3+ the harshest; from there on it
// keeps growing until [cap] and not beyond: at and past the cap the pattern is
// the cap's, and the re-alarm keeps repeating every snooze interval (the
// wearer is always eventually woken; nothing here ends the snooze).

import '../../gestures/pattern_transcript.dart';

const int kSnoozeCapMin = 1;
const int kSnoozeCapMax = 20;
const int kSnoozeCapDefault = 6;

/// Tier 1 (mildest): mf only. Tier 2: mf and f. Tier 3 (harshest): f and ff.
/// Uneven on purpose, so the wearer cannot settle into the rhythm.
const List<String> _tiers = [
  'N4mf R3 N2mf R6 N4mf',
  'N2f R2 N6mf R3 N2f R4 N4f R2 N2mf',
  'N3ff R1 N2f R3 N6ff R2 N1ff R1 N3ff R4 N4f R2 N4ff',
];

/// From snooze 4 on, tier 3 grows by one extra burst per snooze (up to this
/// many), so the pattern keeps getting longer until [SnoozeSchedule.cap]. Five
/// bursts keep the longest pattern at 66 sixteenths, inside the 10 s default
/// runtime cap on the MG, whatever the cap setting.
const int _maxExtraBursts = 5;
const List<int> _extraLengths = [4, 3, 6, 4, 3];

class SnoozeSchedule {
  const SnoozeSchedule({this.cap = kSnoozeCapDefault});

  /// The snooze index at which escalation stops.
  final int cap;

  /// The notes of the re-alarm after snooze [snoozeIndex] (>= 1; lower values
  /// read as 1). Deterministic for a given index.
  List<PatternEntry> reAlarmNotes(int snoozeIndex) =>
      reAlarmCode(snoozeIndex).split(' ').map(PatternEntry.parse).toList();

  /// [reAlarmNotes] as a code string ("N4mf R2 N2f ...").
  String reAlarmCode(int snoozeIndex) {
    final i = (snoozeIndex < 1 ? 1 : snoozeIndex).clamp(1, cap < 1 ? 1 : cap);
    if (i <= 3) return _tiers[i - 1];
    final extra = (i - 3).clamp(0, _maxExtraBursts);
    return [
      _tiers[2],
      for (var k = 0; k < extra; k++) 'R2 N${_extraLengths[k]}ff',
    ].join(' ');
  }

  /// False once [snoozeIndex] is past [cap]: the pattern no longer grows.
  bool escalates(int snoozeIndex) => snoozeIndex <= cap;
}
