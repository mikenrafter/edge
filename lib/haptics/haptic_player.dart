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

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;

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
//
// [pulses] is how many pulses of the score the command plays (a pulse is a run
// of adjacent notes, what one tap is), and [startUnit] the sixteenth of the
// score it starts at when the plan was compiled just now (a stored plan keeps
// no positions: null). Both only serve [bandCommandOfEntries].
class _Cmd {
  const _Cmd(this.effects, this.loop, this.delayMs, this.spanMs, this.waitMs,
      {this.pulses = 1, this.startUnit});
  final List<int> effects;
  final int loop;
  final int delayMs;
  final int spanMs;
  final int waitMs;
  final int pulses;
  final int? startUnit;
}

// The pulses of [es]: runs of adjacent notes (the unit tapsFromNotes presses).
int _pulsesIn(List<PatternEntry> es) {
  var n = 0;
  var inNote = false;
  for (final e in es) {
    if (e.note && !inNote) n++;
    inNote = e.note;
  }
  return n;
}

_Cmd _cmdOf(HapticStep s, int unitMs) {
  final span = s.phrase.unitsMax * unitMs;
  return _Cmd(
    s.phrase.effects,
    s.phrase.loop,
    s.delayMs,
    span,
    span + _kEndedGraceMs,
    pulses: _pulsesIn(s.phrase.min),
    startUnit: s.startUnit,
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
  const _Resolved(this.cmds, this.feltMs, {this.targetUnits});
  final List<_Cmd> cmds;
  final int feltMs;

  /// The sixteenths of the notes this plan was compiled from (positions in
  /// [_Cmd.startUnit] are on that timeline); null for a stored plan.
  final int? targetUnits;
}

int _unitsOf(List<PatternEntry> es) => es.fold(0, (n, e) => n + e.length);

_Resolved _fromPlan(
        HapticPlan plan, HapticDeviceProfile profile, List<PatternEntry> target) =>
    _Resolved([for (final s in plan.steps) _cmdOf(s, profile.unitMs)],
        plan.runtimeMs,
        targetUnits: _unitsOf(target));

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
      // A step no phrase matches is counted as one pulse.
      pulses: match == null ? 1 : _pulsesIn(match.min),
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
        last.waitMs + extra + _kSettleMarginMs,
        pulses: last.pulses));
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
//
// The answer is a pure function of (sequence, profile, cap), and compiling a
// rhythm costs milliseconds, so it is remembered: the staff and the row of
// every pattern ask on each rebuild, and a delivery asks again for the same
// rule. A small least-recently-used map, keyed by the sequence's value.
_Resolved? _resolve(
  BuzzSequence s,
  HapticDeviceProfile profile,
  Duration? maxRuntime,
) {
  final key = _ResolveKey(s, profile, maxRuntime);
  if (_cache.containsKey(key)) {
    final hit = _cache.remove(key);
    _cache[key] = hit; // most recently used goes last
    return hit;
  }
  final made = _resolveUncached(s, profile, maxRuntime);
  _cache[key] = made;
  if (_cache.length > _kCacheSize) _cache.remove(_cache.keys.first);
  return made;
}

/// How many resolved plans are kept.
const int _kCacheSize = 64;

class _ResolveKey {
  const _ResolveKey(this.s, this.profile, this.cap);
  final BuzzSequence s;
  // A profile is a fixed measured table: compared by identity.
  final HapticDeviceProfile profile;
  final Duration? cap;

  @override
  bool operator ==(Object other) =>
      other is _ResolveKey &&
      other.s == s &&
      identical(other.profile, profile) &&
      other.cap == cap;

  @override
  int get hashCode => Object.hash(s, identityHashCode(profile), cap);
}

final Map<_ResolveKey, _Resolved?> _cache = {};
int _compiles = 0;

/// How many times a rhythm was compiled (not served from the cache) in this
/// isolate; the seam the cache tests count by.
@visibleForTesting
int get debugCompileCount => _compiles;

/// How many resolved plans are held now (never more than 64).
@visibleForTesting
int get debugResolveCacheSize => _cache.length;

@visibleForTesting
void debugClearResolveCache() => _cache.clear();

