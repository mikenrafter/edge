// Playing compiled band commands. A plan (or the baked copy of one saved
// with a rule) is a list of commands with a write delay after the previous
// command's "ended" event. This file turns that into writes, with no BLE and no
// Flutter: the caller hands in the write, the wait for the band's "ended"
// event (100) and the connection check.
//
// For each command after the first: wait for the previous command's ended
// event (a timeout just carries on, the band has finished by then), then wait
// the command's delay, then write. Results follow deliverBuzzSequence:
// complete, rejected (nothing written) or partial (some written, a later one
// was not).

import 'package:flutter/foundation.dart' show listEquals;

import '../gestures/pattern_transcript.dart';
import '../notify/buzz_sequence.dart';
import 'band_queue.dart';
import 'haptic_compiler.dart';
import 'haptic_profile.dart';
import 'tap_notes.dart';

/// When one command of a compiled delivery started playing on the band: its
/// index in the plan (0 based) and the time the wearer feels it start. When
/// [measured] the time is the band's own live "fired" event (60); otherwise it
/// is the write time plus the usual Bluetooth lead (the band said nothing
/// within a second of the write).
class HapticPlayStart {
  const HapticPlayStart(this.command, this.at, {required this.measured});
  final int command;
  final DateTime at;
  final bool measured;

  @override
  String toString() => 'HapticPlayStart($command, $at, measured: $measured)';
}

/// How long past a phrase's longest span the band may take to report it ended.
const int _kEndedGraceMs = 1500;

/// What is added to a recorded playback estimate before the band is released
/// without its ended event.
const int _kSettleMarginMs = 500;

/// The wait for the ended event after a stored command no phrase of the
/// profile matches, and the span assumed for it when sizing a timeout.
const int _kUnknownMs = 3000;

// One command to write: its slots and loop, the wait after the previous
// command's ended event, how long the band is felt to play it at most, and how
// long to wait for its ended event.
class _Cmd {
  const _Cmd(this.effects, this.loop, this.delayMs, this.spanMs, this.waitMs);
  final List<int> effects;
  final int loop;
  final int delayMs;
  final int spanMs;
  final int waitMs;
}

_Cmd _cmdOf(HapticStep s, int unitMs) {
  final span = s.phrase.unitsMax * unitMs;
  return _Cmd(
    s.phrase.effects,
    s.phrase.loop,
    s.delayMs,
    span,
    span + _kEndedGraceMs,
  );
}

Future<BuzzDelivery> _play(
  List<_Cmd> cmds, {
  required Future<bool> Function(List<int> effects, int loop) write,
  required Future<bool> Function(Duration timeout) waitEnded,
  required bool Function() isConnected,
  void Function(int command)? onWritten,
}) async {
  var written = 0;
  BuzzDelivery failed() =>
      written > 0 ? BuzzDelivery.partial : BuzzDelivery.rejected;
  try {
    for (var i = 0; i < cmds.length; i++) {
      if (!isConnected()) return failed();
      if (i > 0) {
        try {
          await waitEnded(Duration(milliseconds: cmds[i - 1].waitMs));
        } catch (_) {
          // No answer is the same as a timeout: carry on.
        }
        if (cmds[i].delayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: cmds[i].delayMs));
        }
        if (!isConnected()) return failed();
      }
      final ok = await write(cmds[i].effects, cmds[i].loop);
      if (!ok) return failed();
      written++;
      onWritten?.call(i);
    }
    return BuzzDelivery.complete;
  } catch (_) {
    return failed();
  }
}

/// Writes each step of [plan] in order, waiting for the band's ended event
/// (up to the previous phrase's longest span at [unitMs] plus 1500 ms) and
/// then the step's delay before the next write.
Future<BuzzDelivery> playHapticPlan(
  HapticPlan plan, {
  required Future<bool> Function(List<int> effects, int loop) write,
  required Future<bool> Function(Duration timeout) waitEnded,
  required bool Function() isConnected,
  int unitMs = 125,
}) => _play(
  [for (final s in plan.steps) _cmdOf(s, unitMs)],
  write: write,
  waitEnded: waitEnded,
  isConnected: isConnected,
);

