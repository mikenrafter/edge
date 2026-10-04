// ecg_tap_session.dart — runs one EcgTapCounter against the live ECG stream.
//
// The pure counter (ecg_tap_counter.dart) decides; this file feeds it. For one
// live double tap it: starts the ECG stream, WAITS until real R17 packets are
// flowing ([EcgStreamReadiness]) and the sensor has settled ([sensorSettle]),
// opens the first touch window there, turns each R17 packet into 100 Hz samples
// on the stream's own clock, asks for one cue per decision, and stops the stream
// when the gesture ends. The cues are additive: the start cue ([startBuzz],
// 8AI) goes out the moment the tap is accepted and is never waited for, so the
// wearer's hand is on the sensor by the time the stream runs (a touch that
// comes late counts as a double tap, not a triple); then ONE follow-up
// ([buzz]) per count increment, as soon as it is seen; then the confirm
// ([confirmBuzz]) when the gesture ends counted. Each is its own call, in
// order, and the band queue spaces them. The one wait the session adds is the
// window after a follow-up (8AK): the wearer is feeling that cue, so the window
// for the next touch opens only once the band has finished playing it
// ([bandIdle]), never from the touch itself.
// No sample is persisted (invariant 14): the packets are consumed and dropped
// here. The one thing kept is the session's strap-clock INTERVAL (see
// [EcgGestureRecord]): turning the stream on makes the band save raw ECG that
// ordinary history sync delivers later, and the receiving side needs the
// interval to label those packets as gesture contact (8N), never a reading.
//
// Time. Every touch decision is on the stream's own (strap) sample clock, and
// only on it: a packet's strap time is its NEWEST sample and its samples run
// back from there (see PACKET TIME in ecg_stream_readiness.dart). The first
// window opens at a sample time ([sensorSettle] after the stream's first
// sample), not at a phone time mapped across. The phone clock is only used to
// notice a stalled stream. The stream is called steady only
// when the sample clock is continuous and in step with the wall clock
// ([EcgStreamReadiness]). Missing samples are the counter's discontinuity
// policy (see ecg_tap_counter.dart). The trace prints, per packet, where its
// contact sits, how far it sits behind the freshest packet and whether it
// continues the previous one.
//
// A start that fails (refused, throws, times out) is tried once more inside the
// same gesture before the double-tap fallback is taken (8AK): the 2026-10-04 lab
// log shows the band refusing a start that the very next one accepted. The retry
// only ever calls the injected [beginStream]/[endStream]; it names no opcode.
//
// Why the wait: a start command being written only means the command left the
// phone. The band can take many seconds to begin sending, and then its sensor
// reads zero for a while even with a finger on it. Startup is slow, so
// [startTimeout] is generous (20 s).
//
// Everything that touches the world is injected (stream start/stop, buzz,
// clocks), so the latch discipline is testable. One gesture at a time; every
// exit (done, abandon, a throw while starting) goes through [_finish], which
// resets every flag in `finally` (a sticky flag here would swallow every later
// double tap until the app is restarted).
//
// The step trace (for the Device lab) names every stage with its timing: the
// tap, the stream command written, the first packet, the stream steady, the
// touch window open, every buzz (and any wait before it), and every packet in
// between (number, samples, how many show contact and where, strap time, gap
// since the last).

import 'dart:async';

import 'package:openstrap_protocol/openstrap_protocol.dart' show LabradorR17;

import '../notify/alert_rule.dart';
import 'ecg_contact.dart';
import 'ecg_presence_gate.dart';
import 'ecg_stream_readiness.dart';
import 'ecg_tap_counter.dart';
import 'ecg_tap_mode.dart';
import 'strap_event.dart';

/// The band buzz for each count step: band-only, live-only, a few seconds of
/// life, like the tap acknowledgement.
const AlertRule kEcgTapRule = AlertRule(
  id: 'gesture_ecg_tap',
  kind: 'gesture',
  destinations: AlertRule.band,
  executionMode: AlertExecutionMode.phoneLive,
  historicalReplay: AlertHistoricalReplay.liveOnly,
  fallback: AlertFallback.none,
  staleAfter: kLiveEventWindow,
  channelPolicyId: 'gesture',
);

/// What a finished gesture leaves behind: its interval on the STRAP clock
/// (whole seconds, the same clock as `ecg_raw_packet.strap_seconds`) and the
/// outcome. No samples. [strapStart]/[strapEnd] are null when the session never
/// learned the strap clock.
class EcgGestureRecord {
  const EcgGestureRecord({
    required this.strapStart,
    required this.strapEnd,
    required this.finalCount,
    required this.reason,
    this.fellBackToSamples = false,
  });

  final int? strapStart;
  final int? strapEnd;

  /// The final count, or null when the gesture was abandoned.
  final int? finalCount;

  /// Why it was abandoned (null when counted).
  final String? reason;

  /// Fast mode only: the band never reported presence while the samples showed
  /// contact, so the presence veto was lifted for the rest of the gesture.
  final bool fellBackToSamples;

  @override
  String toString() =>
      'EcgGestureRecord($strapStart..$strapEnd count=$finalCount reason=$reason'
      '${fellBackToSamples ? ' fellBackToSamples' : ''})';
}