_Resolved? _resolveUncached(
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
      _compiles++;
      final plan = compile(
        entries,
        profile,
        // A rule that asks for dynamics priority weighs loudness even when
        // every note is mf, as the editor did when it compiled the preview.
        dynamicWeight: loud || s.priority == HapticPriority.dynamics ? 1 : 0,
        priority: s.priority,
        maxRuntimeMs: maxRuntime?.inMilliseconds,
      );
      if (plan != null) return _fromPlan(plan, profile, entries);
    } on FormatException {
      // Unreadable notes: fall back to the taps.
    } on ArgumentError {
      // Same.
    }
  }
  _compiles++;
  final plan = planForTaps(s, profile, maxRuntime: maxRuntime);
  return plan == null
      ? null
      : _fromPlan(plan, profile, notesFromTaps(s, unitMs: profile.unitMs));
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

/// Which band command plays each of [entries] (the notes and rests that draw
/// [s], see `scoreEntriesOf`): the index of the command in the list a delivery
/// of [s] writes, the same list [bandSequenceCommands] counts and
/// [bandStepsFor] returns, or null for a rest and for a note no command plays.
/// This is the one place the score is split into commands; the staff colours
/// by it and nothing in the UI works the split out again.
///
/// It reads [_resolve], so it names the commands that are sent:
///  * A plan compiled just now (no stored plan) knows where each command
///    starts, so a pulse belongs to the last command that starts at or before
///    it. Exact.
///  * A stored plan keeps no positions, so the split is a heuristic: a command
///    plays the next pulses of the score, as many as its phrase has (the
///    shortest rendition's runs of notes), the last command taking any that
///    are left, and a step no phrase matches counting as one. It is right
///    whenever the plan plays the pulses it was saved with, which a plan
///    compiled from these notes does (a rest is never dropped, see
///    haptic_compiler.dart); it can shift a note by a command if the notes
///    were edited after the plan was saved without recompiling. The picture
///    may be off there; what is sent and counted never is.
///  * No profile (a 4.0), or a rhythm the cap leaves to the taps: every tap is
///    one command and one pulse, so the pulses past the sent taps get null.
List<int?> bandCommandOfEntries(
  BuzzSequence s,
  List<PatternEntry> entries,
  HapticDeviceProfile? profile, {
  Duration? maxRuntime = kMaxHapticRuntime,
}) {
  final resolved = profile == null ? null : _resolve(s, profile, maxRuntime);
  // The pulses of the score: their index per note entry, where each starts.
  final pulseOf = List<int?>.filled(entries.length, null);
  final pulseStart = <int>[];
  var at = 0;
  var inNote = false;
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    if (e.note) {
      if (!inNote) pulseStart.add(at);
      pulseOf[i] = pulseStart.length - 1;
    }
    inNote = e.note;
    at += e.length;
  }

  List<int?> viaPulse(int? Function(int) of) =>
      [for (final k in pulseOf) k == null ? null : of(k)];

  if (resolved == null) {
    return viaPulse((k) => k < s.length ? k : null);
  }
  final cmds = resolved.cmds;
  if (cmds.isEmpty) return viaPulse((k) => null);
  if (resolved.targetUnits == at && cmds.every((c) => c.startUnit != null)) {
    return viaPulse((k) {
      var cmd = 0;
      for (var i = 0; i < cmds.length; i++) {
        if (cmds[i].startUnit! <= pulseStart[k]) cmd = i;
      }
      return cmd;
    });
  }
  // The stored plan: the next pulses to each command in turn.
  final owner = <int>[];
  for (var i = 0; i < cmds.length; i++) {
    for (var n = 0; n < cmds[i].pulses; n++) {
      owner.add(i);
    }
  }
  return viaPulse((k) => k < owner.length ? owner[k] : cmds.length - 1);
}

/// The length the staff of [s] shows, in ms: how long the stored plan is felt
/// ([bakedRuntimeMsFor], the figure the pattern picker's detail line gives)
/// when that is known, else the written length of [entries] at [unitMs] per
/// sixteenth. One source for the "~x.xs" on the staff and the spoken length.
int scoreDurationMs(
  BuzzSequence s,
  List<PatternEntry> entries,
  HapticDeviceProfile? profile, {
  int unitMs = 125,
}) =>
    bakedRuntimeMsFor(s, profile) ?? _unitsOf(entries) * unitMs;

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
