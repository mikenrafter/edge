// moment_label.dart — the answer to "what was that marked moment?".
//
// A marked moment is a journal tag `moment HH:mm` on its local day (see
// gestures/moment_stamp.dart). It has no row of its own, so the label lives in
// a side table keyed on the same (date, hhmm). One row per moment: a row with a
// null [label] is a moment the wearer SKIPPED (answered, deliberately unlabelled).

import 'package:flutter/foundation.dart';

@immutable
class MomentLabel {
  const MomentLabel({
    required this.date,
    required this.hhmm,
    this.label,
    this.note,
    required this.answeredAtMs,
  });

  /// 'YYYY-MM-DD', local.
  final String date;

  /// 'HH:mm', local, zero-padded.
  final String hhmm;

  /// A `MomentChoice.id`, or null when the moment was skipped.
  final String? label;

  /// The optional free-text note ("Other"), null when none.
  final String? note;

  /// Epoch ms the answer was given.
  final int answeredAtMs;

  String get key => '$date $hhmm';

  /// Epoch SECONDS of that local wall-clock minute (DST-safe: built from the
  /// calendar fields, never from a day start plus minutes).
  int? get atSec {
    final t = momentLocalTime(date, hhmm);
    return t == null ? null : t.millisecondsSinceEpoch ~/ 1000;
  }
}

/// The LOCAL wall-clock DateTime of a `YYYY-MM-DD` + `HH:mm` pair, or null when
/// either is malformed. Built from calendar fields, never from a day start plus
/// minutes, so a DST day does not shift it.
DateTime? momentLocalTime(String date, String hhmm) {
  final d = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(date);
  final t = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(hhmm);
  if (d == null || t == null) return null;
  return DateTime(int.parse(d[1]!), int.parse(d[2]!), int.parse(d[3]!),
      int.parse(t[1]!), int.parse(t[2]!));
}
