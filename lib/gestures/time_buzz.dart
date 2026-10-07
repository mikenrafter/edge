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

import '../haptics/haptic_compiler.dart' show kMaxHapticRuntime;
import '../haptics/haptic_player.dart' show bakedRuntimeMsFor;
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
List<TimeBuzzElement> encodeTime(DateTime localTime, TimeBuzzMode mode) {
  final pm = localTime.hour >= 12;
  final hour = localTime.hour % 12 == 0 ? 12 : localTime.hour % 12;
  final quarters = (localTime.minute / 15).round().clamp(0, 4);

  // A group is the buzzes of one unit, a gap between each; the groups are
  // joined by pauses.
  final groups = <List<TimeBuzzElement>>[];
  switch (mode) {
    case TimeBuzzMode.count:
      groups.add(List.filled(
          hour, pm ? TimeBuzzElement.long : TimeBuzzElement.short));
    case TimeBuzzMode.binary:
      groups.add([
        for (var bit = 3; bit >= 0; bit--)
          (hour >> bit) & 1 == 1 ? TimeBuzzElement.long : TimeBuzzElement.short,
      ]);
      groups.add([pm ? TimeBuzzElement.long : TimeBuzzElement.click]);
    case TimeBuzzMode.morse:
      for (final digit in '$hour'.split('')) {
        groups.add(_morse(_morseDigits[int.parse(digit)]));
      }
      groups.add(_morse(pm ? '.--.' : '.-'));
  }
  if (quarters > 0) groups.add(List.filled(quarters, TimeBuzzElement.click));

  final out = <TimeBuzzElement>[];
  for (final g in groups) {
    if (out.isNotEmpty) out.add(TimeBuzzElement.pause);
    for (final e in g) {
      if (out.isNotEmpty && out.last != TimeBuzzElement.pause) {
        out.add(TimeBuzzElement.gap);
      }
      out.add(e);
    }
  }
  return out;
}

const List<String> _morseDigits = [
  '-----', '.----', '..---', '...--', '....-', //
  '.....', '-....', '--...', '---..', '----.',
];

List<TimeBuzzElement> _morse(String code) => [
      for (final c in code.split(''))
        c == '.' ? TimeBuzzElement.short : TimeBuzzElement.long,
    ];

/// The elements as glyphs for the settings screen: ▬ long, · short, • click,
/// │ pause. A [TimeBuzzElement.gap] draws nothing of its own; the glyphs are
/// joined by single spaces. An empty list is the empty string.
String renderTimeBuzz(List<TimeBuzzElement> elements) => [
      for (final e in elements)
        switch (e) {
          TimeBuzzElement.long => '\u25AC',
          TimeBuzzElement.short => '\u00B7',
          TimeBuzzElement.click => '\u2022',
          TimeBuzzElement.pause => '\u2502',
          TimeBuzzElement.gap => null,
        },
    ].whereType<String>().join(' ');

bool _isBuzz(TimeBuzzElement e) =>
    e != TimeBuzzElement.gap && e != TimeBuzzElement.pause;

/// How many band commands (writes) playing [elements] costs: one per short,
/// long and click; gaps and pauses are waits, not writes.
int bandCommandsFor(List<TimeBuzzElement> elements) =>
    elements.where(_isBuzz).length;

/// One job's worth of the rhythm: [sequence] has at most
/// [BuzzSequence.maxBakedSteps] / [BuzzSequence.maxBuzzes] commands (a 12 PM
/// hour alone is 12 buzzes, so one sequence cannot hold a whole time) and, on a
/// band with a profile, plays within [kMaxHapticRuntime] so it is played as
/// stored. [waitBeforeMs] is the silence the player must add before writing it
/// (the gap or the pause that sat at the chunk boundary; 0 for the first chunk).
typedef TimeBuzzChunk = ({BuzzSequence sequence, int waitBeforeMs});

// Per-tap holds and the release gap for a band with no profile.
const int _kLegacyShortMs = 150;
const int _kLegacyLongMs = 600;
const int _kLegacyClickMs = 0;
const int _kLegacyGapMs = 400;

const String _kShortPhrase = 'buzz14';
const String _kLongPhrase = 'buzz47x2';
const String _kClickPhrase = 'click1';

