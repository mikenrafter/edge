// hardware_probes.dart — scripted hardware measurements for the Device lab (8V).
//
// The touch counter and the band buzz both depend on things the band does that
// no spec describes: how close together it accepts haptic commands, how long
// its electrode takes to show a finger that lifted and came back. Two probes
// measure them on the real band, under the wearer's control, and write
// everything into the lab log (and, for ECG, the raw packets) so the numbers can
// be documented and the state machine replayed off the band.
//
//  * [HapticProbe] — single buzz commands at a series of spacings. Per command:
//    when it was asked for, when its write landed, and the band's own reply (or
//    none). Per trial: the band events that arrived during it and how many
//    buzzes the wearer FELT (asked after each trial).
//  * [EcgTouchProbe] — a cued touch / lift script on a live ECG stream: the
//    phone shows (and the phone itself vibrates) TOUCH / LIFT on a schedule;
//    afterwards [analyzeTouchProbe] lines each cue up with the contact runs and
//    the band's presence flag.
//
// SAFETY AND HARDWARE HEALTH. Both probes start only from an explicit button,
// stop at once on Stop or a lost link, and are bounded: the buzz probe sends at
// most [HapticProbe.maxCommands] short buzzes per run with a rest after every
// trial; the ECG probe streams for at most [EcgTouchProbe.maxStream] and always
// stops the stream (in `finally`). Neither sends any command the app does not
// already send (one ordinary buzz; the gesture's ECG start/stop). Every flag is
// reset in `finally`, so a failure never wedges the lab.
//
// Pure Dart with injected effects: no Flutter, no BLE, no clock of its own.

import 'dart:async';

import 'package:openstrap_protocol/openstrap_protocol.dart' show LabradorR17;

import 'ecg_stream_readiness.dart';

// ---------------------------------------------------------------- buzz probe

/// One trial: [commands] single buzzes, [spacingMs] apart.
class HapticTrial {
  const HapticTrial(this.spacingMs, {this.commands = 3});
  final int spacingMs;
  final int commands;

  @override
  String toString() => '$commands buzzes $spacingMs ms apart';
}

/// One buzz command of a trial. Times are ms since the trial started.
class HapticCommandResult {
  HapticCommandResult(this.index, this.requestedMs);
  final int index;
  final int requestedMs;
  int? writtenMs;
  bool? written;

  /// The band's reply status name, `none` when it did not answer within its
  /// window, null while still waiting.
  String? reply;
  int? replyMs;
}

/// A band event seen during a trial: its id, when the phone got it (ms since
/// the trial started) and when the band says it happened (same origin).
class HapticBandEvent {
  const HapticBandEvent(this.eventId, this.receivedMs, this.happenedMs);
  final int eventId;
  final int receivedMs;
  final int happenedMs;
}

class HapticTrialResult {
  HapticTrialResult(this.trial);
  final HapticTrial trial;
  final List<HapticCommandResult> commands = [];
  final List<HapticBandEvent> events = [];

  /// How many buzzes the wearer felt; null when they skipped the question.
  int? felt;

  /// One plain line for the lab log.
  String get summary {
    final replies = commands.map((c) => c.reply ?? 'waiting').join(', ');
    final written = commands.where((c) => c.written == true).length;
    final replied = commands
        .where((c) => c.reply != null && c.reply != 'none')
        .length;
    final writes = commands
        .map((c) => c.writtenMs == null
            ? 'not written'
            : '${c.requestedMs}→${c.writtenMs}')
        .join(', ');
    final ev = events.isEmpty
        ? 'none'
        : events
            .map((e) => '${e.eventId} at +${e.happenedMs} (got +${e.receivedMs})')
            .join(', ');
    return 'Buzz probe, ${trial.spacingMs} ms apart: ${commands.length} sent, '
        '$written written (asked→written ms: $writes), band replied to '
        '$replied ($replies); band events $ev; felt '
        '${felt == null ? 'not answered' : felt.toString()}.';
  }
}

