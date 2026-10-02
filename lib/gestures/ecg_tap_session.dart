// ecg_tap_session.dart — runs one EcgTapCounter against the live ECG stream.
//
// The pure counter (ecg_tap_counter.dart) decides; this file feeds it. For one
// live double tap it: starts the ECG stream, WAITS until real R17 packets are
// flowing ([EcgStreamReadiness]), only then sends the two-pulse acknowledgement,
// opens the first touch window once that buzz has been written, turns each R17
// packet into 100 Hz samples on the stream's own clock, forwards every buzz
// request, and stops the stream when the gesture ends. No sample is persisted
// (invariant 14): the packets are consumed and dropped here. The one thing kept
// is the session's strap-clock INTERVAL (see [EcgGestureRecord]): turning the
// stream on makes the band save raw ECG that ordinary history sync delivers
// later, and the receiving side needs the interval to label those packets as
// gesture contact (8N), never a reading.
//
// Time. Samples are on the stream's own (strap) clock; the phone only knows when
// a packet ARRIVED, and BLE can hold packets back by a second or more. So the
// first touch window is opened at the acknowledgement's wall time mapped through
// [EcgSampleClock] (the least-delayed recent packet), never "end of the last
// packet plus the wall time since it arrived". The stream is called steady only
// when the sample clock is continuous and in step with the wall clock
// ([EcgStreamReadiness]). Missing samples are the counter's discontinuity
// policy (see ecg_tap_counter.dart). The trace prints, per packet, how far it
// sits behind the freshest packet and whether it continues the previous one.
//
// Why the wait: a start command being written only means the command left the
// phone. The band can take many seconds to begin sending, and an
// acknowledgement before that tells the wearer to touch a sensor that is not
// listening yet. Startup is slow, so [startTimeout] is generous (20 s).
//
// Everything that touches the world is injected (stream start/stop, buzz,
// clocks), so the latch discipline is testable. One gesture at a time; every
// exit (done, abandon, a throw while starting) goes through [_finish], which
// resets every flag in `finally` (a sticky flag here would swallow every later
// double tap until the app is restarted).
//
// The step trace (for the Device lab) names every stage with its timing: the
// tap, the stream command written, the first packet, the stream steady, the
// acknowledgement written, the touch window open, and every packet in between
// (number, samples, how many show contact, strap time, gap since the last).

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
  }) : _now = now ?? DateTime.now;

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
  /// (counted, abandoned, link lost, start failed), after [onFinished] and
  /// before the stream is stopped. May throw: the failure is swallowed, so a
  /// storage error can never wedge the latch or keep the stream running.
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
  //  * [recordTimeout] — writing the gesture interval. It runs BEFORE the stream
  //    is stopped, so a stuck database must not keep the stream running.
  //  * [buzzTimeout] — one band buzz. A buzz that never answers counts as not
  //    written; the acknowledgement then abandons the gesture, and the next
  //    session's buzzes are not queued behind it.
  final Duration beginTimeout, endTimeout, recordTimeout, buzzTimeout;

  static const Duration _samplePeriod = Duration(milliseconds: 10); // 100 Hz

  bool _active = false;
  bool _streamUp = false;
  bool _asked = false; // the acknowledgement has been requested
  DateTime? _ackFinishedAt;
  bool _acked = false;
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

  // The strap-clock interval seen on the wire this session (8N).
  int? _firstStrapSec, _lastEndStrapSec, _strapAtBegin;

  bool get active => _active;

  int _sinceTap() {
    final at = _tapAt;
    return at == null ? 0 : _now().difference(at).inMilliseconds;
  }

  /// Begin the gesture for a live double tap. Returns once the stream command
  /// has gone out (the rest happens as packets arrive). Throws if it could not
  /// start, with every flag already reset, so the caller can give the tap's
  /// claim back. A second tap while one gesture runs is ignored.
  Future<void> start(StrapEvent tap) async {
    if (_active) return;
    _active = true;
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
      if (!_active) {
        // Finished while the start was still returning: do not leave the
        // stream running.
        await _endStreamSafely();
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
      _maybeAskForAck();
    } catch (e) {
      step?.call('Could not start: $e');
      await _finish(null, 'start_failed');
      // A start that never answered may still land: make sure nothing is left
      // streaming for a gesture that has already given up.
      if (e is TimeoutException) await _endStreamSafely();
      rethrow;
    }
  }

  Future<void> _endStreamSafely() async {
    try {
      await endStream().timeout(endTimeout);
    } catch (_) {}
  }

  /// One decoded ECG packet. Contact is a non-zero sample: the stream is zeros
  /// until the finger is on the electrode.
  void onFrame(LabradorR17 r) {
    final c = _counter;
    if (!_active || c == null) return;
    final wall = _now();
    _packets++;
    final prevWall = _lastFrameWall;
    var contact = 0;
    for (final s in r.samples) {
      if (s != 0) contact++;
    }
    final base = Duration(microseconds: (r.strapTime * 1000000).round());
    final end = base + _samplePeriod * r.samples.length;
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
      'Packet $_packets: ${r.samples.length} samples, $contact with contact, '
      'strap time ${r.strapTime.toStringAsFixed(3)}, $gap, $continuity, '
      'received ${(behind.inMicroseconds / 1000).round()} ms behind the '
      'freshest packet so far',
    );
    if (_packets == 1) {
      step?.call('First packet arrived ${_sinceTap()} ms after the tap.');
    }
    // Interval bookkeeping: whole strap seconds, start floored and end
    // ceiled, in integers (no float drift at a second boundary).
    final startSec = r.strapSeconds;
    final subMs = (r.subseconds * 1000 + 32767) ~/ 32768;
    final endSec = startSec + (subMs + r.samples.length * 10 + 999) ~/ 1000;
    _firstStrapSec = _firstStrapSec == null || startSec < _firstStrapSec!
        ? startSec
        : _firstStrapSec;
    _lastEndStrapSec = _lastEndStrapSec == null || endSec > _lastEndStrapSec!
        ? endSec
        : _lastEndStrapSec;
    _lastFrameWall = wall;
    _lastEnd = end;
    _prevEnd = end;

    if (!_readiness.ready &&
        _readiness.offer(
          at: wall,
          strapTime: r.strapTime,
          sampleCount: r.samples.length,
        )) {
      step?.call(
        'Stream is steady, ${_sinceTap()} ms after the tap '
        '(two packets continuous on the sample clock, advancing in step with '
        'the wall clock, within '
        '${EcgStreamReadiness.pairWindow.inMilliseconds} ms of each other).',
      );
    }
    _maybeAskForAck();

    if (_ackFinishedAt != null && !_acked) _openWindow();
    if (!_acked) return;
    for (var i = 0; i < r.samples.length && _active; i++) {
      final t = base + _samplePeriod * i;
      _handle(c.sample(t, contact: r.samples[i] != 0));
    }
  }

  /// Ask for the two-pulse acknowledgement, once, and only when the stream
  /// command has returned AND the packets are steady.
  void _maybeAskForAck() {
    final c = _counter, tap = _tap;
    if (!_active || _asked || !_streamUp || !_readiness.ready) return;
    if (c == null || tap == null) return;
    _asked = true;
    _handle(c.start(tap, at: _clock.sampleAt(_now()) ?? Duration.zero));
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
  /// window: that goes through [_clock].
  Duration? _stallNow() {
    final end = _lastEnd, at = _lastFrameWall;
    if (end == null || at == null) return null;
    return end + _now().difference(at);
  }

  /// Open the first touch window at the acknowledgement's wall time mapped onto
  /// the sample clock through the least-delayed recent packet. (The haptic
  /// itself may start a little after the write completes: unknown, not
  /// modelled; the counter's debounce absorbs a few tens of ms.)
  void _openWindow() {
    final wall = _ackFinishedAt;
    final boundary = wall == null ? null : _clock.sampleAt(wall);
    if (wall == null || boundary == null) return;
    _acked = true;
    final end = _lastEnd, at = _lastFrameWall;
    final legacy = end == null || at == null ? null : end + wall.difference(at);
    final shift = legacy == null
        ? ''
        : ' The boundary is ${(boundary - legacy).inMilliseconds} ms later '
            'than the receipt-time estimate (end of the last packet plus the '
            'wall time since it arrived) would have put it.';
    step?.call(
      'Sample clock: from ${_packets.clamp(0, _clock.keep)} packets, the '
      'least-delayed one puts the phone clock at the strap clock plus '
      '${(_clock.baseline!.inMicroseconds / 1e6).toStringAsFixed(3)} s (the '
      'real clock offset and that packet\'s own latency, which cannot be told '
      'apart).$shift',
    );
    step?.call(
      'Touch window open at sample time ${boundary.inMilliseconds} ms '
      '(${_sinceTap()} ms after the tap).',
    );
    _handle(_counter!.ackDone(boundary));
  }

  void _ackFinishedByBuzz() {
    _ackFinishedAt = _now();
    if (!_active || _acked) return;
    _openWindow();
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
    final counter = _counter;
    if (tap == null || counter == null) return Future<void>.value();
    final base = tap.plausible
        ? tap.identity
        : '${tap.identity}:${tap.receivedAt.microsecondsSinceEpoch}';
    final id = '$base:ecg:${_buzzes++}';
    final sent = _now();
    _buzzTail = _buzzTail
        .then((_) => _deliverBuzz(pulses, id, counter, sent))
        .catchError((Object _) {});
    return _buzzTail;
  }

  Future<void> _deliverBuzz(
    int pulses,
    String id,
    EcgTapCounter counter,
    DateTime sent,
  ) async {
    var ok = false;
    try {
      ok = await buzz(pulses, id).timeout(buzzTimeout);
    } catch (_) {
      ok = false;
    }
    // An earlier session's asynchronous haptic must never change the current
    // session's acknowledgement or abandon it after a new gesture starts.
    if (!_active || !identical(counter, _counter)) return;
    final took = _now().difference(sent).inMilliseconds;
    if (pulses == 2) {
      if (ok) {
        step?.call(
          'Acknowledgement written, ${_sinceTap()} ms after the tap '
          '($took ms after the request).',
        );
        _ackFinishedByBuzz();
      } else {
        // Only a buzz that could not be WRITTEN stops the gesture. The band
        // answering late, or not at all, is not a failure.
        step?.call('Acknowledgement could not be written ($took ms). Giving up.');
        await _finish(null, 'ack_failed');
      }
      return;
    }
    step?.call(
      'Buzz x$pulses ${ok ? 'written' : 'could not be written'}, '
      '$took ms after the request.',
    );
  }

  Future<void> _finish(int? count, String? reason) async {
    if (!_active) return;
    final up = _streamUp;
    // The interval: the packets' own bounds when any arrived, else the strap
    // clock estimate at begin and now (a start that failed). Taken before the
    // flags reset below.
    final record = EcgGestureRecord(
      strapStart: _firstStrapSec ?? _strapAtBegin,
      strapEnd:
          _lastEndStrapSec ?? (_strapAtBegin == null ? null : _strapNowSafe()),
      finalCount: count,
      reason: reason,
    );
    try {
      _timer?.cancel();
    } finally {
      _timer = null;
      _active = false;
      _streamUp = false;
      _asked = false;
      _ackFinishedAt = null;
      _acked = false;
      _counter = null;
      _readiness = EcgStreamReadiness();
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
    // 8N: the interval is written on every exit, and a failure here must not
    // stop the stream from being stopped.
    try {
      await recordSession?.call(record).timeout(recordTimeout);
    } catch (_) {}
    if (up) await _endStreamSafely();
  }

  int? _strapNowSafe() {
    try {
      return strapNow?.call();
    } catch (_) {
      return null;
    }
  }
}
