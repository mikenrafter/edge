// Which ECG haptic cue a capture's state changes play (ecg-features). Pure
// Dart; the controller feeds it every state it publishes and plays the slot it
// returns through `onCue`.
//
// RED STUB: throws until the green phase. The mapping the tests pin:
//
//   first `active` of a capture            -> ecg.started (once per capture)
//   completed, status complete             -> ecg.complete
//   completed, status inconclusive (final) -> ecg.inconclusive
//   inconclusiveRetry (another reading     -> ecg.inconclusiveRetry
//     requested)
//   unreadable, failed, or cancelled with  -> ecg.failed
//     reason 'paused' (the app was backgrounded)
//   ANY terminal with cleanupIncomplete,   -> ecg.attention (the SOS rhythm)
//     or failed with reason 'recovery'
//   cancelled by the wearer ('cancelled'), a gesture-owned capture ('gesture'),
//     disposed, disconnected / incompatible / busy before anything started,
//     every non-terminal phase after the first `active` -> no cue
//
// S.O.S. is used ONLY where the phone must be looked at because the band may
// still be recording. It is never used for what a reading found: no category
// and no inconclusive/complete outcome is an alarm.

import 'ecg_controller.dart';

class EcgCueTracker {
  /// The slot to play for [s], or null for no cue. Call with every published
  /// state in order; a terminal cue fires once, on entering the terminal phase.
  String? observe(EcgCaptureState s) =>
      throw UnimplementedError('EcgCueTracker.observe');

  /// Forget the capture (a new one begins).
  void reset() => throw UnimplementedError('EcgCueTracker.reset');
}
