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
    this.caffeineMg,
    this.metricValue,
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

  /// Explicit amount recorded for this moment; historic daily totals stay null.
  final double? caffeineMg;

  /// What this answer actually added to its dose field's day total (the amount
  /// after any clamp; 0 when it added nothing), so an edit can take exactly
  /// that back. Null on an answer saved before this was kept: what it added is
  /// not known.
  final double? metricValue;

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

/// Why a saved answer could not be changed.
enum MomentChangeFailure {
  /// The saved answer is a dose saved before the amount it added was kept, so
  /// taking it back would be a guess. Nothing was written.
  priorAmountUnknown,

  /// The database refused a write; everything was rolled back.
  storage,
}

/// The outcome of `LocalDb.changeMomentAnswer`. Every case other than
/// [MomentChanged] leaves the database exactly as it was.
sealed class MomentAnswerChange {
  const MomentAnswerChange();
}

/// The answer was replaced; [after] is the stored row.
final class MomentChanged extends MomentAnswerChange {
  const MomentChanged(this.after);
  final MomentLabel after;
}

/// There is no saved answer at that minute (deleted since the editor opened).
final class MomentNotFound extends MomentAnswerChange {
  const MomentNotFound();
}

/// The saved answer is no longer the one the editor was opened on (changed
/// from another screen or an earlier tap); [current] is what is stored now.
final class MomentStale extends MomentAnswerChange {
  const MomentStale(this.current);
  final MomentLabel current;
}

/// The change was refused or failed; see [reason]. [error] is the database
/// error for [MomentChangeFailure.storage].
final class MomentChangeFailed extends MomentAnswerChange {
  const MomentChangeFailed(this.reason, [this.error]);
  final MomentChangeFailure reason;
  final Object? error;
}