class HapticProbe {
  HapticProbe({
    required this.sendOne,
    required this.askFelt,
    required this.isConnected,
    this.step,
    DateTime Function()? now,
    Future<void> Function(Duration)? wait,
    List<HapticTrial>? trials,
    this.replyWait = const Duration(milliseconds: 3500),
    this.rest = const Duration(seconds: 2),
  })  : _now = now ?? DateTime.now,
        _wait = wait ?? ((d) => Future<void>.delayed(d)),
        trials = trials ?? defaultTrials {
    final total = this.trials.fold<int>(0, (n, t) => n + t.commands);
    if (total > maxCommands) {
      throw ArgumentError.value(
          total, 'trials', 'at most $maxCommands buzzes per run');
    }
  }

  /// Hardware health: no run sends more than this many buzzes.
  static const int maxCommands = 30;

  /// Spacings either side of what is known (300 ms pairs play; a third 300 ms
  /// later, or a new buzz 0.2–0.65 s after a pair, did not; 1.06 s did).
  static const List<HapticTrial> defaultTrials = [
    HapticTrial(200),
    HapticTrial(300),
    HapticTrial(450),
    HapticTrial(600),
    HapticTrial(800),
    HapticTrial(1000),
    HapticTrial(1300),
    HapticTrial(1600),
  ];

  /// One ordinary band buzz. True when the write landed; [onReply] hears the
  /// band's reply status (null: none) and its latency.
  final Future<bool> Function(void Function(String? status, int ms) onReply)
      sendOne;

  /// Ask the wearer how many buzzes they felt in [trial] ([index] of all).
  /// Null: skipped. Must complete even when the probe is stopped.
  final Future<int?> Function(HapticTrial trial, int index) askFelt;

  final bool Function() isConnected;
  final void Function(String line)? step;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _wait;
  final List<HapticTrial> trials;

  /// How long after a trial's last command replies and events are collected
  /// (the band's reply window is 3 s).
  final Duration replyWait;

  /// Rest after every trial: the motor cools, and trials do not overlap.
  final Duration rest;

  bool _running = false;
  bool _stop = false;
  DateTime? _trialStart;
  HapticTrialResult? _current;
  final List<HapticTrialResult> results = [];

  bool get running => _running;

  /// Stop after the current command; a pending question is the caller's to
  /// cancel.
  void stop() => _stop = true;

  /// A band event (any id) arrived; recorded into the running trial.
  void onBandEvent(int eventId, DateTime receivedAt, DateTime happenedAt) {
    final cur = _current, t0 = _trialStart;
    if (cur == null || t0 == null) return;
    cur.events.add(HapticBandEvent(
      eventId,
      receivedAt.difference(t0).inMilliseconds,
      happenedAt.difference(t0).inMilliseconds,
    ));
  }

  /// Run every trial once. Returns the results (also kept in [results]).
  Future<List<HapticTrialResult>> run() async {
    if (_running) return results;
    _running = true;
    _stop = false;
    results.clear();
    try {
      step?.call('Buzz probe: ${trials.length} trials, '
          '${trials.fold<int>(0, (n, t) => n + t.commands)} short buzzes at '
          'most, ${rest.inMilliseconds} ms rest after each.');
      for (var i = 0; i < trials.length; i++) {
        if (_stop || !isConnected()) break;
        final r = await _runTrial(trials[i]);
        results.add(r);
        if (_stop) break;
        r.felt = await askFelt(trials[i], i);
        step?.call(r.summary);
        if (i < trials.length - 1 && !_stop) await _wait(rest);
      }
      step?.call(_stop
          ? 'Buzz probe stopped after ${results.length} trials.'
          : !isConnected()
              ? 'Buzz probe ended: the band is not connected.'
              : 'Buzz probe finished.');
      return results;
    } finally {
      _running = false;
      _current = null;
      _trialStart = null;
    }
  }

