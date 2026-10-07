// time_buzz.dart — the "Tell the time" band gesture action: the current local
// time as a rhythm of buzzes. Pure Dart: no clock, no BLE, no storage.
//
// One encoder, [encodeTime], turns a local wall-clock time into a list of
// [TimeBuzzElement]s. Everything else reads that list: the band plays it
// ([toBuzzChunks]), the budget counts it ([bandCommandsFor]) and the settings
// screen draws it ([renderTimeBuzz]), so the worked examples shown to the
// wearer can never drift from what the band does.
//
// Modes (see [TimeBuzzMode]). Hour = the real 12-hour clock hour 1..12 (00:xx
// and 12:xx are 12). Quarters = round(minute / 15) clamped to 0..4, played as
// clicks; :53 and later is 4 quarters and is never rolled into the next hour.
// No quarters: no clicks and no trailing pause.
//   count   the hour as N buzzes (AM short, PM long), a pause, the quarter clicks.
//   binary  the hour as 4 bits MSB first (long = 1, short = 0), a pause, one
//           AM/PM marker (click = AM, long = PM), a pause, the quarter clicks.
//   morse   the hour's decimal digits in Morse (dot = short, dash = long), a
//           pause between digits (the letter gap), a pause, "A" (.-) or "P"
//           (.--.), a pause, the quarter clicks.
// Between two buzzes of one group the element is [TimeBuzzElement.gap]; between
// groups (and between Morse digits) it is [TimeBuzzElement.pause], 1 s.
//
// Only the wall-clock fields of the DateTime are read (hour, minute): never
// a time zone conversion, never 86400 s arithmetic, never seconds.

import '../haptics/haptic_profile.dart';
import '../notify/buzz_sequence.dart';

enum TimeBuzzMode { count, binary, morse }

enum TimeBuzzElement {
  /// A short hour buzz (AM in count mode, a 0 bit, a Morse dot).
  short,

  /// A long hour buzz (PM in count mode, a 1 bit, a Morse dash, the PM marker
  /// of binary mode).
  long,

  /// The lighter quarter click (and the AM marker of binary mode).
  click,

  /// The silence between two elements of one group.
  gap,

  /// The 1 s silence between groups (and between Morse digits).
  pause,
}

/// How long a [TimeBuzzElement.pause] is.
const int kTimeBuzzPauseMs = 1000;

/// [localTime]'s wall-clock hour and minute as buzz elements in [mode].
List<TimeBuzzElement> encodeTime(DateTime localTime, TimeBuzzMode mode) =>
    throw UnimplementedError();

/// The elements as glyphs for the settings screen: ▬ long, · short, • click,
/// │ pause. A [TimeBuzzElement.gap] draws nothing of its own; the glyphs are
/// joined by single spaces. An empty list is the empty string.
String renderTimeBuzz(List<TimeBuzzElement> elements) =>
    throw UnimplementedError();

/// How many band commands (writes) playing [elements] costs: one per short,
/// long and click; gaps and pauses are waits, not writes.
int bandCommandsFor(List<TimeBuzzElement> elements) =>
    throw UnimplementedError();

/// One job's worth of the rhythm: [sequence] has at most
/// [BuzzSequence.maxBakedSteps] / [BuzzSequence.maxBuzzes] commands (a 12 PM
/// hour alone is 12 buzzes, so one sequence cannot hold a whole time), and
/// [waitBeforeMs] is the silence the player must add before writing it (the
/// gap or the pause that sat at the chunk boundary; 0 for the first chunk).
typedef TimeBuzzChunk = ({BuzzSequence sequence, int waitBeforeMs});

/// [elements] as the chunks that play it back to back. With a [profile]:
/// short = phrase buzz14, long = buzz47x2, click = click1, as a baked plan for
/// that profile (profileId, profileVersion, bakedSteps; a step's delayMs is the
/// gap before it, [kTimeBuzzPauseMs] after a pause, never below
/// [HapticDeviceProfile.minVibrationGapMs]; the first step of a chunk is 0).
/// Without one (a 4.0): per-tap sequences, long > short > click in held
/// duration, a pause is a release gap of exactly [kTimeBuzzPauseMs].
List<TimeBuzzChunk> toBuzzChunks(
  List<TimeBuzzElement> elements,
  HapticDeviceProfile? profile,
) =>
    throw UnimplementedError();
