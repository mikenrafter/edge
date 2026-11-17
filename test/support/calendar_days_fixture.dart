import 'package:openstrap_edge/compute/substrate.dart';
import 'day_stream_fixture.dart';

// A populated midnight-crossing substrate, including beat and gravity columns.
Substrate calendarDaysFixture() {
  final start = DateTime(2026, 10, 14, 22).millisecondsSinceEpoch ~/ 1000;
  return substrateOf(
    synthBeats(SynthBeats(startSec: start, seconds: 4 * 3600,
      gapPerHour: 0, ectopicPerMin: 0, missedPerMin: 0, extraPerMin: 0,
      noiseRunPerMin: 0)),
    synthAccel(73, start, start + 4 * 3600, gapPerHour: 0),
  );
}
