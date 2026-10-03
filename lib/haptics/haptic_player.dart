// 8AC: playing compiled band commands. A plan (or the baked copy of one saved
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
import 'haptic_compiler.dart';
import 'haptic_profile.dart';
import 'tap_notes.dart';

/// How long past a phrase's longest span the band may take to report it ended.
const int _kEndedGraceMs = 1500;

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
    HapticPhrase? match;
    for (final ph in profile.phrases) {
      if (ph.loop == b.loop && listEquals(ph.effects, b.effects)) {
        match = ph;
        break;
      }
    }
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
  return _Resolved(cmds, felt);
}

// A rule's stored plan; else its notes compiled now; else its taps compiled.
// Notes that are all mf came from taps, which carry no loudness, so they are
// compiled with the same weight planForTaps uses (what the editor showed is
// what plays); notes with any other dynamic are weighed for loudness. Null
// when nothing compiles (no stored plan, and over [maxRuntime] or empty; a null
// [maxRuntime] lifts the cap).
_Resolved? _resolve(
  BuzzSequence s,
  HapticDeviceProfile profile,
  Duration? maxRuntime,
) {
  final baked = _fromBaked(s, profile);
  if (baked != null) return baked;
  final notes = s.notes;
  if (notes != null && s.profileId == profile.id) {
    try {
      final entries = PatternTranscript.parseCode(notes).entries;
      final loud = entries.any((e) => e.note && e.dynamic != PatternDynamic.mf);
      final plan = compile(
        entries,
        profile,
        extended: s.extended,
        dynamicWeight: loud ? 1 : 0,
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
  );
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
/// write of a compiled plan; zero for the per-tap path. The queue holds its
/// slot this long (or until the ended event) so the next job does not write
/// while the band still plays.
Duration bandSequenceSettle(
  BuzzSequence s,
  HapticDeviceProfile? profile, {
  Duration? maxRuntime = kMaxHapticRuntime,
}) {
  final resolved = profile == null ? null : _resolve(s, profile, maxRuntime);
  if (resolved == null || resolved.cmds.isEmpty) return Duration.zero;
  return Duration(milliseconds: resolved.cmds.last.waitMs);
}