// What a sequence plays on a band with [profile], and how long it is felt.
class _Resolved {
  const _Resolved(this.cmds, this.feltMs);
  final List<_Cmd> cmds;
  final int feltMs;
}

_Resolved _fromPlan(HapticPlan plan, HapticDeviceProfile profile) =>
    _Resolved([for (final s in plan.steps) _cmdOf(s, profile.unitMs)],
        plan.runtimeMs);

// The stored plan of a rule saved for this profile, as commands. A step no
// phrase of the profile matches is still played as stored, with a fixed wait.
_Resolved? _fromBaked(BuzzSequence s, HapticDeviceProfile profile) {
  final steps = s.bakedSteps;
  if (steps == null || steps.isEmpty || s.profileId != profile.id) return null;
  final cmds = <_Cmd>[];
  var felt = 0;
  for (final b in steps) {
    final match = _phraseOf(b, profile);
    final span = match == null ? _kUnknownMs : match.unitsMax * profile.unitMs;
    cmds.add(_Cmd(
      b.effects,
      b.loop,
      b.delayMs,
      span,
      match == null ? _kUnknownMs : span + _kEndedGraceMs,
    ));
    felt += span + b.delayMs;
  }
  // The runtime recorded when the plan was saved is the better estimate of how
  // long it plays. When it is longer than the commands add up to (a command no
  // phrase matches is sized at a flat 3 s), the difference is the last
  // command's: the band is held that much longer after the last write.
  final stored = s.bakedRuntimeMs;
  if (stored != null && stored > felt) {
    final extra = stored - felt;
    final last = cmds.removeLast();
    cmds.add(_Cmd(last.effects, last.loop, last.delayMs, last.spanMs + extra,
        last.waitMs + extra + _kSettleMarginMs));
    felt = stored;
  }
  return _Resolved(cmds, felt);
}

// The phrase of [profile] a stored command is, if any.
HapticPhrase? _phraseOf(BakedStep b, HapticDeviceProfile profile) {
  for (final ph in profile.phrases) {
    if (ph.loop == b.loop && listEquals(ph.effects, b.effects)) return ph;
  }
  return null;
}

/// How long the stored plan of [s] is felt at its longest, in ms: the runtime
/// recorded when it was saved, else (a rule saved before that was recorded)
/// worked out from [profile] as each command's longest span plus the longest
/// rest the profile measured for its write delay. Null when there is no plan,
/// or it cannot be worked out (no stored runtime, and no profile it was made
/// for). A command or delay the profile does not know counts for what it
/// plays: 3 s for the command, the delay itself for the rest.
int? bakedRuntimeMsFor(BuzzSequence s, HapticDeviceProfile? profile) {
  final steps = s.bakedSteps;
  if (steps == null || steps.isEmpty) return null;
  final stored = s.bakedRuntimeMs;
  if (stored != null) return stored;
  if (profile == null || s.profileId != profile.id) return null;
  var total = 0;
  for (var i = 0; i < steps.length; i++) {
    final b = steps[i];
    final ph = _phraseOf(b, profile);
    total += ph == null ? _kUnknownMs : ph.unitsMax * profile.unitMs;
    if (i == 0) continue;
    var rest = -1;
    for (final g in profile.gaps) {
      if (g.delayMs == b.delayMs && g.maxUnits * profile.unitMs > rest) {
        rest = g.maxUnits * profile.unitMs;
      }
    }
    total += rest < 0 ? b.delayMs : rest;
  }
  return total;
}