class EcgTapSession {
  EcgTapSession({
    required this.beginStream,
    required this.endStream,
    required this.isStreamAlive,
    required this.buzz,
    required this.maxTaps,
    required this.thresholds,
    required this.onFinished,
    this.failBuzz,
    this.startBuzz,
    this.confirmBuzz,
    this.onStarted,
    this.recordSession,
    this.onPacket,
    this.bandIdle,
    this.onFailed,
    this.strapNow,
    this.step,
    this.tapMode,
    this.beginFastStream,
    this.presenceFallbackPackets,
    DateTime Function()? now,
    this.stallAfter = const Duration(seconds: 3),
    this.maxSampleGap = const Duration(milliseconds: 50),
    this.startTimeout = const Duration(seconds: 20),
    this.pollEvery = const Duration(milliseconds: 250),
    this.beginTimeout = const Duration(seconds: 15),
    this.endTimeout = const Duration(seconds: 5),
    this.recordTimeout = const Duration(seconds: 5),
    this.buzzTimeout = const Duration(seconds: 15),
    this.sensorSettle = const Duration(milliseconds: 2500),
    this.sensorReacquire = const Duration(milliseconds: 1500),
    Duration Function()? postRoll,
    Future<void> Function(Duration)? wait,
  })  : _now = now ?? DateTime.now,
        _wait = wait ?? ((d) => Future<void>.delayed(d)),
        _postRoll = postRoll ?? (() => Duration.zero);

  /// Start the ECG stream; true when the command went out and the controller is
  /// running. It does NOT mean packets are flowing: see [EcgStreamReadiness].
  final Future<bool> Function() beginStream;

  /// The ECG tap mode in force, read when a gesture begins. Null: accurate.
  final EcgTapMode Function()? tapMode;

  /// Fast mode's stream start, called INSTEAD of [beginStream]: the same ECG
  /// stream without the raw-save the readings need. Null: fast mode is not
  /// available and the gesture runs accurate.
  final Future<bool> Function()? beginFastStream;

  /// Packets of sample contact without presence before the presence veto is
  /// lifted (fast mode). Null: [kEcgPresenceFallbackPackets].
  final int? presenceFallbackPackets;

  /// Stop it and clean up. Never throws.
  final Future<void> Function() endStream;

  /// Whether the stream is still up (false after a link drop or timeout).
  final bool Function() isStreamAlive;

  /// Ask the band for ONE follow-up cue for [eventId], through AlertDispatcher:
  /// called once per count increment (3, 4, 5), never for the opening count of
  /// 2. [pulses] is always 1 (an increment is one follow-up, not a recount).
  /// True when the buzz was WRITTEN to the band (the band's reply is not
  /// awaited), false when it could not be.
  final Future<bool> Function(int pulses, String eventId) buzz;

  /// The confirm cue, through AlertDispatcher: called once when the gesture
  /// ends counted, after the follow-up it closes, with the event id
  /// `<gesture id>:ecg:confirm`. Null: no confirm.
  final Future<bool> Function(String eventId)? confirmBuzz;

  final int Function() maxTaps;
  final EcgTapThresholds Function() thresholds;

  /// The gesture ended: [count] taps, or null when abandoned (with [reason]).
  final void Function(int? count, String? reason) onFinished;

  /// One long buzz for a failed ECG (8X), through AlertDispatcher: called once
  /// per failed gesture with the event id `<gesture id>:failed`, queued behind
  /// any count buzz. True when it was written to the band.
  final Future<bool> Function(String eventId)? failBuzz;

  /// The gesture-start cue (8AI), through AlertDispatcher: called once, in the
  /// same turn the tap is accepted and BEFORE the stream is asked to start,
  /// with the event id `<gesture id>:ecg:start`. [start] never waits for it:
  /// ECG monitoring begins at once and the buzz plays beside it. A buzz that
  /// throws or is not written is logged and changes nothing else.
  final Future<bool> Function(String eventId)? startBuzz;

  /// A gesture began: the tap and a one-line description of the thresholds in
  /// force, for the Device lab's session summary.
  final void Function(StrapEvent tap, String settings)? onStarted;

  /// Write the finished gesture's interval (8N). Called once on EVERY exit
  /// (counted, abandoned, link lost, start failed), after [onFinished] and AFTER
  /// the stream has been stopped, with an end that covers the stop. May throw:
  /// the failure is swallowed, so a storage error can never wedge the latch.
  final Future<void> Function(EcgGestureRecord record)? recordSession;

  /// The strap clock now, in whole seconds, estimated from the phone-to-strap
  /// clock correlation; null when unknown. Only used for a session that never
  /// saw a packet (a start that failed), so the interval is a coarse estimate
  /// there and exact (from the packets) everywhere else.
  final int? Function()? strapNow;

  /// Completes once the band has finished playing everything queued so far:
  /// every cue delivered AND its plan ended (the band queue's settle, not the
  /// write). Awaited after each follow-up cue, bounded by [buzzTimeout], before
  /// the window for the next touch opens. Null: nothing waits and the window
  /// follows the touch as before.
  final Future<void> Function()? bandIdle;

  /// A gesture FAILED (start_failed, no_stream, link_lost, stalled,
  /// sample_gap): called once, with the abandon reason as such, after the start
  /// retry (if any) was used up. Never for a gesture that counted and never for
  /// an attempt that is retried. May throw: it is swallowed.
  final void Function(StrapEvent tap, String reason)? onFailed;

  /// A line for the Device lab's trace.
  final void Function(String line)? step;