  Future<HapticTrialResult> _runTrial(HapticTrial t) async {
    final r = _current = HapticTrialResult(t);
    final t0 = _trialStart = _now();
    final pending = <Future<void>>[];
    for (var i = 0; i < t.commands; i++) {
      if (_stop || !isConnected()) break;
      final due = t0.add(Duration(milliseconds: t.spacingMs * i));
      final left = due.difference(_now());
      if (left > Duration.zero) await _wait(left);
      final c = HapticCommandResult(i, _now().difference(t0).inMilliseconds);
      r.commands.add(c);
      // Not awaited: the next command goes out on schedule, not after this
      // write lands (the write queue serializes them anyway, and the measured
      // write times show it).
      pending.add(sendOne((status, ms) {
        c.reply = status ?? 'none';
        c.replyMs = ms;
      }).then((ok) {
        c.written = ok;
        c.writtenMs = _now().difference(t0).inMilliseconds;
        if (!ok) c.reply ??= 'not written';
      }, onError: (Object _) {
        c.written = false;
        c.writtenMs = _now().difference(t0).inMilliseconds;
        c.reply ??= 'not written';
      }));
    }
    await Future.wait(pending);
    await _wait(replyWait);
    for (final c in r.commands) {
      c.reply ??= 'none';
    }
    return r;
  }
}

// ---------------------------------------------------------- ECG touch probe

enum EcgCueKind { rest, touch, lift, done }

class EcgCue {
  const EcgCue(this.kind, this.holdMs, this.text);
  final EcgCueKind kind;
  final int holdMs;
  final String text;
}

/// A cue as it was shown: phone wall time.
class EcgCueShown {
  const EcgCueShown(this.cue, this.at);
  final EcgCue cue;
  final DateTime at;
}

/// A packet as the probe got it.
class EcgProbePacket {
  const EcgProbePacket(this.r, this.receivedAt);
  final LabradorR17 r;
  final DateTime receivedAt;
}

class EcgTouchProbe {
  EcgTouchProbe({
    required this.beginStream,
    required this.endStream,
    required this.isStreamAlive,
    required this.onCue,
    this.step,
    this.onPacket,
    DateTime Function()? now,
    Future<void> Function(Duration)? wait,
    List<EcgCue>? script,
    this.leadIn = const Duration(seconds: 2),
    this.startTimeout = const Duration(seconds: 20),
  })  : _now = now ?? DateTime.now,
        _wait = wait ?? ((d) => Future<void>.delayed(d)),
        script = script ?? defaultScript;

  /// Hardware health: the stream never runs longer than this.
  static const Duration maxStream = Duration(seconds: 60);

  /// Long holds (does contact stay solid?), lifts of growing length (how long
  /// before a returning finger shows?), then quick taps (does a short lift
  /// show at all?). About 32 s.
  static const List<EcgCue> defaultScript = [
    EcgCue(EcgCueKind.rest, 2500, 'Keep your finger off the sensor'),
    EcgCue(EcgCueKind.touch, 3000, 'Touch and hold'),
    EcgCue(EcgCueKind.lift, 400, 'Lift'),
    EcgCue(EcgCueKind.touch, 3000, 'Touch and hold'),
    EcgCue(EcgCueKind.lift, 800, 'Lift'),
    EcgCue(EcgCueKind.touch, 3000, 'Touch and hold'),
    EcgCue(EcgCueKind.lift, 1500, 'Lift'),
    EcgCue(EcgCueKind.touch, 3000, 'Touch and hold'),
    EcgCue(EcgCueKind.lift, 2500, 'Lift'),
    EcgCue(EcgCueKind.touch, 3000, 'Touch and hold'),
    EcgCue(EcgCueKind.lift, 2000, 'Lift'),
    EcgCue(EcgCueKind.touch, 300, 'Tap'),
    EcgCue(EcgCueKind.lift, 700, 'Lift'),
    EcgCue(EcgCueKind.touch, 300, 'Tap'),
    EcgCue(EcgCueKind.lift, 700, 'Lift'),
    EcgCue(EcgCueKind.touch, 300, 'Tap'),
    EcgCue(EcgCueKind.lift, 2500, 'Lift and wait'),
  ];

  final Future<bool> Function() beginStream;
  final Future<void> Function() endStream;
  final bool Function() isStreamAlive;

  /// Show [cue] (null: the probe is over). The UI vibrates the phone too.
  final void Function(EcgCue? cue) onCue;
  final void Function(String line)? step;
  final void Function(LabradorR17 r, DateTime receivedAt)? onPacket;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _wait;
  final List<EcgCue> script;

  /// Wall time between the stream being steady and the first cue; the
  /// sensor's own settle (~2.4 s after the first sample) mostly falls in it.
  final Duration leadIn;
  final Duration startTimeout;

