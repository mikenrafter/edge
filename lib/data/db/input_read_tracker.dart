// input_read_tracker.dart — Zone-scoped record of which inputs a computation
// read (design 06 phase 1c). RED-PHASE STUB: records nothing.
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

/// One recording. Not reusable after [end].
class InputRecording {
  InputRecording._();

  /// Pass to `runZoned(..., zoneValues: ...)` so [InputReads.note] finds this
  /// recording from anywhere inside that zone.
  Map<Object?, Object?> get zoneValues => const <Object?, Object?>{};

  /// Stops the recording and returns the input ids noted inside its zone.
  Set<String> end() => <String>{};
}

class InputReads {
  const InputReads._();

  /// Starts a recording for one computation.
  static InputRecording begin() => InputRecording._();

  /// Notes that input [id] was read for [scope] (a day label or '').
  static void note(String id, String scope) {}
}
