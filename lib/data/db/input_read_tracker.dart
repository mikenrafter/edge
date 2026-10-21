// input_read_tracker.dart — Zone-scoped record of which inputs a computation
// read (design 06 phase 1c).
//
// `InputReads.note(id, scope)` is one line in each tracked `LocalDb` accessor;
// outside a recording zone it does nothing. A recording is explicit:
//
//   final rec = InputReads.begin();
//   try {
//     await runZoned(() => work(), zoneValues: rec.zoneValues);
//   } finally {
//     ids = rec.end();
//   }
//
// There is deliberately no `record(Future Function())` wrapper: a function-typed
// parameter call is something the heavy-calc guard cannot resolve, and the
// caller already owns the closure it hands to `runZoned`.
//
// One owner per recording: the object returned by [InputReads.begin]. The
// recorder lives in the zone, so a nested recording shadows the outer one and
// a read made on another isolate is not seen (the derive's store reads are on
// the main isolate by design; see lib/compute/derive_prepare.dart).

import 'dart:async' show Zone;

/// One recording. Not reusable after [end].
class InputRecording {
  InputRecording._();

  final Set<String> _ids = <String>{};
  bool _open = true;

  /// Pass to `runZoned(..., zoneValues: ...)` so [InputReads.note] finds this
  /// recording from anywhere inside that zone.
  Map<Object?, Object?> get zoneValues => <Object?, Object?>{InputReads._key: this};

  /// Stops the recording and returns the input ids noted inside its zone.
  Set<String> end() {
    _open = false;
    return Set<String>.unmodifiable(_ids);
  }
}

class InputReads {
  const InputReads._();

  static final Object _key = Object();

  /// Starts a recording for one computation.
  static InputRecording begin() => InputRecording._();

  /// Notes that input [id] was read for [scope] (a day label or '').
  /// Ids only: scopes are not kept (the stamp re-reads revisions by range).
  static void note(String id, String scope) {
    final rec = Zone.current[_key];
    if (rec is InputRecording && rec._open) rec._ids.add(id);
  }
}
