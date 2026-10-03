// hardware_probes.dart — scripted hardware measurements for the Device lab (8V, 8W).
//
// The touch counter and the band buzz both depend on things the band does that
// no spec describes: how it takes haptic commands, how long its electrode takes
// to show a finger. Three probes measure them on the real band, under the
// wearer's control, and write everything into the lab log (and, for ECG, the
// raw packets) so the numbers can be documented and the state machine replayed
// off the band.
//
//  * [HapticProbe] — single buzz commands at a series of spacings. Per command:
//    when it was asked for, when its write landed, and the band's own reply (or
//    none). Per trial: the band events that arrived during it and how many
//    "bzz-bzz" plays the wearer FELT (asked after each trial; one command is
//    one bzz-bzz, and one written while the band still plays is swallowed).
//  * [PatternProbe] (8W) — ways of getting a COUNT of buzzes out of the band:
//    four waveforms × four ways of sending (separate commands paced by time or
//    by the band's "ended" event, one command with its loop raised, one command
//    listing the waveform several times; 8Y adds a "delayed" way for gap
//    tests). Played on demand, one test at a time: per play, the payloads,
//    write times, replies, live band events and the measured silences and
//    buzzes. What the wearer felt is transcribed elsewhere.
//  * [EcgTouchProbe] — a cued touch / lift script on a live ECG stream: the
//    phone shows (and the phone itself vibrates) TOUCH / LIFT on a schedule;
//    afterwards [analyzeTouchProbe] lines each cue up with the contact runs and
//    the band's presence flag.
//
// SAFETY AND HARDWARE HEALTH. All probes start only from an explicit button,
// stop at once on Stop or a lost link, and are bounded: the buzz probe sends at
// most [HapticProbe.maxCommands] short buzzes per run and the pattern probe at
// most [PatternProbe.maxCommandsPerWindow] short commands in any
// [PatternProbe.commandWindow] (each play waits for the band to finish the
// last one);
// the ECG probe streams for at most [EcgTouchProbe.maxStream] and always stops
// the stream (in `finally`). The buzz and ECG probes send nothing the app does
// not already send. The pattern probe DOES send new waveform bytes (the same
// RUN_HAPTIC_PATTERN_MAVERICK opcode with other effect ids), but only validated
// ones: 1..8 effects of 1..255 and a loop of 1..3 ([AlarmPayloads.
// gen5MaverickPattern] refuses anything else), only on a gen5 link, and never a
// dangerous opcode. Every flag is reset in `finally`, so a failure never wedges
// the lab.
//
// Pure Dart with injected effects: no Flutter, no BLE, no clock of its own.

import 'dart:async';

import 'package:openstrap_protocol/openstrap_protocol.dart' show LabradorR17;

import '../ble/ble_state.dart' show AlarmPayloads;
import '../haptics/band_queue.dart' show BandCommandLedger;

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
        .where((c) =>
            c.reply != null && c.reply != 'none' && c.reply != 'not written')
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
        // Nothing reached the band: there is nothing to feel, and buzzing on
        // would only repeat the refusal.
        if (r.commands.isNotEmpty &&
            r.commands.every((c) => c.written != true)) {
          step?.call(r.summary);
          step?.call('Buzz probe ended: the app sent no buzz in this trial '
              '(see the reason above).');
          return results;
        }
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

// ------------------------------------------------------------ pattern probe

/// A waveform to try: a name for the log and the effect ids of one play of it.
class BuzzWaveform {
  const BuzzWaveform(this.name, this.effects);
  final String name;
  final List<int> effects;

  /// The band's own pair, then single effects (47 is its first half; 14 and 1
  /// are ids the protocol notes list as plausible).
  static const List<BuzzWaveform> all = [
    BuzzWaveform('band pair 47+152', [47, 152]),
    BuzzWaveform('effect 47 alone', [47]),
    BuzzWaveform('effect 14', [14]),
    BuzzWaveform('effect 1', [1]),
  ];
}

