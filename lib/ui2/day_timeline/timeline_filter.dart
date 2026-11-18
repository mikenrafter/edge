import 'package:flutter/foundation.dart';
enum DayTimelineKind { pending, saved, discarded }
sealed class TimelineFilterOutcome { const TimelineFilterOutcome(); }
class TimelineFilterApplied extends TimelineFilterOutcome { const TimelineFilterApplied(); }
class TimelineFilterRefused extends TimelineFilterOutcome { const TimelineFilterRefused(); }
// Owner: this session-only filter never writes a preference.
class TimelineFilter extends ChangeNotifier {
  Set<DayTimelineKind> get kinds => const {DayTimelineKind.pending, DayTimelineKind.saved};
  TimelineFilterOutcome setKinds(Set<DayTimelineKind> kinds) => const TimelineFilterRefused();
}
