import 'package:flutter/foundation.dart';

enum DayTimelineKind { pending, saved, discarded }

sealed class TimelineFilterOutcome {
  const TimelineFilterOutcome();
}

class TimelineFilterApplied extends TimelineFilterOutcome {
  const TimelineFilterApplied();
}

class TimelineFilterRefused extends TimelineFilterOutcome {
  const TimelineFilterRefused();
}

// Owner: this session-only filter never writes a preference.
class TimelineFilter extends ChangeNotifier {
  Set<DayTimelineKind> _kinds = {
    DayTimelineKind.pending,
    DayTimelineKind.saved,
  };
  Set<DayTimelineKind> get kinds => Set.unmodifiable(_kinds);
  TimelineFilterOutcome setKinds(Set<DayTimelineKind> kinds) {
    if (kinds.isEmpty) return const TimelineFilterRefused();
    _kinds = Set.of(kinds);
    notifyListeners();
    return const TimelineFilterApplied();
  }
}
