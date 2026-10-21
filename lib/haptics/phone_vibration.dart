// The phone's side of a haptic preview: one vibration of a given length.
//
// Isolated here (and the `vibration` package with it) so it can be reverted
// to the fixed-length HapticFeedback buzz without touching the scheduler.

import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

/// Vibrates the phone for [hold]. Where the device cannot vibrate for a given
/// length (iOS without CoreHaptics, no vibrator, a plugin error) it falls back
/// to the platform's fixed-length buzz.
Future<void> vibratePhoneFor(Duration hold) async {
  try {
    if (hold > Duration.zero && await Vibration.hasCustomVibrationsSupport()) {
      await Vibration.vibrate(duration: hold.inMilliseconds);
      return;
    }
  } catch (_) {
    // Fall through to the fixed buzz.
  }
  await HapticFeedback.vibrate();
}
