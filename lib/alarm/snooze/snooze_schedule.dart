// snooze_schedule.dart — the escalating, erratic re-alarm pattern per snooze.
//
// STUB (red phase). Pinned by test/alarm_snooze/snooze_schedule_test.dart.
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

class SnoozeSchedule {
  const SnoozeSchedule({this.cap = kSnoozeCapDefault});

  /// The snooze index at which escalation stops.
  final int cap;

  /// The notes of the re-alarm after snooze [snoozeIndex] (>= 1; lower values
  /// read as 1). Deterministic for a given index.
  List<PatternEntry> reAlarmNotes(int snoozeIndex) => throw UnimplementedError();

  /// [reAlarmNotes] as a code string ("N4mf R2 N2f ...").
  String reAlarmCode(int snoozeIndex) => throw UnimplementedError();

  /// False once [snoozeIndex] is past [cap]: the pattern no longer grows.
  bool escalates(int snoozeIndex) => throw UnimplementedError();
}
