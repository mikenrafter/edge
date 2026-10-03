// ecg_tap_session.dart — runs one EcgTapCounter against the live ECG stream.
//
// The pure counter (ecg_tap_counter.dart) decides; this file feeds it. For one
// live double tap it: starts the ECG stream, WAITS until real R17 packets are
// flowing ([EcgStreamReadiness]) and the sensor has settled ([sensorSettle]),
// opens the first touch window there, turns each R17 packet into 100 Hz samples
// on the stream's own clock, paces every buzz request so the band plays it
// ([buzzQuietGap]), and stops the stream when the gesture ends. Nothing buzzes
// before the first window is decided: the first buzz is the count so far (three
// for a finger already on the sensor, two to end at two). No sample is persisted
// (invariant 14): the packets are consumed and dropped here. The one thing kept
// is the session's strap-clock INTERVAL (see [EcgGestureRecord]): turning the
// stream on makes the band save raw ECG that ordinary history sync delivers
// later, and the receiving side needs the interval to label those packets as
// gesture contact (8N), never a reading.
//
// Time. Every touch decision is on the stream's own (strap) sample clock, and
// only on it: a packet's strap time is its NEWEST sample and its samples run
// back from there (see PACKET TIME in ecg_stream_readiness.dart). The first
// window opens at a sample time ([sensorSettle] after the stream's first
// sample), not at a phone time mapped across. The phone clock is only used to
// notice a stalled stream and to pace buzzes. The stream is called steady only
// when the sample clock is continuous and in step with the wall clock
// ([EcgStreamReadiness]). Missing samples are the counter's discontinuity
// policy (see ecg_tap_counter.dart). The trace prints, per packet, where its
// contact sits, how far it sits behind the freshest packet and whether it
// continues the previous one.
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
import 'ecg_stream_readiness.dart';
import 'ecg_tap_counter.dart';
import 'strap_event.dart';

