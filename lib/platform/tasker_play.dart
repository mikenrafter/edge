// tasker_play.dart — an incoming Tasker request to play something on the band.
//
// Tasker -> band, beside the older BUZZ_STRAP (a numbered pattern). The native
// receiver forwards the intent's extras on the `openstrap/tasker` channel as
// the method `tasker_play` with a map holding EITHER
//   slot     a Tasker slot number 1..6 (int, or a numeric string), or a haptic
//            slot key ('tasker.3', 'breath.done', 'alert.water', ...);
//   pattern  a stored pattern's id ('sys.preset.sos', a user pattern's id).
// Anything else is not a request: it is ignored and logged by the handler.

import '../haptics/haptic_slots.dart';

/// What Tasker asked to be played.
sealed class TaskerPlayRequest {
  const TaskerPlayRequest();
}

/// A haptic slot, by its key (`tasker.1` .. `tasker.6` for a numbered slot).
final class TaskerSlotPlay extends TaskerPlayRequest {
  const TaskerSlotPlay(this.slotKey);
  final String slotKey;
}

/// A stored pattern, by id. Whether it exists is decided when it plays.
final class TaskerPatternPlay extends TaskerPlayRequest {
  const TaskerPatternPlay(this.patternId);
  final String patternId;
}

/// The request in a `tasker_play` call's arguments, or null when they name
/// neither a known slot nor a pattern id (a slot number outside 1..6, an
/// unknown slot key, an empty id, arguments that are not a map).
TaskerPlayRequest? parseTaskerPlay(Object? args) {
  if (args is! Map) return null;
  final slot = args['slot'];
  if (slot != null) {
    final n = slot is int
        ? slot
        : slot is String
            ? int.tryParse(slot)
            : null;
    if (n != null) {
      return n >= 1 && n <= kTaskerSlotCount
          ? TaskerSlotPlay(taskerSlotKey(n))
          : null;
    }
    // Any slot on the Haptics screen, by its key.
    return slot is String && isKnownSlot(slot) ? TaskerSlotPlay(slot) : null;
  }
  final pattern = args['pattern'];
  return pattern is String && pattern.isNotEmpty
      ? TaskerPatternPlay(pattern)
      : null;
}