  /// Every packet this gesture saw (and, during a post-roll, saw after it
  /// ended), with when the phone got it: the Device lab keeps them in RAM for
  /// "Save lab log file" so a session can be replayed off the band. Never stored.
  final void Function(LabradorR17 r, DateTime receivedAt)? onPacket;

  final DateTime Function() _now;

  /// Packets arrive roughly once a second, so the counter's sample-clock stall
  /// timeout is a few packets, not its 500 ms default.
  final Duration stallAfter;

  /// Samples further apart than this are a discontinuity: see
  /// [EcgTapCounter.maxSampleGap].
  final Duration maxSampleGap;

  /// No steady stream this long after the stream command was written abandons
  /// (`no_stream`). Startup is slow; do not give up early.
  final Duration startTimeout;
  final Duration pollEvery;

  // Every call out of this class is bounded, so a write or a database that
  // never answers ends in a give-up state instead of a latch that swallows
  // every later double tap:
  //  * [beginTimeout] — the stream-start command (a BLE write). On expiry the
  //    start fails and a late-starting stream is stopped.
  //  * [endTimeout] — stopping the stream.
  //  * [recordTimeout] — writing the gesture interval. It runs AFTER the stream
  //    is stopped (8N), so a stuck database can neither keep the stream running
  //    nor leave the end of the recording outside the stored interval.
  //  * [buzzTimeout] — one band buzz. A buzz that never answers counts as not
  //    written (logged; the count stands), and the buzzes after it, this
  //    gesture's or the next one's, are not queued behind it forever.
  final Duration beginTimeout, endTimeout, recordTimeout, buzzTimeout;

  /// How long after the stream's first sample the sensor's zeros mean "no
  /// finger". Measured, not specified: in the 2026-10-02 lab log every session
  /// with a finger resting on the sensor read 0 for the whole second packet
  /// (100 samples) and showed contact again only in the last ~140 ms of the
  /// third, about 2.35 s after the first sample. The first window opens here,
  /// so its deadline is [sensorSettle] + start after the first sample.
  final Duration sensorSettle;

  /// How long the sensor itself takes to show a finger that came back after a
  /// lift, added to every window after a lift ([EcgTapCounter.reacquire]).
  /// Measured, not specified: in the 2026-10-02 18:17 lab log the only two
  /// re-touches that showed up did so 1.96 s and 2.16 s after the lift, both
  /// at sample 76 of a packet (the band reports contact again at a fixed phase
  /// of its packet cycle), while a lift showed as zeros within ~0.2 s of the
  /// wearer feeling the buzz. With gap 200 and confirm 1000 that window closed
  /// 1.2 s after the lift, before either re-touch could appear. The 20:40 log
  /// explains it: a touch shows ~1.9 s after the finger lands whatever the
  /// lift before it lasted, so this is the sensor's touch latency, not a hold
  /// that depends on the lift.
  final Duration sensorReacquire;

  /// Lab only: how long to keep the stream on after the gesture ended, so the
  /// trace shows what the sensor did next (a re-touch that came too late, for
  /// one). The result is reported at once; only the stop waits. Zero outside
  /// the lab.
  final Duration Function() _postRoll;

  final Future<void> Function(Duration) _wait;

  static const Duration _samplePeriod = Duration(milliseconds: 10); // 100 Hz

  bool _active = false;
  // 8X: whether the one retry was used, and the thresholds this gesture runs
  // on. Both reset when the gesture ends.
  bool _retried = false;
  EcgTapThresholds? _th;
  bool _streamUp = false;
  bool _opened = false; // the counter has started and its first window is open
  Duration? _firstSampleAt; // the stream's first sample, on the sample clock
  EcgTapCounter? _counter;
  // 8AN fast mode, fixed when the gesture begins: no readiness or settle wait,
  // and the band's presence bit vetoes each packet's sample contact ([_gate]).
  bool _fast = false;
  EcgPresenceGate? _gate;
  bool _fallbackLogged = false;
  // The last presence / sample-contact state the trace reported (8AN A).
  bool _presenceOn = false, _sampleOn = false;
  EcgStreamReadiness _readiness = EcgStreamReadiness();
  EcgSampleClock _clock = EcgSampleClock();
  Duration? _prevEnd; // sample time just after the previous packet's last sample
  StrapEvent? _tap;
  DateTime? _tapAt; // when the phone got the tap (never in the future)
  Timer? _timer;
  DateTime? _startedAt;
  DateTime? _lastFrameWall;
  Duration? _lastEnd;
  int _packets = 0;
  int _buzzes = 0;
  // Cues are requested in the order they are decided, one call at a time, and
  // that order survives session cleanup (the final follow-up and the confirm
  // are still in flight when the gesture ends).
  Future<void> _buzzTail = Future<void>.value();

  bool _postRolling = false;
  int _postPackets = 0;
  int? _postEndStrapSec;

  // The strap-clock interval seen on the wire this session (8N).
  int? _firstStrapSec, _lastEndStrapSec, _strapAtBegin;

  bool get active => _active;

  /// Whether the gesture in flight runs in fast mode (false when idle): the
  /// stream start reads it to leave out the raw-save.
  bool get fast => _active && _fast;

  int _generation = 0;
  Future<void>? _stopInFlight;