  bool _running = false;
  bool _stop = false;
  final _readiness = EcgStreamReadiness();
  final List<EcgProbePacket> packets = [];
  final List<EcgCueShown> cues = [];

  bool get running => _running;
  void stop() => _stop = true;

  void onFrame(LabradorR17 r) {
    if (!_running) return;
    final at = _now();
    packets.add(EcgProbePacket(r, at));
    try {
      onPacket?.call(r, at);
    } catch (_) {}
    _readiness.offer(
        at: at, strapTime: r.strapTime, sampleCount: r.samples.length);
  }

  /// Run the script once. Returns the analysis lines (also logged).
  Future<List<String>> run() async {
    if (_running) return const [];
    _running = true;
    _stop = false;
    packets.clear();
    cues.clear();
    _readiness.reset();
    final started = _now();
    var up = false;
    try {
      step?.call('ECG touch probe: starting the stream (at most '
          '${maxStream.inSeconds} s).');
      up = await beginStream();
      if (!up) {
        step?.call('ECG touch probe: the stream did not start.');
        return const [];
      }
      // Wait for a steady stream, then the lead-in.
      while (!_readiness.ready) {
        if (_stop || !isStreamAlive()) return _ended('before the stream was steady');
        if (_now().difference(started) > startTimeout) {
          return _ended('no steady stream in ${startTimeout.inSeconds} s');
        }
        await _wait(const Duration(milliseconds: 100));
      }
      step?.call('ECG touch probe: stream steady; cues start in '
          '${leadIn.inMilliseconds} ms.');
      await _wait(leadIn);
      for (final cue in script) {
        if (_stop || !isStreamAlive()) return _ended('during the cues');
        if (_now().difference(started) + Duration(milliseconds: cue.holdMs) >
            maxStream) {
          return _ended('at the ${maxStream.inSeconds} s stream limit');
        }
        final shown = EcgCueShown(cue, _now());
        cues.add(shown);
        onCue(cue);
        await _wait(Duration(milliseconds: cue.holdMs));
      }
      onCue(const EcgCue(EcgCueKind.done, 0, 'Done'));
      final lines = analyzeTouchProbe(packets, cues);
      for (final l in lines) {
        step?.call(l);
      }
      return lines;
    } finally {
      try {
        onCue(null);
      } catch (_) {}
      if (up) {
        try {
          await endStream();
        } catch (_) {}
      }
      _running = false;
    }
  }

  List<String> _ended(String when) {
    final lines = [
      'ECG touch probe stopped $when.',
      ...analyzeTouchProbe(packets, cues),
    ];
    for (final l in lines) {
      step?.call(l);
    }
    return lines;
  }
}

/// A run of samples with signal, on the strap clock (ms).
class ContactRun {
  const ContactRun(this.startMs, this.endMs, this.startIndex);
  final int startMs;

  /// The first sample time AFTER the run.
  final int endMs;

  /// Where in its packet the run started (sample index): the band seems to
  /// report a returning finger at a fixed phase of its packet cycle.
  final int startIndex;
}

/// Contact runs from raw samples: a sample is contact when non-zero; zero
/// runs shorter than [bridgeMs] (an ECG trace crossing zero) do not split a
/// run. Packet strap time is the newest sample (PACKET TIME).
List<ContactRun> contactRuns(List<EcgProbePacket> packets, {int bridgeMs = 50}) {
  final runs = <ContactRun>[];
  int? start, startIdx, lastContact;
  for (final p in packets) {
    final n = p.r.samples.length;
    final endMs = (p.r.strapTime * 1000).round();
    for (var i = 0; i < n; i++) {
      final t = endMs - (n - i) * 10;
      if (p.r.samples[i] == 0) continue;
      if (start != null && lastContact != null && t - lastContact > bridgeMs) {
        runs.add(ContactRun(start, lastContact + 10, startIdx!));
        start = null;
      }
      if (start == null) {
        start = t;
        startIdx = i;
      }
      lastContact = t;
    }
  }
  if (start != null && lastContact != null) {
    runs.add(ContactRun(start, lastContact + 10, startIdx!));
  }
  return runs;
}

