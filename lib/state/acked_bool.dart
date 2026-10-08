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

/// The state is published here, and a screen renders THIS, never a copy it took
/// at init: [value] (the confirmed value, or the pending write's optimistic
/// one), [pending], and [failed] (the last write was refused; cleared by the
/// next success). A screen opened mid-write, or a second one, shows the same.
class AckedBool extends ChangeNotifier {
  AckedBool._(this.key);

  static final Map<String, AckedBool> _byKey = {};

  /// The one instance for [key].
  static AckedBool forKey(String key) =>
      _byKey.putIfAbsent(key, () => AckedBool._(key));

  /// Test isolation: forget every instance (and its pending/failed state).
  @visibleForTesting
  static void resetForTest() => _byKey.clear();

  final String key;

  bool _pending = false;
  bool _failed = false;
  bool _optimistic = false;

  /// True while a write waits for its acknowledgement.
  bool get pending => _pending;

  /// The last write was refused or threw; the next success clears it.
  bool get failed => _failed;

  /// What to show: the pending write's value while it waits, else the confirmed
  /// one (with nothing pending, the cache IS the last confirmed value).
  bool get value => _pending ? _optimistic : Prefs.getBool(key, false);

  /// Writes [on] ([write] is `Prefs.setBoolAcked` unless a test passes its own).
  /// Null: ignored, a write is already pending. Otherwise whether the platform
  /// confirmed it; if not (refused or thrown), the cached value goes back to the
  /// one confirmed before this write.
  Future<bool?> set(bool on,
      {Future<bool> Function(String key, bool value)? write}) async {
    if (_pending) return null;
    final confirmed = Prefs.getBool(key, false);
    _optimistic = on;
    _pending = true;
    notifyListeners();
    var ok = false;
    try {
      ok = await (write ?? Prefs.setBoolAcked)(key, on);
    } catch (_) {
      ok = false;
    }
    Prefs.setBool(key, ok ? on : confirmed);
    _failed = !ok;
    _pending = false;
    notifyListeners();
    return ok;
  }
}