  /// Which gesture this is: bumped by every [start] that actually begins one.
  /// Whatever awaits on a gesture's behalf (the stream start, the wrist lookup)
  /// compares it after each await and stands down when the gesture is gone, so
  /// a slow start can never switch the stream on for a dead gesture.
  int get generation => _generation;

  int _sinceTap() {
    final at = _tapAt;
    return at == null ? 0 : _now().difference(at).inMilliseconds;
  }

  /// Begin the gesture for a live double tap. Returns once the stream command
  /// has gone out (the rest happens as packets arrive). Throws if it could not
  /// start, with every flag already reset, so the caller can give the tap's
  /// claim back. A failed start is tried once more first (8AK); if that fails
  /// too, with the double-tap fallback on (8X) it does not throw: the gesture
  /// ends with count 2. A second tap while one gesture runs is ignored.
  Future<void> start(StrapEvent tap) async {
    // The previous gesture's stop may still be in flight (bounded by
    // [endTimeout]). Starting a stream before it lands would let that stop
    // switch the NEW stream off.
    final prior = _stopInFlight;
    if (prior != null) await prior;
    if (_active) return;
    _active = true;
    _retried = false;
    final gen = ++_generation;
    _tap = tap;
    final now = _now();
    _tapAt = tap.receivedAt.isAfter(now) ? now : tap.receivedAt;
    _strapAtBegin = _strapNowSafe();
    final t = _th = thresholds();
    _fast = beginFastStream != null && _modeNow() == EcgTapMode.fast;
    _newAttempt();
    try {
      onStarted?.call(tap, t.summary);
    } catch (_) {}
    step?.call('Double tap received. Starting the ECG stream.');
    if (_fast) {
      step?.call('Fast mode: no raw-save, no wait for the stream to settle; '
          "the band's presence flag vetoes contact it does not confirm.");
    }
    _fireCue(tap, startBuzz);
    await _startStream(gen);
  }

  EcgTapMode _modeNow() {
    try {
      return tapMode?.call() ?? EcgTapMode.accurate;
    } catch (_) {
      return EcgTapMode.accurate;
    }
  }

  /// The start cue, sent without waiting: a throw, a late failure and a "not
  /// written" are logged and nothing more. The band queue holds the cues that
  /// follow it until it has played.
  void _fireCue(StrapEvent tap, Future<bool> Function(String eventId)? send) {
    if (send == null) return;
    try {
      send('${_eventBase(tap)}:ecg:start').then((ok) {
        step?.call(ok
            ? 'Start buzz written.'
            : 'Start buzz could not be written.');
      }, onError: (Object e) => step?.call('Start buzz failed: $e'));
    } catch (e) {
      step?.call('Start buzz failed: $e');
    }
  }

  // The id every buzz of this gesture is built on: the tap's own identity, made
  // unique when the band's clock is not trusted.
  String _eventBase(StrapEvent tap) => tap.plausible
      ? tap.identity
      : '${tap.identity}:${tap.receivedAt.microsecondsSinceEpoch}';

  /// A fresh counter, readiness and clock: the first try's, or the retry's.
  void _newAttempt() {
    _counter = EcgTapCounter(
      max: maxTaps(),
      thresholds: _th!,
      stallAfter: stallAfter,
      maxSampleGap: maxSampleGap,
      reacquire: sensorReacquire,
    );
    _readiness = EcgStreamReadiness();
    _clock = EcgSampleClock();
    _prevEnd = null;
    _gate = _fast
        ? EcgPresenceGate(
            fallbackPackets:
                presenceFallbackPackets ?? kEcgPresenceFallbackPackets)
        : null;
    _fallbackLogged = false;
    _presenceOn = _sampleOn = false;
  }

  Future<void> _startStream(int gen) async {
    try {
      final begin = _fast ? beginFastStream! : beginStream;
      if (!await begin().timeout(beginTimeout)) {
        throw StateError('the ECG stream did not start');
      }
      if (!_active || gen != _generation) {
        // Finished while the start was still returning: do not leave the
        // stream running. (Only if no newer gesture owns the stream now.)
        if (gen == _generation) await _endStreamSafely();
        return;
      }
      _streamUp = true;
      _startedAt = _now();
      step?.call(
        'ECG stream command written, ${_sinceTap()} ms after the tap. '
        'Waiting for packets (up to ${startTimeout.inSeconds} s).',
      );
      _timer = Timer.periodic(pollEvery, (_) => poll());
      // Packets may already have arrived while the start was still finishing.
      _maybeOpen();
    } catch (e) {
      step?.call('Could not start: $e');
      // A start that never answered may still land: stop the stream (before
      // the interval is written) so nothing is left streaming for a gesture
      // that has already given up. The caller's own start is generation-checked
      // too (see beginEcgForTap).
      if (gen != _generation) rethrow;
      final stop = e is TimeoutException;
      if (_active && _canRetry(startFailed: true)) {
        await _retry('start_failed', gen, stopStream: stop);
        return;
      }
      // With the fallback on the gesture ends as a double tap and start()
      // does not throw; otherwise the caller gives the tap's claim back.
      final fellBack = await _finish(null, 'start_failed', stopStream: stop);
      if (!fellBack) rethrow;
    }
  }

  /// Whether a failure now may be answered by starting the stream once more:
  /// the retry unused, the touch window not yet open and no touch counted, and
  /// either the stream START failed (always retried, 8AK) or the fallback is off
  /// (any failure before the first touch, 8X).
  bool _canRetry({bool startFailed = false}) {
    final t = _th;
    if (t == null || _retried || _opened) return false;
    if (!startFailed && t.fallbackToDoubleTap) return false;
    return (_counter?.count ?? 0) < 3;
  }

