import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native boot signal for Android headless launches.
///
/// Native only returns true when:
/// - BootReceiver previously marked a pending headless boot
/// - no `MainActivity` is currently attached
///
/// That closes the "first foreground open after reboot" hole where a pending
/// boot flag could otherwise be consumed by a normal UI launch.
bool _platformIsAndroid() => Platform.isAndroid;

class AndroidBootSignal {
  AndroidBootSignal._();

  static const MethodChannel _ch = MethodChannel('openstrap/edge_tracking');

  /// [isAndroid] is a test seam (design 02): CI hosts are not Android, so the
  /// real boot wake could not otherwise be driven.
  static Future<bool> consumePendingHeadlessBoot({
    bool Function() isAndroid = _platformIsAndroid,
  }) async {
    if (!isAndroid()) return false;
    try {
      return await _ch.invokeMethod<bool>('consumeHeadlessBootPending') ??
          false;
    } catch (e) {
      debugPrint('[android-boot-signal] consume failed: $e');
      return false;
    }
  }
}