/// The band buzz for each counter step: band-only, live-only, a few seconds of
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
  });

  final int? strapStart;
  final int? strapEnd;

  /// The final count, or null when the gesture was abandoned.
  final int? finalCount;

  /// Why it was abandoned (null when counted).
  final String? reason;

  @override
  String toString() =>
      'EcgGestureRecord($strapStart..$strapEnd count=$finalCount reason=$reason)';
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
    this.onStarted,
    this.recordSession,
    this.onPacket,
    this.strapNow,
    this.step,
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
    this.buzzQuietGap = const Duration(milliseconds: 1800),
    this.maxPulsesPerBurst = 2,
    Duration Function()? postRoll,
    Future<void> Function(Duration)? wait,
  })  : _now = now ?? DateTime.now,
        _wait = wait ?? ((d) => Future<void>.delayed(d)),
        _postRoll = postRoll ?? (() => Duration.zero);

  /// Start the ECG stream; true when the command went out and the controller is
  /// running. It does NOT mean packets are flowing: see [EcgStreamReadiness].
  final Future<bool> Function() beginStream;

  /// Stop it and clean up. Never throws.
  final Future<void> Function() endStream;

  /// Whether the stream is still up (false after a link drop or timeout).
  final bool Function() isStreamAlive;

  /// Ask the band to buzz [pulses] times for [eventId], through AlertDispatcher.
  /// True when the buzz was WRITTEN to the band (the band's reply is not
  /// awaited), false when it could not be.
  final Future<bool> Function(int pulses, String eventId) buzz;

  final int Function() maxTaps;
  final EcgTapThresholds Function() thresholds;

  /// The gesture ended: [count] taps, or null when abandoned (with [reason]).
  final void Function(int? count, String? reason) onFinished;

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

  /// A line for the Device lab's trace.
  final void Function(String line)? step;

  /// Every packet this gesture saw (and, during a post-roll, saw after it
  /// ended), with when the phone got it: the Device lab keeps them in RAM for
  /// "Copy all logs" so a session can be replayed off the band. Never stored.
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
  /// 1.2 s after the lift, before either re-touch could appear.
  final Duration sensorReacquire;

  /// The most pulses sent back to back in one burst. Measured, not specified:
  /// in the 18:17 lab log every three-pulse buzz (pulses 300 ms apart) got a
  /// band reply for pulses 1 and 2 and none for pulse 3, and the band logged
  /// one haptic start/stop pair; two pulses 300 ms apart are felt as two. More
  /// pulses go out in further bursts, each after [buzzQuietGap].
  final int maxPulsesPerBurst;

  /// Lab only: how long to keep the stream on after the gesture ended, so the
  /// trace shows what the sensor did next (a re-touch that came too late, for
  /// one). The result is reported at once; only the stop waits. Zero outside
  /// the lab.
  final Duration Function() _postRoll;

  /// The quiet time after one burst finishes writing before the next may be
  /// asked for. Measured, not specified: in the 2026-10-02 lab logs the band
  /// is busy for a while after it takes a command (it accepts ONE more inside
  /// that time, the second pulse of a pair 300 ms later, and drops the rest
  /// with no reply). A command written ~1.25 s after the first of a pair was
  /// dropped; one written ~2.0 s after played. 1.8 s after the pair's second
  /// write puts the next burst ~2.15 s after its first: past both.
  /// docs/hardware/whoop-mg-haptics-and-ecg.md keeps the evidence.
  final Duration buzzQuietGap;

  final Future<void> Function(Duration) _wait;

  static const Duration _samplePeriod = Duration(milliseconds: 10); // 100 Hz

  bool _active = false;
  bool _streamUp = false;
  bool _opened = false; // the counter has started and its first window is open
  Duration? _firstSampleAt; // the stream's first sample, on the sample clock
  EcgTapCounter? _counter;
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
  // Packet bursts can request several confirmations at once. Preserve their
  // order across session cleanup, including the final touch's feedback.
  Future<void> _buzzTail = Future<void>.value();

  /// No buzz is asked for before this ([buzzQuietGap] after the last one
  /// finished writing). Kept across gestures: the band does not care which
  /// gesture a buzz belongs to.
  DateTime? _quietUntil;

  bool _postRolling = false;
  int _postPackets = 0;
  int? _postEndStrapSec;

  // The strap-clock interval seen on the wire this session (8N).
  int? _firstStrapSec, _lastEndStrapSec, _strapAtBegin;

  bool get active => _active;

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
  /// claim back. A second tap while one gesture runs is ignored.
  Future<void> start(StrapEvent tap) async {
    // The previous gesture's stop may still be in flight (bounded by
    // [endTimeout]). Starting a stream before it lands would let that stop
    // switch the NEW stream off.
    final prior = _stopInFlight;
    if (prior != null) await prior;
    if (_active) return;
    _active = true;
    final gen = ++_generation;
    _tap = tap;
    final now = _now();
    _tapAt = tap.receivedAt.isAfter(now) ? now : tap.receivedAt;
    _strapAtBegin = _strapNowSafe();
    final t = thresholds();
    _counter = EcgTapCounter(
      max: maxTaps(),
      thresholds: t,
      stallAfter: stallAfter,
      maxSampleGap: maxSampleGap,
      reacquire: sensorReacquire,
    );
    _readiness = EcgStreamReadiness();
    _clock = EcgSampleClock();
    _prevEnd = null;
    try {
      onStarted?.call(tap, t.summary);
    } catch (_) {}
    try {
      step?.call('Double tap received. Starting the ECG stream.');
      if (!await beginStream().timeout(beginTimeout)) {
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
      if (gen == _generation) {
        await _finish(null, 'start_failed', stopStream: e is TimeoutException);
      }
      rethrow;
    }
  }

  Future<void> _endStreamSafely() async {
    try {
      await endStream().timeout(endTimeout);
    } catch (_) {}
  }

  /// One decoded ECG packet. Contact is a non-zero sample: the stream is zeros
  /// until the finger is on the electrode. Unless
  /// [EcgTapThresholds.extraSensitive] is on, the zeros between a packet's
  /// first and last non-zero sample are contact too (an ECG trace crosses
  /// zero).
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
    final (raw, first, last) = _contactOf(r);
    final fill = !c.thresholds.extraSensitive;
    bool contactAt(int i) =>
        fill ? first >= 0 && i >= first && i <= last : r.samples[i] != 0;
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
      '${raw > 0 ? ' (samples $first–$last)' : ''}, '
      'strap time ${r.strapTime.toStringAsFixed(3)} (newest sample), $gap, '
      '$continuity, received ${(behind.inMicroseconds / 1000).round()} ms '
      'behind the freshest packet so far; ${_bandStatus(r)}',
    );
    if (_packets == 1) {
      step?.call('First packet arrived ${_sinceTap()} ms after the tap.');
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
    if (n > 0) _firstSampleAt ??= base;

    if (!_readiness.ready &&
        _readiness.offer(at: wall, strapTime: r.strapTime, sampleCount: n)) {
      step?.call(
        'Stream is steady, ${_sinceTap()} ms after the tap '
        '(two packets continuous on the sample clock, advancing in step with '
        'the wall clock, within '
        '${EcgStreamReadiness.pairWindow.inMilliseconds} ms of each other).',
      );
    }
    _maybeOpen();

    if (!_opened) return;
    // Samples before the window opened are ignored by the counter.
    for (var i = 0; i < n && _active; i++) {
      _handle(c.sample(base + _samplePeriod * i, contact: contactAt(i)));
    }
  }

  /// How many samples are non-zero, and the first and last of them (-1 when
  /// none).
  static (int, int, int) _contactOf(LabradorR17 r) {
    var raw = 0, first = -1, last = -1;
    for (var i = 0; i < r.samples.length; i++) {
      if (r.samples[i] == 0) continue;
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
    final (raw, first, last) = _contactOf(r);
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
    if (!_readiness.ready &&
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
    step?.call('Abandoned: $reason. No action.');
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
        case EcgTapBuzz(:final at, :final pulses):
          step?.call(
            'Buzz x$pulses requested at sample time '
            '${at.inMilliseconds} ms.',
          );
          unawaited(_sendBuzz(pulses));
        case EcgTapDone(:final at, :final count):
          step?.call(
            'Final count $count at sample time ${at.inMilliseconds} ms.',
          );
          unawaited(_finish(count, null));
        case EcgTapAbandoned(:final reason):
          step?.call('Abandoned: $reason. No action.');
          unawaited(_finish(null, reason));
      }
    }
  }

  Future<void> _sendBuzz(int pulses) {
    final tap = _tap;
    if (tap == null) return Future<void>.value();
    final base = tap.plausible
        ? tap.identity
        : '${tap.identity}:${tap.receivedAt.microsecondsSinceEpoch}';
    final id = '$base:ecg:${_buzzes++}';
    final requested = _now();
    _buzzTail = _buzzTail
        .then((_) => _deliverBuzz(pulses, id, requested))
        .catchError((Object _) {});
    return _buzzTail;
  }

  /// One count buzz, in order: bursts of at most [maxPulsesPerBurst] pulses,
  /// each after the band's quiet gap. A burst that could not be written is
  /// logged and ends the buzz (the count it reports already stands), and the
  /// gesture still ends (or carries on) on its own clock.
  Future<void> _deliverBuzz(int pulses, String id, DateTime requested) async {
    final bursts = (pulses + maxPulsesPerBurst - 1) ~/ maxPulsesPerBurst;
    var sent = 0;
    for (var k = 0; k < bursts; k++) {
      final n = pulses - sent < maxPulsesPerBurst
          ? pulses - sent
          : maxPulsesPerBurst;
      final what = bursts == 1
          ? 'Buzz x$pulses'
          : 'Buzz x$pulses, ${n == 1 ? 'pulse ${sent + 1}' : 'pulses ${sent + 1}–${sent + n}'}';
      final quiet = _quietUntil;
      final now = _now();
      if (quiet != null && quiet.isAfter(now)) {
        final w = quiet.difference(now);
        step?.call('$what waits ${w.inMilliseconds} ms: the band is still '
            'busy with the last buzz.');
        await _wait(w);
      }
      var ok = false;
      try {
        ok = await buzz(n, k == 0 ? id : '$id:b$k').timeout(buzzTimeout);
      } catch (_) {
        ok = false;
      }
      final done = _now();
      _quietUntil = done.add(buzzQuietGap);
      step?.call(
        '$what ${ok ? 'written' : 'could not be written'}, '
        '${done.difference(requested).inMilliseconds} ms after the request.',
      );
      if (!ok) return;
      sent += n;
    }
  }

  /// End the gesture. Order matters (8N): the flags reset first (the next tap
  /// is not swallowed), the listener is told, THEN the stream is stopped, and
  /// only then is the tagging interval written, with an end that covers the time
  /// the band kept recording until the stop. The reverse order let a slow
  /// database leave seconds of gesture ECG outside the stored interval.
  Future<void> _finish(int? count, String? reason,
      {bool stopStream = false}) async {
    if (!_active) return;
    final up = _streamUp;
    final strapStart = _firstStrapSec ?? _strapAtBegin;
    final packetEnd = _lastEndStrapSec;
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
    }
    // Both are best effort and must not leak an error out of an unawaited
    // call; the stream is stopped even if the listener throws.
    try {
      onFinished(count, reason);
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
    );
    // 8N: the interval is written on every exit, and a failure here must not
    // leave anything unfinished.
    try {
      await recordSession?.call(record).timeout(recordTimeout);
    } catch (_) {}
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