  /// Stop the stream and start it once more inside the same gesture (same tap,
  /// same generation, same lab session). [active] stays true throughout.
  Future<void> _retry(String reason, int gen, {bool stopStream = false}) async {
    _retried = true;
    step?.call('ECG failed ($reason); trying the ECG once more.');
    final up = _streamUp;
    try {
      _timer?.cancel();
    } finally {
      _timer = null;
      _streamUp = false;
      _opened = false;
      _firstSampleAt = null;
      _startedAt = null;
      _lastFrameWall = null;
      _lastEnd = null;
      _packets = 0;
      _newAttempt();
    }
    if (up || stopStream) await _endStreamSafely();
    if (!_active || gen != _generation) return;
    await _startStream(gen);
  }

  Future<void> _endStreamSafely() async {
    try {
      await endStream().timeout(endTimeout);
    } catch (_) {}
  }

  /// One decoded ECG packet. Contact comes from [ecgContactMask]: a 50 ms
  /// block with a moving signal, a run of at least two such blocks (a flat
  /// block, zeros or any constant, is no contact). Unless
  /// [EcgTapThresholds.extraSensitive] is on, everything between a packet's
  /// first and last contact sample is contact too (an ECG trace crosses zero).
  void onFrame(LabradorR17 r) {
    final c = _counter;
    if (!_active || c == null) {
      if (_postRolling) _afterCount(r);
      return;
    }
    final wall = _now();
    _notePacket(r, wall);
    _packets++;
    final prevWall = _lastFrameWall;
    final n = r.samples.length;
    final rawMask = ecgContactMask(r.samples);
    final (raw, rawFirst, rawLast) = _contactOf(rawMask);
    // Fast mode: the band's presence bit vetoes the samples' contact for this
    // packet (see EcgPresenceGate); the trace still reports the raw contact.
    final gate = _gate;
    final mask = gate == null
        ? rawMask
        : gate.filter(rawMask, presence: r.presence);
    final (_, first, last) = _contactOf(mask);
    final fill = !c.thresholds.extraSensitive;
    bool contactAt(int i) =>
        fill ? first >= 0 && i >= first && i <= last : mask[i];
    // PACKET TIME: the strap time is the newest sample; the packet covers
    // [end - n samples, end).
    final end = Duration(microseconds: (r.strapTime * 1000000).round());
    final base = end - _samplePeriod * n;
    final prevEnd = _prevEnd;
    _clock.add(receivedAt: wall, sampleEnd: end);
    final behind = _clock.excessOf(receivedAt: wall, sampleEnd: end)!;
    final gap = prevWall == null
        ? 'first packet'
        : '${wall.difference(prevWall).inMilliseconds} ms since the last packet';
    final String continuity;
    if (prevEnd == null) {
      continuity = 'no earlier packet to compare';
    } else {
      final holeMs = ((base - prevEnd).inMicroseconds / 1000).round();
      continuity = holeMs.abs() <= maxSampleGap.inMilliseconds
          ? 'continuous with the last packet'
          : holeMs > 0
              ? 'gap of $holeMs ms before this packet'
              : 'overlaps the last packet by ${-holeMs} ms';
    }
    step?.call(
      'Packet $_packets: $n samples, $raw with contact'
      '${raw > 0 ? ' (samples $rawFirst–$rawLast)' : ''}'
      '${raw > 0 && first < 0 ? ', vetoed: the band reports no presence' : ''}, '
      'strap time ${r.strapTime.toStringAsFixed(3)} (newest sample), $gap, '
      '$continuity, received ${(behind.inMicroseconds / 1000).round()} ms '
      'behind the freshest packet so far; ${_bandStatus(r)}',
    );
    if (_packets == 1) {
      step?.call('First packet arrived ${_sinceTap()} ms after the tap.');
    }
    // 8AN A: each transition of the band's presence and of the samples' own
    // contact, so one capture gives the band's debounce.
    if (r.presence != _presenceOn) {
      _presenceOn = r.presence;
      step?.call('Presence ${_presenceOn ? 'on' : 'off'}, ${_sinceTap()} ms '
          'after the tap.');
    }
    if ((raw > 0) != _sampleOn) {
      _sampleOn = raw > 0;
      step?.call('Sample contact ${_sampleOn ? 'on' : 'off'}, ${_sinceTap()} ms '
          'after the tap.');
    }
    if (gate != null && gate.fellBack && !_fallbackLogged) {
      _fallbackLogged = true;
      step?.call('Presence fallback: ${gate.fallbackPackets} packets showed '
          'contact in the samples and the band never reported presence; '
          'counting on the samples alone for the rest of the gesture.');
    }
    // Interval bookkeeping: whole strap seconds, start floored and end
    // ceiled, in integers (no float drift at a second boundary).
    final endMsFloor = r.strapSeconds * 1000 + r.subseconds * 1000 ~/ 32768;
    final endMsCeil =
        r.strapSeconds * 1000 + (r.subseconds * 1000 + 32767) ~/ 32768;
    final startSec = (endMsFloor - n * 10) ~/ 1000;
    final endSec = (endMsCeil + 999) ~/ 1000;
    _firstStrapSec = _firstStrapSec == null || startSec < _firstStrapSec!
        ? startSec
        : _firstStrapSec;
    _lastEndStrapSec = _lastEndStrapSec == null || endSec > _lastEndStrapSec!
        ? endSec
        : _lastEndStrapSec;
    _lastFrameWall = wall;
    _lastEnd = end;
    _prevEnd = end;
    final firstSampled = n > 0 && _firstSampleAt == null;
    if (n > 0) _firstSampleAt ??= base;
    if (_fast) {
      // No readiness or settle wait: the counter starts at the first sampled
      // packet and its first window opens at the first packet the presence gate
      // does not hold.
      if (n > 0) _openFast(c, gate!, end, base);
      if (!_active || !_opened) return;
      for (var i = 0; i < n && _active; i++) {
        _handle(c.sample(base + _samplePeriod * i, contact: contactAt(i)));
      }
      return;
    }

    if (!_readiness.ready &&
        _readiness.offer(at: wall, strapTime: r.strapTime, sampleCount: n)) {
      step?.call(
        'Stream is steady, ${_sinceTap()} ms after the tap '
        '(two packets continuous on the sample clock, advancing in step with '
        'the wall clock, within '
        '${EcgStreamReadiness.pairWindow.inMilliseconds} ms of each other).',
      );
    }
    // Quick start: the first sampled packet shows no finger, so a plain double
    // tap is decided now instead of waiting for the sensor to settle.
    if (firstSampled && !c.thresholds.tolerantStartup && _streamUp && !_opened) {
      if (raw == 0) {
        step?.call('Quick start: no finger in the first sampled packet; the '
            'count is 2.');
        _opened = true;
        final tap = _tap;
        if (tap != null) {
          _handle(c.start(tap, at: end));
          if (_active) _handle(c.noFinger(end));
        }
        return;
      }
    }
    _maybeOpen();

    if (!_opened) return;
    // Samples before the window opened are ignored by the counter.
    for (var i = 0; i < n && _active; i++) {
      _handle(c.sample(base + _samplePeriod * i, contact: contactAt(i)));
    }
  }