/// Ways of getting a count of buzzes out of the band.
enum BuzzStyle {
  /// Separate commands, each a fixed 1.8 s after the previous write.
  paced,

  /// Separate commands, each just after the band says the last one ended.
  eventPaced,

  /// One command with its loop count raised.
  repeat,

  /// One command listing the waveform several times.
  listed,

  /// Separate commands, each [PatternTest.delayMs] after the band says the
  /// last one ended (8Y: how long a silence is felt as).
  delayed,
}

class PatternTest {
  const PatternTest({
    required this.waveform,
    required this.style,
    required this.count,
    this.delayMs = 0,
  });
  final BuzzWaveform waveform;
  final BuzzStyle style;
  final int count;

  /// Wait after the band's "ended" before the next command; delayed only.
  final int delayMs;

  /// Band commands this test writes.
  int get commands => (style == BuzzStyle.paced ||
          style == BuzzStyle.eventPaced ||
          style == BuzzStyle.delayed)
      ? count
      : 1;

  /// The waveform written [count] times into one command's slots; a lone effect
  /// gets a 152 slot between copies (the pair already ends in one).
  List<int> get listedEffects {
    final e = waveform.effects;
    return [
      for (var i = 0; i < count; i++) ...[
        if (i > 0 && e.length == 1) 152,
        ...e,
      ],
    ];
  }

  String get description => switch (style) {
        BuzzStyle.paced => '${waveform.name}, $count commands 1.8 s apart',
        BuzzStyle.eventPaced => '${waveform.name}, $count commands, each '
            'after the band says the last one ended',
        BuzzStyle.repeat => '${waveform.name}, one command looped $count×',
        BuzzStyle.listed => '${waveform.name}, one command listing it '
            '$count× with a pause slot between',
        BuzzStyle.delayed => '${waveform.name}, $count commands, the second '
            '$delayMs ms after the first ends',
      };
}

/// One command of a pattern test. Times are ms since the test started.
class PatternCommandResult {
  PatternCommandResult(this.effects, this.loop, this.startMs);
  final List<int> effects;
  final int loop;
  final int startMs;
  int? writtenMs;
  bool written = false;
  String? reply;
}

class PatternTestResult {
  PatternTestResult(this.test);
  final PatternTest test;
  final List<PatternCommandResult> commands = [];
  final List<HapticBandEvent> events = [];

  /// 8Z: phone receive time (ms) of the first live 60.
  int? get _firstStartMs {
    for (final e in events) {
      if (e.eventId == 60) return e.receivedMs;
    }
    return null;
  }

  /// 8Z: how long the play took, the first live 60 to the last live 100 after
  /// it (phone receive times, ms); null when either is missing.
  int? get spanMs {
    final first = _firstStartMs;
    if (first == null) return null;
    int? last;
    for (final e in events) {
      if (e.eventId == 100 && e.receivedMs >= first) last = e.receivedMs;
    }
    return last == null ? null : last - first;
  }

  /// 8Z: the Bluetooth delay, the first live 60 minus the moment the first
  /// command's write landed (ms); null without a live 60 or a landed write.
  int? get leadMs {
    final first = _firstStartMs;
    if (first == null) return null;
    for (final c in commands) {
      if (c.written && c.writtenMs != null) return first - c.writtenMs!;
      break;
    }
    return null;
  }
}

/// Plays one pattern test at a time, on demand (8Y): the wearer presses Play
/// for the test on screen, as often as they like, and transcribes what they
/// felt elsewhere. The probe only sends, waits for the band and logs.
/// The id of [kWhoopMgPatternProbeSet], written to the lab log when a pattern
/// session opens so a transcribed log says which input set it answers.
const String kWhoopMgPatternProbeSetId = 'whoop-mg-pattern-v1';

