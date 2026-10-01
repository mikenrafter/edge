// moment_stamp.dart — the local date and HH:mm a "mark a moment" tap belongs to.
//
// Uses the event's own time (strap clock when believable, else receipt), never
// the moment the handler happens to run, so a tap replayed from history lands
// on the day and minute it actually happened.

import '../data/day_label.dart';
import 'strap_event.dart';

class MomentStamp {
  const MomentStamp({
    required this.date,
    required this.hhmm,
    required this.timeSource,
  });

  /// 'YYYY-MM-DD', local.
  final String date;

  /// 'HH:mm', local, zero-padded.
  final String hhmm;
  final EventTimeSource timeSource;

  String get tag => 'moment $hhmm';
}

MomentStamp momentStampFor(StrapEvent e) {
  final local = e.effectiveTime.toLocal();
  String two(int x) => x.toString().padLeft(2, '0');
  return MomentStamp(
    date: dayLabelOf(local),
    hhmm: '${two(local.hour)}:${two(local.minute)}',
    timeSource: e.timeSource,
  );
}

/// A copy of [tags] with the stamp's tag appended once.
List<String> withMomentTag(List<String> tags, MomentStamp s) {
  final out = List<String>.of(tags);
  if (!out.contains(s.tag)) out.add(s.tag);
  return out;
}