  /// How many samples of [mask] are contact, and the first and last of them
  /// (-1 when none).
  static (int, int, int) _contactOf(List<bool> mask) {
    var raw = 0, first = -1, last = -1;
    for (var i = 0; i < mask.length; i++) {
      if (!mask[i]) continue;
      raw++;
      if (first < 0) first = i;
      last = i;
    }
    return (raw, first, last);
  }

  /// The band's own view of the packet: its debounced electrode presence,
  /// HeartKey S2 state and flags, progress and signal quality. Logged, not
  /// used to decide anything (yet): the lab needs to see whether presence
  /// tracks a finger faster than the samples do.
  static String _bandStatus(LabradorR17 r) {
    final unreadable = r.unreadable.reasons;
    return 'band: presence ${r.presence ? 'on' : 'off'}, S2 ${r.s2State}, '
        'flags 0x${r.flags.raw.toRadixString(16).padLeft(2, '0')}, '
        'progress ${r.progress}, quality ${r.quality}'
        '${unreadable.isEmpty ? '' : ', unreadable ${unreadable.join('+')}'}';
  }

  void _notePacket(LabradorR17 r, DateTime wall) {
    try {
      onPacket?.call(r, wall);
    } catch (_) {}
  }

  /// A packet that arrived after the gesture ended, during a lab post-roll:
  /// logged (and kept for replay), never counted.
  void _afterCount(LabradorR17 r) {
    final wall = _now();
    _notePacket(r, wall);
    _postPackets++;
    final (raw, first, last) = _contactOf(ecgContactMask(r.samples));
    final endSec = r.strapSeconds +
        ((r.subseconds * 1000 + 32767) ~/ 32768 + 999) ~/ 1000;
    final e = _postEndStrapSec;
    _postEndStrapSec = e == null || endSec > e ? endSec : e;
    step?.call(
      'After the count, packet $_postPackets: ${r.samples.length} samples, '
      '$raw with contact${raw > 0 ? ' (samples $first–$last)' : ''}, strap '
      'time ${r.strapTime.toStringAsFixed(3)}; ${_bandStatus(r)}',
    );
  }

  /// Fast mode's start: the counter begins at the first sampled packet and its
  /// first window opens at that packet's first sample, unless the gate holds it
  /// (samples show contact the band has not confirmed): then the window waits,
  /// so vetoed contact can neither count nor let the first window run out.
  void _openFast(EcgTapCounter c, EcgPresenceGate gate, Duration end,
      Duration base) {
    final tap = _tap;
    if (_opened || tap == null) return;
    if (!c.started) {
      _handle(c.start(tap, at: end)); // max 2 ends here
      if (!_active) return;
    }
    if (gate.holdsFirstWindow) return;
    _opened = true;
    step?.call(
      'Touch window open at sample time ${base.inMilliseconds} ms, at the '
      'first usable packet, ${_sinceTap()} ms after the tap '
      '(${c.thresholds.startMs} ms for the first touch to begin; a finger '
      'already on the sensor counts).',
    );
    _handle(c.open(base));
  }