/// The stable probe input set (8AC): 4 waveforms × 4 ways of sending × counts
/// 2 and 3, cycling so an early stop still has seen every waveform and every
/// way; then 8 gap tests: two delayed commands, effect 14 then 47
/// alternating, a delay of 0, 300, 700, 1200 ms for each. Test number N is
/// index N - 1; the order must never change, because every transcribed log and
/// the device profile cite tests by number.
final List<PatternTest> kWhoopMgPatternProbeSet = List.unmodifiable([
  for (var i = 0; i < 32; i++)
    PatternTest(
      waveform: BuzzWaveform.all[i % 4],
      style: BuzzStyle.values[(i ~/ 4) % 4],
      count: i < 16 ? 2 : 3,
    ),
  for (var j = 0; j < 8; j++)
    PatternTest(
      waveform: BuzzWaveform.all[j.isEven ? 2 : 1],
      style: BuzzStyle.delayed,
      count: 2,
      delayMs: const [0, 300, 700, 1200][j ~/ 2],
    ),
]);

/// Why [PatternProbe.play] refused a play (8AB).
enum PatternRefusal { busy, notConnected, resting }

class PatternProbe {
  PatternProbe({
    required this.sendPattern,
    required this.isConnected,
    this.step,
    DateTime Function()? now,
    Future<void> Function(Duration)? wait,
    List<PatternTest>? tests,
    List<DateTime>? writeLog,
  })  : _now = now ?? DateTime.now,
        _wait = wait ?? ((d) => Future<void>.delayed(d)),
        tests = tests ?? defaultTests,
        _writes = writeLog ?? <DateTime>[];

  /// Hardware health: at most this many commands in any [commandWindow].
  static const int maxCommandsPerWindow = BandCommandLedger.maxCommands;
  static const Duration commandWindow = BandCommandLedger.window;

  /// Gap between paced commands, and the wait for a band "ended" event.
  static const Duration pacedGap = Duration(milliseconds: 1800);
  static const Duration eventTimeout = Duration(milliseconds: 2500);
  static const Duration afterEnded = Duration(milliseconds: 100);

  /// Longest wait for the band's "ended" after a write, in a play's last wait
  /// and in the cool-down before the next play.
  static const Duration settle = Duration(seconds: 4);
  static const Duration _poll = Duration(milliseconds: 100);

  /// A band event counts only when it happened no earlier than this before
  /// the play started, and reached the phone within [_liveWithin].
  static const Duration _liveBefore = Duration(milliseconds: 500);
  static const Duration _liveWithin = Duration(seconds: 2);

  /// The stable probe input set (8AC), [kWhoopMgPatternProbeSet]: 4 waveforms
  /// × 4 ways of sending × counts 2 and 3, then 8 gap tests.
  static final List<PatternTest> defaultTests = kWhoopMgPatternProbeSet;

  /// One custom pattern command. True when the write landed; [onReply] hears
  /// the band's reply status (null: none) and its latency.
  final Future<bool> Function(List<int> effects, int loop,
      void Function(String? status, int ms) onReply) sendPattern;

  final bool Function() isConnected;
  final void Function(String line)? step;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _wait;
  final List<PatternTest> tests;

  /// When each command was written, oldest first. Pass the same list to the
  /// next probe so closing and reopening the screen does not reset the limit.
  final List<DateTime> _writes;
  PatternRefusal? _refusal;
  DateTime? _restUntil;

  bool _running = false;
  bool _stop = false;
  DateTime? _playStart;
  DateTime? _testStart;
  DateTime? _writeStart;
  DateTime? _lastLanded;
  bool _ended = false;
  PatternTestResult? _current;

  bool get running => _running;

  /// Why the latest play was refused; null when it was accepted (or none yet).
  PatternRefusal? get lastRefusal => _refusal;

  /// When the band has rested enough, after a "resting" refusal; null
  /// otherwise (and after the next accepted play).
  DateTime? get restUntil => _restUntil;