/// Line each cue up with what the sensor showed. Cue times are phone time,
/// mapped onto the strap clock through the least-delayed packet (receipt
/// minus its newest sample): that mapping assumes the best packet had no
/// latency, so every latency below is overstated by that packet's real
/// latency (about 0.15 s in the lab logs) plus the wearer's reaction time.
List<String> analyzeTouchProbe(
    List<EcgProbePacket> packets, List<EcgCueShown> cues) {
  if (packets.isEmpty) return const ['ECG touch probe: no packets.'];
  var offsetMs = 1 << 62; // phone ms - strap ms, minimum over packets
  for (final p in packets) {
    final d = p.receivedAt.millisecondsSinceEpoch -
        (p.r.strapTime * 1000).round();
    if (d < offsetMs) offsetMs = d;
  }
  int strapOf(DateTime wall) => wall.millisecondsSinceEpoch - offsetMs;
  final runs = contactRuns(packets);
  final out = <String>[
    'ECG touch probe: ${packets.length} packets, ${runs.length} contact runs; '
        'phone time = strap time ${offsetMs >= 0 ? '+' : '-'} '
        '${offsetMs.abs()} ms (best packet).',
    for (final r in runs)
      'ECG touch probe run: strap ${(r.startMs / 1000).toStringAsFixed(2)}–'
          '${(r.endMs / 1000).toStringAsFixed(2)} s '
          '(${r.endMs - r.startMs} ms), started at sample ${r.startIndex} '
          'of its packet.',
  ];
  // Presence flag transitions, per packet (end time).
  bool? lastPresence;
  for (final p in packets) {
    if (p.r.samples.isEmpty) continue;
    if (lastPresence != p.r.presence) {
      out.add('ECG touch probe presence: ${p.r.presence ? 'on' : 'off'} from '
          'the packet ending at strap '
          '${p.r.strapTime.toStringAsFixed(2)} s (S2 ${p.r.s2State}, '
          'progress ${p.r.progress}).');
      lastPresence = p.r.presence;
    }
  }
  final lastSample = (packets.last.r.strapTime * 1000).round();
  for (var i = 0; i < cues.length; i++) {
    final c = cues[i];
    if (c.cue.kind != EcgCueKind.touch && c.cue.kind != EcgCueKind.lift) {
      continue;
    }
    final at = strapOf(c.at);
    final prev = i > 0 ? cues[i - 1].cue : null;
    final what = c.cue.kind == EcgCueKind.touch
        ? 'TOUCH${prev != null && prev.kind == EcgCueKind.lift ? ' after a ${prev.holdMs} ms lift' : ''}'
        : 'LIFT after a ${prev?.holdMs ?? 0} ms ${prev?.kind.name ?? ''}';
    int? seenAt;
    String extra = '';
    if (c.cue.kind == EcgCueKind.touch) {
      for (final r in runs) {
        if (r.startMs >= at - 150) {
          seenAt = r.startMs;
          extra = ', at sample ${r.startIndex} of its packet';
          break;
        }
      }
    } else {
      for (final r in runs) {
        if (r.endMs >= at - 150) {
          seenAt = r.endMs;
          break;
        }
      }
    }
    // A transition at or after the next cue of the same kind belongs to that
    // cue, not this one.
    int? nextSame;
    for (var j = i + 1; j < cues.length; j++) {
      if (cues[j].cue.kind == c.cue.kind) {
        nextSame = strapOf(cues[j].at) - 150;
        break;
      }
    }
    final cueS = (at / 1000).toStringAsFixed(2);
    if (seenAt != null && nextSame != null && seenAt >= nextSame) {
      out.add('ECG touch probe cue $what at strap $cueS s: not seen before '
          'the next ${c.cue.kind == EcgCueKind.touch ? 'TOUCH' : 'LIFT'} '
          'cue.');
    } else if (seenAt == null || seenAt > lastSample) {
      out.add('ECG touch probe cue $what at strap $cueS s: not seen before '
          'the stream ended.');
    } else {
      out.add('ECG touch probe cue $what at strap $cueS s: seen '
          '${seenAt - at} ms later$extra.');
    }
  }
  return out;
}
