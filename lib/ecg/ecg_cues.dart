// Which ECG haptic cue a capture's state changes play (ecg-features). Pure
// Dart; the controller feeds it every state it publishes and plays the slot it
// returns through `onCue`.
//
// The mapping:
//
//   first `active` of a capture            -> ecg.started (once per capture)
//   completed, status complete             -> ecg.complete
//   completed, status inconclusive (final) -> ecg.inconclusive
//   inconclusiveRetry (another reading     -> ecg.inconclusiveRetry
//     requested)
//   unreadable, failed, or cancelled with  -> ecg.failed
//     reason 'paused' (the app was backgrounded)
//   ANY terminal with cleanupIncomplete,   -> ecg.attention (the SOS rhythm)
//     or failed with reason 'recovery'      (but a dropped link, reason
//                                            'disconnected', stays ecg.failed:
//                                            the app retries the cleanup itself)
//   cancelled by the wearer ('cancelled'), a gesture-owned capture ('gesture'),
//     disposed, disconnected / incompatible / busy before anything started,
//     every non-terminal phase after the first `active` -> no cue
//
// S.O.S. is used ONLY where the phone must be looked at because the band may
// still be recording. It is never used for what a reading found: no category
// and no inconclusive/complete outcome is an alarm.

import '../haptics/builtin_patterns.dart';
import 'ecg_controller.dart';
import 'ecg_models.dart';

class EcgCueTracker {
  bool _started = false;
  EcgCapturePhase? _last;

  /// The slot to play for [s], or null for no cue. Call with every published
  /// state in order; a terminal cue fires once, on entering the terminal phase.
  String? observe(EcgCaptureState s) {
    final entered = _last != s.phase;
    _last = s.phase;
    if (!entered) return null;
    switch (s.phase) {
      case EcgCapturePhase.active:
        if (_started) return null;
        _started = true;
        return kEcgStartedKey;
      case EcgCapturePhase.completed:
        return s.cleanupIncomplete
            ? kEcgAttentionKey
            : s.result == EcgReadingStatus.inconclusive
            ? kEcgInconclusiveKey
            : kEcgCompleteKey;
      case EcgCapturePhase.inconclusiveRetry:
        return s.cleanupIncomplete ? kEcgAttentionKey : kEcgInconclusiveRetryKey;
      case EcgCapturePhase.unreadable:
        return s.cleanupIncomplete ? kEcgAttentionKey : kEcgFailedKey;
      case EcgCapturePhase.failed:
        // A dropped link also leaves the cleanup undone, but the app retries
        // that itself on the next connection and the band cannot be reached
        // now: nothing for the wearer to look at, so it is a plain failure.
        if (s.reason == 'disconnected') return kEcgFailedKey;
        return s.cleanupIncomplete || s.reason == 'recovery'
            ? kEcgAttentionKey
            : kEcgFailedKey;
      case EcgCapturePhase.cancelled:
        if (s.cleanupIncomplete) return kEcgAttentionKey;
        return s.reason == 'paused' ? kEcgFailedKey : null;
      default:
        return null;
    }
  }

  /// Forget the capture (a new one begins).
  void reset() {
    _started = false;
    _last = null;
  }
}
