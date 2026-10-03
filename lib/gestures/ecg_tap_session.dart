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
    this.buzzQuietGap = const Duration(milliseconds: 1200),
    Future<void> Function(Duration)? wait,
  })  : _now = now ?? DateTime.now,
        _wait = wait ?? ((d) => Future<void>.delayed(d));

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

  /// The quiet time after one buzz finishes writing before the next may be
  /// asked for. Measured, not specified: in the 2026-10-02 lab log a buzz asked
  /// for 0.2–0.65 s after the previous one finished writing never played (no
  /// reply, no haptic); one asked for 1.06 s after did. Pulses INSIDE one buzz
  /// are 300 ms apart and play.
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
    if (!_active || c == null) return;
    final wall = _now();
    _packets++;
    final prevWall = _lastFrameWall;
    final n = r.samples.length;
    var raw = 0, first = -1, last = -1;
    for (var i = 0; i < n; i++) {
      if (r.samples[i] == 0) continue;
      raw++;
      if (first < 0) first = i;
      last = i;
    }
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
      'behind the freshest packet so far',
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

  /// One buzz, in order, after the band's quiet gap. A buzz that could not be
  /// written is logged, never retried: the count it reports already stands,
  /// and the gesture still ends (or carries on) on its own clock.
  Future<void> _deliverBuzz(int pulses, String id, DateTime requested) async {
    final quiet = _quietUntil;
    final now = _now();
    if (quiet != null && quiet.isAfter(now)) {
      final w = quiet.difference(now);
      step?.call('Buzz x$pulses waits ${w.inMilliseconds} ms: the band is '
          'still busy with the last buzz.');
      await _wait(w);
    }
    var ok = false;
    try {
      ok = await buzz(pulses, id).timeout(buzzTimeout);
    } catch (_) {
      ok = false;
    }
    final done = _now();
    _quietUntil = done.add(buzzQuietGap);
    step?.call(
      'Buzz x$pulses ${ok ? 'written' : 'could not be written'}, '
      '${done.difference(requested).inMilliseconds} ms after the request.',
    );
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
      final stopping = _stopInFlight = _endStreamSafely();
      await stopping;
      if (identical(_stopInFlight, stopping)) _stopInFlight = null;
    }
    // The recording ran until the stop returned. The strap clock now is only
    // known to the whole second, so round it UP: over-covering by a second is
    // harmless, leaving the tail of the recording outside the interval is not.
    final afterStop = _strapNowSafe();
    int? strapEnd = packetEnd;
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

  int? _strapNowSafe() {
    try {
      return strapNow?.call();
    } catch (_) {
      return null;
    }
  }
}
