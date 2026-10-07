// tasker_play.dart — an incoming Tasker request to play something on the band
// (RED phase: the types exist, the parser throws).
//
// Tasker -> band, beside the older BUZZ_STRAP (a numbered pattern). The native
// receiver forwards the intent's extras on the `openstrap/tasker` channel as
// the method `tasker_play` with a map holding EITHER
//   slot     a Tasker slot number 1..6 (int, or a numeric string), or a haptic
//            cue slot key ('tasker.3', 'breath.done', ...);
//   pattern  a stored pattern's id ('sys.preset.sos', a user pattern's id).
// Anything else is not a request: it is ignored and logged by the handler.

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
TaskerPlayRequest? parseTaskerPlay(Object? args) =>
    throw UnimplementedError('parseTaskerPlay');
