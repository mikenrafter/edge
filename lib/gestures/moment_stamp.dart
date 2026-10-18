// moment_stamp.dart — the local date and HH:mm a "mark a moment" tap belongs to.
//
// Uses the event's own time (strap clock when believable, else receipt), never
// the moment the handler happens to run, so a tap replayed from history lands
// on the day and minute it actually happened.

import '../data/day_label.dart';
import 'moment_follow_ups.dart' show wallMinuteIsAmbiguous;
import 'strap_event.dart';

class MomentStamp {
  const MomentStamp({
    required this.date,
    required this.hhmm,
    required this.timeSource,
    this.epochSec = 0,
    this.ambiguous = false,
  });

  /// Absolute time of the tap (epoch seconds).
  final int epochSec;

  /// The wall-clock minute happened twice that day (clocks went back).
  final bool ambiguous;

  /// 'YYYY-MM-DD', local.
  final String date;

  /// 'HH:mm', local, zero-padded.
  final String hhmm;
  final EventTimeSource timeSource;

  String get tag => 'moment $hhmm';

  /// Only for a mark in a repeated hour: its absolute time, so two marks on
  /// either side of the clock change can still be ordered and measured.
  String get absoluteTag => 'moment-at $hhmm $epochSec';
}

MomentStamp momentStampFor(StrapEvent e, {bool Function(DateTime)? isAmbiguous}) {
  final local = e.effectiveTime.toLocal();
  String two(int x) => x.toString().padLeft(2, '0');
  return MomentStamp(
    date: dayLabelOf(local),
    hhmm: '${two(local.hour)}:${two(local.minute)}',
    timeSource: e.timeSource,
    epochSec: local.millisecondsSinceEpoch ~/ 1000,
    ambiguous: (isAmbiguous ?? wallMinuteIsAmbiguous)(local),
  );
}

/// A copy of [tags] with the stamp's tag appended once.
List<String> withMomentTag(List<String> tags, MomentStamp s) {
  final out = List<String>.of(tags);
  if (!out.contains(s.tag)) out.add(s.tag);
  if (s.ambiguous && !out.contains(s.absoluteTag)) out.add(s.absoluteTag);
  return out;
}
