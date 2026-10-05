// The touch timings the counter and session timelines in these tests were
// written against: start 300 ms, gap 200 ms, confirm 200 ms, extra sensitive
// off. The app's defaults and ranges have since moved (start 200, gap 150,
// confirm 750, extra sensitive on; the confirm range no longer reaches 200), so
// those timelines state their numbers here instead of relying on the defaults.
// Values are NOT range-checked: the counter and session only read them.

import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';

class LegacyEcgThresholds extends EcgTapThresholds {
  LegacyEcgThresholds({
    int startMs = 300,
    int gapMs = 200,
    int confirmMs = 200,
    super.extraSensitive = false,
    super.tolerantStartup,
    super.fallbackToDoubleTap,
  })  : _startMs = startMs,
        _gapMs = gapMs,
        _confirmMs = confirmMs;

  final int _startMs, _gapMs, _confirmMs;

  @override
  int get startMs => _startMs;
  @override
  int get gapMs => _gapMs;
  @override
  int get confirmMs => _confirmMs;

  @override
  EcgTapThresholds copyWith({
    int? startMs,
    int? gapMs,
    int? confirmMs,
    bool? extraSensitive,
    bool? tolerantStartup,
    bool? fallbackToDoubleTap,
  }) =>
      LegacyEcgThresholds(
        startMs: startMs ?? this.startMs,
        gapMs: gapMs ?? this.gapMs,
        confirmMs: confirmMs ?? this.confirmMs,
        extraSensitive: extraSensitive ?? this.extraSensitive,
        tolerantStartup: tolerantStartup ?? this.tolerantStartup,
        fallbackToDoubleTap: fallbackToDoubleTap ?? this.fallbackToDoubleTap,
      );
}