  /// Start the counter and open its first window, once, when the stream
  /// command has returned AND the packets are steady. The window opens on the
  /// sample clock at [sensorSettle] after the stream's first sample, or at the
  /// end of the newest packet if that is later.
  void _maybeOpen() {
    final c = _counter, tap = _tap, first = _firstSampleAt, end = _lastEnd;
    if (!_active || _opened || !_streamUp || !_readiness.ready) return;
    if (c == null || tap == null || first == null || end == null) return;
    _opened = true;
    _handle(c.start(tap, at: end)); // max 2 ends here
    if (!_active) return;
    final settled = first + sensorSettle;
    final at = settled > end ? settled : end;
    step?.call(
      'Touch window open at sample time ${at.inMilliseconds} ms, '
      '${(at - first).inMilliseconds} ms after the first sample '
      '(${c.thresholds.startMs} ms for the first touch to begin; a finger '
      'already on the sensor counts).',
    );
    _handle(c.open(at));
  }

  /// Stall and liveness checks; also what the periodic timer runs.
  void poll() {
    final c = _counter;
    if (!_active || c == null) return;
    if (!isStreamAlive()) {
      _abandon('link_lost');
      return;
    }
    final start = _startedAt;
    if (_fast && !_opened) {
      // Packets flow but the first window is held by the presence gate: the
      // counter's own stall check does not run before it opens.
      final seen = _lastFrameWall;
      if (seen != null && _now().difference(seen) > stallAfter) {
        _abandon('stalled');
        return;
      }
    }
    if (!(_fast ? _packets > 0 : _readiness.ready) &&
        start != null &&
        _now().difference(start) > startTimeout) {
      step?.call(
        'No steady stream ${startTimeout.inSeconds} s after the stream '
        'command ($_packets packets seen).',
      );
      _abandon('no_stream');
      return;
    }
    final now = _stallNow();
    if (now != null) _handle(c.tick(now));
  }

  void _abandon(String reason) {
    final gen = _generation;
    if (_canRetry()) {
      unawaited(_retry(reason, gen).catchError((Object _) {}));
      return;
    }
    unawaited(_finish(null, reason));
  }

  /// "Now" for STALL detection only: the end of the last packet plus the wall
  /// time since it arrived, so the counter's stall test measures time since the
  /// last packet RECEIVED (a packet that was itself late must not look like a
  /// stalled stream). Null before any packet. Never used to place the touch
  /// window: that is on the sample clock alone.
  Duration? _stallNow() {
    final end = _lastEnd, at = _lastFrameWall;
    if (end == null || at == null) return null;
    return end + _now().difference(at);
  }

  void _handle(List<EcgTapOutput> outs) {
    for (final o in outs) {
      switch (o) {
        case EcgTapBuzz(:final at):
          step?.call(
            'Follow-up buzz requested at sample time ${at.inMilliseconds} ms.',
          );
          final sent = _sendCue(
            'Follow-up buzz',
            (id) => buzz(1, id),
            '${_buzzes++}',
          );
          _holdForCue(sent);
        case EcgTapConfirm(:final at):
          step?.call(
            'Confirm buzz requested at sample time ${at.inMilliseconds} ms.',
          );
          final confirm = confirmBuzz;
          if (confirm != null) {
            unawaited(_sendCue('Confirm buzz', confirm, 'confirm'));
          }
        case EcgTapDone(:final at, :final count):
          step?.call(
            'Final count $count at sample time ${at.inMilliseconds} ms.',
          );
          unawaited(_finish(count, null));
        case EcgTapAbandoned(:final reason):
          _abandon(reason);
      }
    }
  }

  /// The window after a follow-up waits for the cue to be played: the counter
  /// is told to hold, and once the cue was written (or refused) and the band is
  /// idle (bounded by [buzzTimeout]) the next window opens at that moment on the
  /// sample clock. A gesture that ended meanwhile, or a retried attempt, is left
  /// alone. Nothing here is a flag that outlives the gesture: the hold belongs
  /// to the counter, which every exit drops.
  void _holdForCue(Future<void> sent) {
    final idle = bandIdle, c = _counter;
    if (idle == null || c == null || c.finished) return;
    c.hold();
    step?.call('The next touch window waits for the follow-up cue to finish '
        'playing.');
    unawaited(() async {
      try {
        await sent;
        await idle().timeout(buzzTimeout);
      } catch (_) {
        step?.call('The band did not report idle in time; the touch window '
            'opens anyway.');
      }
      if (!_active || !identical(_counter, c) || c.finished) return;
      final at = _stallNow() ?? _lastEnd;
      if (at == null) return;
      step?.call('Follow-up cue played. Touch window open at sample time '
          '${at.inMilliseconds} ms (${c.thresholds.confirmMs} ms for the next '
          'touch to begin, plus ${sensorReacquire.inMilliseconds} ms for the '
          'sensor to show it).');
      c.release(at);
    }());
  }

  /// One cue, in order behind the cues before it: [send] with this gesture's
  /// event id `<base>:ecg:<suffix>`. Not written, a throw and a hang are logged
  /// and end only this cue; the ones after it still go out.
  Future<void> _sendCue(
    String what,
    Future<bool> Function(String eventId) send,
    String suffix,
  ) {
    final tap = _tap;
    if (tap == null) return Future<void>.value();
    final id = '${_eventBase(tap)}:ecg:$suffix';
    final requested = _now();
    _buzzTail = _buzzTail.then((_) async {
      var ok = false;
      try {
        ok = await send(id).timeout(buzzTimeout);
      } catch (_) {
        ok = false;
      }
      step?.call(
        '$what ${ok ? 'written' : 'could not be written'}, '
        '${_now().difference(requested).inMilliseconds} ms after the request.',
      );
    }).catchError((Object _) {});
    return _buzzTail;
  }