  /// Time left until [restUntil] at [now]; null when not resting or ready.
  Duration? restRemaining(DateTime now) {
    final u = _restUntil;
    if (u == null || !now.isBefore(u)) return null;
    return u.difference(now);
  }

  void _refuse(PatternRefusal why, String line, {DateTime? until}) {
    _refusal = why;
    _restUntil = until;
    step?.call(line);
  }

  /// Abort the waits and the commands still to come.
  void stop() => _stop = true;

  /// A band event (any id) arrived. Only LIVE events count: the band delivers
  /// old 60/100 events late, in bursts, and they must not release commands.
  /// A live 100 after the latest write marks that write as ended.
  void onBandEvent(int eventId, DateTime receivedAt, DateTime happenedAt) {
    if (receivedAt.difference(happenedAt) >= _liveWithin) return;
    final p = _playStart;
    if (p != null && happenedAt.isBefore(p.subtract(_liveBefore))) return;
    final cur = _current, t0 = _testStart;
    if (cur != null && t0 != null) {
      cur.events.add(HapticBandEvent(
        eventId,
        receivedAt.difference(t0).inMilliseconds,
        happenedAt.difference(t0).inMilliseconds,
      ));
    }
    final w = _writeStart;
    if (eventId == 100 && w != null && !receivedAt.isBefore(w)) _ended = true;
  }

  /// Play [t] once. Null (with the reason logged) when a play is going, the
  /// band is not connected, the band must rest first (the rolling limit), the
  /// play was stopped before writing, or nothing was written. The refusals
  /// are decided before the first await, so a caller can read [lastRefusal]
  /// right after calling.
  Future<PatternTestResult?> play(PatternTest t) async {
    if (_running) {
      _refuse(PatternRefusal.busy, 'Pattern probe: a play is already going.');
      return null;
    }
    if (!isConnected()) {
      _refuse(PatternRefusal.notConnected,
          'Pattern probe: the band is not connected.');
      return null;
    }
    final now = _now();
    _writes.removeWhere((w) => !w.add(commandWindow).isAfter(now));
    final over = _writes.length + t.commands - maxCommandsPerWindow;
    if (over > 0 && _writes.isNotEmpty) {
      // Enough of the oldest writes must leave the window.
      final until = _writes[(over - 1).clamp(0, _writes.length - 1)]
          .add(commandWindow);
      final secs = (until.difference(now).inMilliseconds / 1000).ceil();
      _refuse(
        PatternRefusal.resting,
        'Pattern probe: resting the band; ready in $secs s '
        '($maxCommandsPerWindow commands per ${commandWindow.inMinutes} '
        'minutes).',
        until: until,
      );
      return null;
    }
    _refusal = null;
    _restUntil = null;
    _running = true;
    _stop = false;
    _playStart = _now();
    try {
      if (!await _coolDown()) {
        step?.call('Pattern probe: stopped before the play.');
        return null;
      }
      final r = await _runTest(t);
      step?.call(_summary(r));
      if (r.commands.isEmpty || r.commands.every((c) => !c.written)) {
        step?.call('Pattern probe: the app sent no buzz in this play (see '
            'the reason above).');
        return null;
      }
      return r;
    } finally {
      _running = false;
      _current = null;
      _testStart = null;
      _playStart = null;
    }
  }

  /// The band drops a command sent while it plays: wait for a live 100 after
  /// the previous play's last write, or [settle] since that write.
  Future<bool> _coolDown() async {
    final w = _lastLanded;
    if (w == null) return true;
    while (!_stop && !_ended) {
      final left = settle - _now().difference(w);
      if (left <= Duration.zero) break;
      await _wait(left < _poll ? left : _poll);
    }
    return !_stop;
  }

