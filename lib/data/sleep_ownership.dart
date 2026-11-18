// Owner: SleepOwnership defines nap membership and sleep framing boundaries.
// Main ownership stays the caller's explicit day until boundary design B.
import 'dart:math' as math;
import 'day_label.dart';
import 'sleep_editor.dart';

abstract final class SleepOwnership {
  // CLAIM(sleep-ownership-one-rule): naps belong to their local start date
  // [phase2_5-spec §3.7; sleep_block_store_test S11].
  static String dayOf(SleepBlockKind kind, int startSec, int endSec) {
    if (kind == SleepBlockKind.main) {
      throw ArgumentError.value(kind, 'kind', 'main ownership is explicit');
    }
    return dayLabelOf(DateTime.fromMillisecondsSinceEpoch(startSec * 1000));
  }

  static Iterable<String> daysOf(int fromSec, int toSec) sync* {
    if (toSec < fromSec) return;
    var day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(fromSec * 1000));
    final last = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(toSec * 1000));
    while (day.compareTo(last) <= 0) {
      yield day;
      day = dayLabelBefore(day, -1)!;
    }
  }

  // CLAIM(timeline-whole-domain): the containing noon/midnight window extends
  // to include every editable entry [sleep-structural spec §4.2;
  // sleep_shared_timeline_test; sleep_block_store_test S8].
  static ({int start, int end}) framingSpan(String dayId, {
    ({int start, int end})? main,
    List<({int start, int end})> entries = const [],
  }) {
    var start = localDayStartSec(dayId)!;
    var end = localDayEndSec(dayId)!;
    if (main != null) {
      final mainDay = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(main.start * 1000));
      final noon = localDayNoonSec(mainDay)!;
      final noonDay = main.start < noon ? dayLabelBefore(mainDay, 1)! : mainDay;
      start = localDayNoonSec(noonDay)!;
      end = localDayNoonSec(dayLabelBefore(noonDay, -1)!)!;
      if (main.end > end) {
        final midnightEnd = localDayEndSec(mainDay)!;
        if (main.end <= midnightEnd) {
          start = localDayStartSec(mainDay)!;
          end = midnightEnd;
        } else {
          end = main.end;
        }
      }
    }
    for (final entry in [?main, ...entries]) {
      start = math.min(start, entry.start);
      end = math.max(end, entry.end);
    }
    return (start: start, end: end);
  }
}