  /// End the gesture. Order matters (8N): the flags reset first (the next tap
  /// is not swallowed), the listener is told, THEN the stream is stopped, and
  /// only then is the tagging interval written, with an end that covers the time
  /// the band kept recording until the stop. The reverse order let a slow
  /// database leave seconds of gesture ECG outside the stored interval.
  ///
  /// 8X: a failed ECG (abandoned with a reason) buzzes the failure once. With
  /// the fallback on and no touch counted yet it ends with count 2 instead of
  /// null, so the double-tap action runs; returns true then.
  Future<bool> _finish(int? count, String? reason,
      {bool stopStream = false}) async {
    if (!_active) return false;
    final failed = count == null && reason != null;
    final fallback = failed &&
        (_th?.fallbackToDoubleTap ?? true) &&
        (_counter?.count ?? 0) < 3;
    if (failed) {
      final tap = _tap;
      step?.call('ECG failed ($reason): one long buzz.');
      step?.call(fallback
          ? 'ECG failed ($reason). Fallback: the count is 2 (double-tap '
              'action).'
          : 'Abandoned: $reason. No action.');
      // After the trace lines, so the failure record's log tells the story.
      if (tap != null) {
        try {
          onFailed?.call(tap, reason);
        } catch (_) {}
      }
      _sendFailBuzz();
    }
    final up = _streamUp;
    final strapStart = _firstStrapSec ?? _strapAtBegin;
    final packetEnd = _lastEndStrapSec;
    final fellBackToSamples = _gate?.fellBack ?? false;
    try {
      _timer?.cancel();
    } finally {
      _timer = null;
      _active = false;
      _streamUp = false;
      _opened = false;
      _firstSampleAt = null;
      _counter = null;
      _readiness = EcgStreamReadiness();
      _clock = EcgSampleClock();
      _prevEnd = null;
      _tap = null;
      _tapAt = null;
      _startedAt = null;
      _lastFrameWall = null;
      _lastEnd = null;
      _packets = 0;
      _buzzes = 0;
      _firstStrapSec = _lastEndStrapSec = _strapAtBegin = null;
      _retried = false;
      _th = null;
      _fast = false;
      _gate = null;
      _fallbackLogged = false;
      _presenceOn = _sampleOn = false;
    }
    // Both are best effort and must not leak an error out of an unawaited
    // call; the stream is stopped even if the listener throws.
    try {
      if (fallback) {
        onFinished(2, 'fallback: $reason');
      } else {
        onFinished(count, reason);
      }
    } catch (_) {}
    if (up || stopStream) {
      final post = up && reason == null ? _postRollSafe() : Duration.zero;
      final stopping = _stopInFlight = () async {
        if (post > Duration.zero) {
          _postRolling = true;
          _postPackets = 0;
          step?.call('Keeping the stream on for ${post.inMilliseconds} ms to '
              'see what the sensor does next (Device lab only).');
          try {
            await _wait(post);
          } catch (_) {}
          _postRolling = false;
        }
        await _endStreamSafely();
      }();
      await stopping;
      if (identical(_stopInFlight, stopping)) _stopInFlight = null;
    }
    final postEnd = _postEndStrapSec;
    _postEndStrapSec = null;
    // The recording ran until the stop returned. The strap clock now is only
    // known to the whole second, so round it UP: over-covering by a second is
    // harmless, leaving the tail of the recording outside the interval is not.
    final afterStop = _strapNowSafe();
    int? strapEnd = packetEnd;
    if (postEnd != null && (strapEnd == null || postEnd > strapEnd)) {
      strapEnd = postEnd;
    }
    if (strapStart != null && afterStop != null) {
      final covered = afterStop + 1;
      strapEnd = strapEnd == null || covered > strapEnd ? covered : strapEnd;
    }
    final record = EcgGestureRecord(
      strapStart: strapStart,
      strapEnd: strapEnd,
      finalCount: count,
      reason: reason,
      fellBackToSamples: fellBackToSamples,
    );
    // 8N: the interval is written on every exit, and a failure here must not
    // leave anything unfinished.
    try {
      await recordSession?.call(record).timeout(recordTimeout);
    } catch (_) {}
    return fallback;
  }

  /// The failure buzz, queued behind any count buzz. A throw, a refusal or a hang is logged and ends there.
  void _sendFailBuzz() {
    final tap = _tap, fb = failBuzz;
    if (tap == null || fb == null) return;
    final base = tap.plausible
        ? tap.identity
        : '${tap.identity}:${tap.receivedAt.microsecondsSinceEpoch}';
    final id = '$base:failed';
    _buzzTail = _buzzTail.then((_) async {
      var ok = false;
      try {
        ok = await fb(id).timeout(buzzTimeout);
      } catch (_) {
        ok = false;
      }
      step?.call('The failure buzz ${ok ? 'written' : 'could not be written'}.');
    }).catchError((Object _) {});
  }

  Duration _postRollSafe() {
    try {
      return _postRoll();
    } catch (_) {
      return Duration.zero;
    }
  }

  int? _strapNowSafe() {
    try {
      return strapNow?.call();
    } catch (_) {
      return null;
    }
  }
}