// A rule's stored plan; else its notes compiled now; else its taps compiled.
// Notes that are all mf or `*` came from taps, which carry no loudness, so
// they are compiled with the same weight planForTaps uses (what the editor
// showed is what plays); notes with any other dynamic are weighed for loudness. A stored
// plan longer than [maxRuntime] is not played (it was saved with the cap
// lifted): the notes, then the taps, are compiled under the cap as if there
// were no stored plan. Null when nothing compiles (no stored plan, and over
// [maxRuntime] or empty; a null [maxRuntime] lifts the cap).
_Resolved? _resolve(
  BuzzSequence s,
  HapticDeviceProfile profile,
  Duration? maxRuntime,
) {
  final baked = _fromBaked(s, profile);
  if (baked != null) {
    final runtime = bakedRuntimeMsFor(s, profile);
    if (maxRuntime == null ||
        runtime == null ||
        runtime <= maxRuntime.inMilliseconds) {
      return baked;
    }
  }
  final notes = s.notes;
  if (notes != null && s.profileId == profile.id) {
    try {
      final entries = PatternTranscript.parseCode(notes).entries;
      final loud = entries.any((e) =>
          e.note &&
          e.dynamic != PatternDynamic.mf &&
          e.dynamic != PatternDynamic.any);
      final plan = compile(
        entries,
        profile,
        // A rule that asks for dynamics priority weighs loudness even when
        // every note is mf, as the editor did when it compiled the preview.
        dynamicWeight: loud || s.priority == HapticPriority.dynamics ? 1 : 0,
        priority: s.priority,
        maxRuntimeMs: maxRuntime?.inMilliseconds,
      );
      if (plan != null) return _fromPlan(plan, profile);
    } on FormatException {
      // Unreadable notes: fall back to the taps.
    } on ArgumentError {
      // Same.
    }
  }
  final plan = planForTaps(s, profile, maxRuntime: maxRuntime);
  return plan == null ? null : _fromPlan(plan, profile);
}

/// Delivers [s] to a band. With a [profile] it plays the rule's stored plan,
/// else its notes compiled, else its taps compiled, as Maverick commands
/// through [writePattern], waiting on [waitEnded] between them. Without a
/// profile, or when nothing compiles, it plays today's per-tap buzz.
/// [maxRuntime] is the longest a compiled rhythm may run (null lifts it).
Future<BuzzDelivery> deliverBandSequence(
  BuzzSequence s, {
  required HapticDeviceProfile? profile,
  required Future<bool> Function() buzz,
  Future<bool> Function(int holdMs)? buzzForDuration,
  required Future<bool> Function(List<int> effects, int loop) writePattern,
  required Future<bool> Function(Duration timeout) waitEnded,
  required bool Function() isConnected,
  Duration? maxRuntime = kMaxHapticRuntime,
  void Function(int command)? onWritten,
}) {
  final resolved = profile == null ? null : _resolve(s, profile, maxRuntime);
  if (resolved == null) {
    return deliverBuzzSequence(
      s,
      buzz: buzz,
      buzzForDuration: buzzForDuration,
      isConnected: isConnected,
    );
  }
  return _play(
    resolved.cmds,
    write: writePattern,
    waitEnded: waitEnded,
    isConnected: isConnected,
    onWritten: onWritten,
  );
}

/// The commands [s] plays on a band with [profile], as stored steps: its baked
/// plan, else its notes compiled, else its taps compiled (see
/// [deliverBandSequence]). Null when nothing compiles under [maxRuntime] (null
/// lifts the cap).
List<BakedStep>? bandStepsFor(
  BuzzSequence s,
  HapticDeviceProfile profile, {
  Duration? maxRuntime = kMaxHapticRuntime,
}) {
  final resolved = _resolve(s, profile, maxRuntime);
  if (resolved == null) return null;
  return [
    for (final c in resolved.cmds)
      BakedStep(effects: c.effects, loop: c.loop, delayMs: c.delayMs),
  ];
}

/// How long a delivery of [s] may take: the sequence's own transport timeout,
/// or on a profiled band the longer of that and the plan's felt length plus
/// 2 s per command and 1 s.
Duration bandSequenceTimeout(
  BuzzSequence s,
  HapticDeviceProfile? profile, {
  Duration? maxRuntime = kMaxHapticRuntime,
}) {
  final resolved = profile == null ? null : _resolve(s, profile, maxRuntime);
  if (resolved == null) return s.transportTimeout;
  final planned = Duration(
    milliseconds: resolved.feltMs + 2000 * resolved.cmds.length + 1000,
  );
  return planned > s.transportTimeout ? planned : s.transportTimeout;
}

