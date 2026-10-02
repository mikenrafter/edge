// ecg_tap_begin.dart — start the ECG stream for a tap gesture without ever
// outliving the gesture or touching an ECG the gesture did not start (review
// finding G).
//
// Future.timeout() abandons the wait, not the work. The session gives up on a
// slow start (beginTimeout) and finishes, but the start can still be awaiting
// the wrist lookup or the controller's own begin(), and would then switch the
// band's raw ECG on for a gesture that no longer exists, unconsumed until the
// controller's capture limit. So:
//  * [isCurrent] (the session generation) is checked after EVERY await;
//  * the capture is identified by the controller's capture epoch, read in the
//    same synchronous step that starts it, so a capture that was cancelled and
//    replaced (the user opened the ECG screen) is never mistaken for ours;
//  * a start that completes for a dead gesture stops the capture it started,
//    and only that one.
// Pure: every effect is injected, so the ordering is testable without a band.

import '../ecg/ecg_models.dart' show EcgWrist;

/// True when THIS call started a capture and the gesture is still current.
/// False (with a line for the Device lab) in every other case; throws only what
/// [begin] throws.
Future<bool> beginEcgForTap({
  required bool Function() isCurrent,
  required bool Function() isCapturing,
  required Future<EcgWrist?> Function() lookupWrist,
  required Future<void> Function(EcgWrist wrist) begin,
  required int Function() captureEpoch,
  required Future<void> Function() cancel,
  void Function(String line)? note,
}) async {
  if (isCapturing()) return false; // the ECG screen is mid-reading
  final wrist = await lookupWrist();
  if (!isCurrent()) {
    note?.call('The gesture ended while the wrist was being looked up. '
        'No ECG stream was started.');
    return false;
  }
  if (wrist == null) {
    note?.call('No wrist remembered. Take one ECG reading first so the lab '
        'knows which wrist the band is on.');
    return false;
  }
  if (isCapturing()) {
    // Someone started an ECG while the wrist was being looked up. begin() is
    // single-flight, so calling it would "succeed" on THEIR capture.
    note?.call('Another ECG started while the wrist was being looked up. '
        'Leaving it alone.');
    return false;
  }
  final started = begin(wrist); // its synchronous part takes the capture
  final epoch = captureEpoch();
  await started;
  final ours = isCapturing() && captureEpoch() == epoch;
  if (!isCurrent()) {
    if (ours) {
      note?.call('The gesture ended before the ECG stream finished starting. '
          'The late stream was stopped.');
      await cancel();
    } else {
      note?.call('The gesture ended while the ECG stream was starting; the '
          'capture is not this gesture\'s, so it was left alone.');
    }
    return false;
  }
  return ours;
}
