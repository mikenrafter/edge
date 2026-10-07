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
  int? get atSec => throw UnimplementedError('MomentLabel.atSec');
}