  Future<PatternTestResult> _runTest(PatternTest t) async {
    final r = _current = PatternTestResult(t);
    final t0 = _testStart = _now();
    _writeStart = null;
    _ended = false;
    int ms() => _now().difference(t0).inMilliseconds;

    Future<bool> write(List<int> effects, int loop) async {
      final c = PatternCommandResult(effects, loop, ms());
      r.commands.add(c);
      _writes.add(_now());
      _ended = false;
      _writeStart = _now();
      try {
        c.written = await sendPattern(effects, loop, (status, _) {
          c.reply = status ?? 'none';
        });
      } catch (_) {
        c.written = false;
      }
      c.writtenMs = ms();
      _lastLanded = _now();
      if (!c.written) c.reply ??= 'not written';
      return c.written;
    }

    // Wait up to [limit] in poll steps, ending early on Stop or (when
    // [forEnd]) on the band's 100. True when the 100 came.
    Future<bool> waitFor(Duration limit, {required bool forEnd}) async {
      var waited = Duration.zero;
      while (waited < limit && !_stop && !(forEnd && _ended)) {
        final d = limit - waited < _poll ? limit - waited : _poll;
        await _wait(d);
        waited += d;
      }
      return _ended;
    }

    final effects = t.waveform.effects;
    switch (t.style) {
      case BuzzStyle.repeat:
        await write(effects, t.count);
      case BuzzStyle.listed:
        await write(t.listedEffects, 1);
      case BuzzStyle.paced:
      case BuzzStyle.eventPaced:
      case BuzzStyle.delayed:
        for (var i = 0; i < t.count; i++) {
          if (_stop || !isConnected()) break;
          if (!await write(effects, 1) || i == t.count - 1) break;
          if (t.style == BuzzStyle.paced) {
            await _wait(pacedGap);
          } else if (await waitFor(eventTimeout, forEnd: true) && !_stop) {
            final after = t.style == BuzzStyle.delayed
                ? Duration(milliseconds: t.delayMs)
                : afterEnded;
            if (after > Duration.zero) await _wait(after);
          }
        }
    }
    // Let the last command play out: its 100, or the settle time.
    if (!_stop && r.commands.any((c) => c.written)) {
      await waitFor(settle, forEnd: true);
    }
    _current = null;
    return r;
  }

  String _summary(PatternTestResult r) {
    final cs = r.commands;
    final at = tests.indexWhere((x) => identical(x, r.test));
    final hex = cs.isEmpty
        ? ''
        : ' [${AlarmPayloads.gen5MaverickPattern(cs.first.effects, loop: cs.first.loop).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}]';
    final writes = cs.any((c) => c.written)
        ? 'written at ${cs.map((c) => c.written ? '+${c.writtenMs}' : 'not written').join(', ')} ms'
        : 'not written';
    final replies = cs.map((c) => c.reply ?? 'none').join(', ');
    final ev = r.events.isEmpty
        ? 'none'
        : r.events
            .map((e) =>
                '${e.eventId} at +${e.happenedMs} (got +${e.receivedMs})')
            .join(', ');
    // Silence = a live 60 minus the 100 before it; buzz = a 100 minus its 60
    // (phone receive times), so felt lengths can be fitted to real ones.
    final silences = <int>[], buzzes = <int>[];
    int? started, ended;
    for (final e in r.events) {
      if (e.eventId == 60) {
        if (ended != null) silences.add(e.receivedMs - ended);
        started = e.receivedMs;
        ended = null;
      } else if (e.eventId == 100 && started != null) {
        buzzes.add(e.receivedMs - started);
        ended = e.receivedMs;
        started = null;
      }
    }
    final measured = '${silences.isEmpty ? '' : '; silences: ${silences.join(', ')}'}'
        '${buzzes.isEmpty ? '' : '; buzzes: ${buzzes.join(', ')}'}';
    return 'Pattern probe play: ${at < 0 ? '?' : at + 1}/${tests.length}, '
        '${r.test.description}: '
        '${cs.length} ${cs.length == 1 ? 'command' : 'commands'}$hex, $writes, '
        'replies $replies; band events $ev$measured.';
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
