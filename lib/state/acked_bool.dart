// acked_bool.dart — a boolean setting changed with the platform's own
// acknowledgement, ONE WRITE AT A TIME.
//
// For a consent. The write can outlive the screen that asked for it, and a
// failure must put the cache back to the last value the platform CONFIRMED —
// never to something older, and never depending on a screen still being there.
// So there is one instance per key, writes do not overlap (a second request
// while one waits is ignored, and the UI disables the switch on [pending]), and
// the rollback happens here.

import 'package:flutter/foundation.dart';

import 'prefs.dart';

class AckedBool {
  AckedBool._(this.key);

  static final Map<String, AckedBool> _byKey = {};

  /// The one instance for [key].
  static AckedBool forKey(String key) =>
      _byKey.putIfAbsent(key, () => AckedBool._(key));

  final String key;

  /// True while a write waits for its acknowledgement.
  final ValueNotifier<bool> pending = ValueNotifier<bool>(false);

  /// Writes [on] ([write] is `Prefs.setBoolAcked` unless a test passes its own).
  /// Null: ignored, a write is already pending. Otherwise whether the platform
  /// confirmed it; if not (refused or thrown), the cached value goes back to the
  /// one confirmed before this write.
  Future<bool?> set(bool on,
      {Future<bool> Function(String key, bool value)? write}) async {
    if (pending.value) return null;
    // With nothing pending, the cache IS the last confirmed value.
    final confirmed = Prefs.getBool(key, false);
    pending.value = true;
    var ok = false;
    try {
      ok = await (write ?? Prefs.setBoolAcked)(key, on);
    } catch (_) {
      ok = false;
    }
    if (!ok) Prefs.setBool(key, confirmed);
    pending.value = false;
    return ok;
  }
}