/// How many band commands a delivery of [s] writes: the plan's commands on a
/// profiled band, else one per tap. What the band queue counts against the
/// rolling limit.
int bandSequenceCommands(
  BuzzSequence s,
  HapticDeviceProfile? profile, {
  Duration? maxRuntime = kMaxHapticRuntime,
}) {
  final resolved = profile == null ? null : _resolve(s, profile, maxRuntime);
  return resolved == null ? s.length : resolved.cmds.length;
}

/// How long the band may take to report its last command ended, after the last
/// write, when its ended event does not come: a compiled plan's last phrase plus
/// a margin (longer when the plan's recorded runtime says it plays longer than
/// its commands add up to), at most [kBandSettleMax], or one buzz's playback
/// ([kBandBuzzPlayback]) on the per-tap path. The queue holds its slot this
/// long (or until the ended event) so the next job does not write while the
/// band still plays.
Duration bandSequenceSettle(
  BuzzSequence s,
  HapticDeviceProfile? profile, {
  Duration? maxRuntime = kMaxHapticRuntime,
}) {
  final resolved = profile == null ? null : _resolve(s, profile, maxRuntime);
  if (resolved == null) return kBandBuzzPlayback;
  if (resolved.cmds.isEmpty) return Duration.zero;
  final settle = Duration(milliseconds: resolved.cmds.last.waitMs);
  return settle > kBandSettleMax ? kBandSettleMax : settle;
}

/// [deliverBandSequence] as one job of [queue]: the commands it will write are
/// reserved up front, every write goes through the job's token (so it is
/// counted when it happens, resets the ended signal, and is refused once the
/// job has timed out), and the band is held through the last playback.
///
/// [lead] is a silence the job keeps once it has the band, before its first
/// write (after the previous job's playback and the queue's own gap): how a
/// rhythm split over several jobs keeps the pause that fell between them.
/// [onFirstWrite] is called once, when the first write of the job was accepted
/// by the band (so something is playing).
Future<BuzzDelivery> deliverBandSequenceQueued(
  BandHapticQueue queue,
  BuzzSequence s, {
  required HapticDeviceProfile? profile,
  required Future<bool> Function() buzz,
  Future<bool> Function(int holdMs)? buzzForDuration,
  required Future<bool> Function(List<int> effects, int loop) writePattern,
  required Future<bool> Function(Duration timeout) waitEnded,
  required bool Function() isConnected,
  Duration? maxRuntime = kMaxHapticRuntime,
  void Function(int command)? onWritten,
  Duration lead = Duration.zero,
  void Function()? onFirstWrite,
}) =>
    queue.run(
      (token) async {
        if (lead > Duration.zero) await Future<void>.delayed(lead);
        var first = onFirstWrite;
        Future<bool> accepted(Future<bool> w) async {
          final ok = await w;
          if (ok) {
            final f = first;
            first = null;
            f?.call();
          }
          return ok;
        }

        return deliverBandSequence(
          s,
          profile: profile,
          buzz: () => accepted(token.write(buzz)),
          buzzForDuration: buzzForDuration == null
              ? null
              : (holdMs) =>
                  accepted(token.write(() => buzzForDuration(holdMs))),
          writePattern: (effects, loop) =>
              accepted(token.write(() => writePattern(effects, loop))),
          waitEnded: waitEnded,
          isConnected: () => !token.cancelled && isConnected(),
          maxRuntime: maxRuntime,
          onWritten: onWritten,
        );
      },
      commands: bandSequenceCommands(s, profile, maxRuntime: maxRuntime),
      timeout:
          bandSequenceTimeout(s, profile, maxRuntime: maxRuntime) + lead,
      settle: bandSequenceSettle(s, profile, maxRuntime: maxRuntime),
    );