/// [elements] as the chunks that play it back to back. With a [profile]:
/// short = phrase buzz14, long = buzz47x2, click = click1, as a baked plan for
/// that profile (profileId, profileVersion, bakedSteps; a step's delayMs is the
/// gap before it, [kTimeBuzzPauseMs] after a pause, never below
/// [HapticDeviceProfile.minVibrationGapMs]; the first step of a chunk is 0). A
/// chunk is closed at [BuzzSequence.maxBakedSteps] commands or when its
/// runtime would pass [kMaxHapticRuntime]. A profile without those phrases is
/// treated as no profile. Without one (a 4.0): per-tap sequences of at most
/// [BuzzSequence.maxBuzzes] taps, long > short > click in held duration, a
/// pause is a release gap of exactly [kTimeBuzzPauseMs].
List<TimeBuzzChunk> toBuzzChunks(
  List<TimeBuzzElement> elements,
  HapticDeviceProfile? profile,
) {
  final phrases = profile == null
      ? null
      : {
          for (final id in [_kShortPhrase, _kLongPhrase, _kClickPhrase])
            id: profile.phrases.where((p) => p.id == id).firstOrNull,
        };
  final usable = phrases != null && phrases.values.every((p) => p != null);
  final gapMs = usable ? profile!.minVibrationGapMs : _kLegacyGapMs;

  // Each buzz with the silence before it (0 for the first).
  final buzzes = <(TimeBuzzElement, int)>[];
  var wait = 0;
  for (final e in elements) {
    switch (e) {
      case TimeBuzzElement.pause:
        wait = kTimeBuzzPauseMs;
      case TimeBuzzElement.gap:
        if (wait < gapMs) wait = gapMs;
      default:
        buzzes.add((e, buzzes.isEmpty ? 0 : wait));
        wait = gapMs;
    }
  }
  if (buzzes.isEmpty) return const [];

  return usable
      ? _profileChunks(buzzes, profile!, phrases)
      : _legacyChunks(buzzes);
}

List<TimeBuzzChunk> _profileChunks(
  List<(TimeBuzzElement, int)> buzzes,
  HapticDeviceProfile profile,
  Map<String, HapticPhrase?> phrases,
) {
  BuzzSequence plan(List<BakedStep> steps) => BuzzSequence(
        const [0],
        durationsMs: const [500],
        profileId: profile.id,
        profileVersion: profile.version,
        bakedSteps: steps,
      );

  final out = <TimeBuzzChunk>[];
  var steps = <BakedStep>[];
  var before = 0;
  void close() {
    if (steps.isEmpty) return;
    out.add((sequence: plan(steps), waitBeforeMs: before));
    steps = <BakedStep>[];
  }

  for (final (e, wait) in buzzes) {
    final ph = phrases[switch (e) {
      TimeBuzzElement.short => _kShortPhrase,
      TimeBuzzElement.long => _kLongPhrase,
      _ => _kClickPhrase,
    }]!;
    if (steps.isNotEmpty) {
      final next = [
        ...steps,
        BakedStep(effects: ph.effects, loop: ph.loop, delayMs: wait),
      ];
      final fits = next.length <= BuzzSequence.maxBakedSteps &&
          (bakedRuntimeMsFor(plan(next), profile) ?? 0) <=
              kMaxHapticRuntime.inMilliseconds;
      if (fits) {
        steps = next;
        continue;
      }
      close();
    }
    // A chunk's first step has no delay of its own: the silence before it is
    // the chunk's wait.
    before = wait;
    steps = [BakedStep(effects: ph.effects, loop: ph.loop, delayMs: 0)];
  }
  close();
  return out;
}

List<TimeBuzzChunk> _legacyChunks(List<(TimeBuzzElement, int)> buzzes) {
  final out = <TimeBuzzChunk>[];
  var offsets = <int>[];
  var holds = <int>[];
  var before = 0;
  void close() {
    if (offsets.isEmpty) return;
    out.add((
      sequence: BuzzSequence(offsets, durationsMs: holds),
      waitBeforeMs: before,
    ));
    offsets = <int>[];
    holds = <int>[];
  }

  for (final (e, wait) in buzzes) {
    if (offsets.length >= BuzzSequence.maxBuzzes) close();
    final hold = switch (e) {
      TimeBuzzElement.short => _kLegacyShortMs,
      TimeBuzzElement.long => _kLegacyLongMs,
      _ => _kLegacyClickMs,
    };
    if (offsets.isEmpty) {
      before = wait;
      offsets.add(0);
    } else {
      offsets.add(offsets.last + holds.last + wait);
    }
    holds.add(hold);
  }
  close();
  return out;
}
