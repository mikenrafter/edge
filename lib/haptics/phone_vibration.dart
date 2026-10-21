// The phone's side of a haptic preview: one vibration of a given length.
//
// Isolated here (and the `vibration` package with it) so it can be reverted
// to the fixed-length HapticFeedback buzz without touching the scheduler.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

import 'example_playback.dart' show HapticCancel;

/// What the phone can do. A seam so tests drive the transport without a
/// platform channel.
abstract class PhoneVibrator {
  /// Can it vibrate for a chosen length? Asked once per process.
  Future<bool> supportsDuration();
  Future<void> vibrate(int ms);
  Future<void> cancel();

  /// The platform's fixed-length buzz.
  Future<void> fixedBuzz();
}

class _PluginVibrator implements PhoneVibrator {
  @override
  Future<bool> supportsDuration() => Vibration.hasCustomVibrationsSupport();
  @override
  Future<void> vibrate(int ms) => Vibration.vibrate(duration: ms);
  @override
  Future<void> cancel() => Vibration.cancel();
  @override
  Future<void> fixedBuzz() => HapticFeedback.vibrate();
}

/// Replaced by tests only.
PhoneVibrator phoneVibrator = _PluginVibrator();

// The vibration an example started and may stop: only that one. A later
// vibration (its own or another example's) takes the ownership, so a Stop can
// never cut off something it did not start; and once the hold has run out the
// vibration is over and there is nothing left to cancel.
class _Active {
  _Active(this.owner, this.endsAt);
  final HapticCancel owner;
  final DateTime endsAt;
}

_Active? _active;

// Whether the phone vibrates for a chosen length: asked once per process (per
// vibrator, so a test's fake gets its own answer).
Future<bool>? _capability;
PhoneVibrator? _capabilityOf;

Future<bool> _supportsDuration() {
  if (!identical(_capabilityOf, phoneVibrator)) {
    _capabilityOf = phoneVibrator;
    _capability = phoneVibrator.supportsDuration();
  }
  return _capability!;
}

/// Vibrates the phone for [hold]. Where the device cannot vibrate for a given
/// length (iOS without CoreHaptics, no vibrator, a plugin error) it falls back
/// to the platform's fixed-length buzz. With [cancel]: nothing starts once it
/// is cancelled (also while the capability is being asked), and cancelling
/// while this vibration runs stops it.
Future<void> vibratePhoneFor(Duration hold, {HapticCancel? cancel}) async {
  final vibrator = phoneVibrator;
  try {
    if (hold > Duration.zero && await _supportsDuration()) {
      if (cancel?.cancelled == true) return;
      final mine = cancel == null ? null : _Active(cancel, clock.now().add(hold));
      _active = mine;
      if (mine != null) {
        unawaited(cancel!.whenCancelled.then((_) {
          if (identical(_active, mine) && clock.now().isBefore(mine.endsAt)) {
            _active = null;
            return vibrator.cancel().catchError((Object _) {});
          }
        }));
      }
      await vibrator.vibrate(hold.inMilliseconds);
      return;
    }
  } catch (_) {
    // Fall through to the fixed buzz.
  }
  if (cancel?.cancelled == true) return;
  await vibrator.fixedBuzz();
}
