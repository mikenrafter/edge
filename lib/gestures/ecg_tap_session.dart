// ecg_tap_session.dart — runs one EcgTapCounter against the live ECG stream.
//
// The pure counter (ecg_tap_counter.dart) decides; this file feeds it. For one
// live double tap it: starts the ECG stream, sends the two-pulse acknowledgement
// once the stream is running, turns each R17 packet into 100 Hz samples on the
// stream's own clock, forwards every buzz request, and stops the stream when the
// gesture ends. Nothing is persisted (invariant 14): the packets are consumed
// and dropped here.
//
// Everything that touches the world is injected (stream start/stop, buzz,
// clocks), so the latch discipline is testable. One gesture at a time; every
// exit (done, abandon, a throw while starting) goes through [_finish], which
// resets every flag in `finally` (a sticky flag here would swallow every later
// double tap until the app is restarted).
//
// Known unknowns, logged by the Device lab rather than guessed: how long the
// stream takes to start, what instant `LabradorR17.strapTime` names inside a
// packet, and how bursty packets are (the examples assume the sample clock is
// finer than the packet cadence).

import 'dart:async';

import 'package:openstrap_protocol/openstrap_protocol.dart' show LabradorR17;

import '../notify/alert_rule.dart';
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

class EcgTapSession {
  EcgTapSession({
    required this.beginStream,
    required this.endStream,
    required this.isStreamAlive,
    required this.buzz,
    required this.maxTaps,
    required this.thresholds,
    required this.onFinished,
    this.step,
    DateTime Function()? now,
    this.stallAfter = const Duration(seconds: 3),
    this.startTimeout = const Duration(seconds: 15),
    this.pollEvery = const Duration(milliseconds: 250),
  }) : _now = now ?? DateTime.now;

  /// Start the ECG stream; true when it is running.
  final Future<bool> Function() beginStream;

  /// Stop it and clean up. Never throws.
  final Future<void> Function() endStream;

  /// Whether the stream is still up (false after a link drop or timeout).
  final bool Function() isStreamAlive;

  /// Ask the band to buzz [pulses] times for [eventId], through AlertDispatcher.
  final Future<bool> Function(int pulses, String eventId) buzz;

  final int Function() maxTaps;
  final EcgTapThresholds Function() thresholds;

  /// The gesture ended: [count] taps, or null when abandoned (with [reason]).
  final void Function(int? count, String? reason) onFinished;

  /// A line for the Device lab's trace.
  final void Function(String line)? step;

  final DateTime Function() _now;

  /// Packets arrive roughly once a second, so the counter's sample-clock stall
  /// timeout is a few packets, not its 500 ms default.
  final Duration stallAfter;

  /// No packet this long after the stream started (or no ack) abandons.
  final Duration startTimeout;
  final Duration pollEvery;

  static const Duration _samplePeriod = Duration(milliseconds: 10); // 100 Hz

  bool _active = false;
  bool _streamUp = false;
  bool _ackFinished = false;
  bool _acked = false;
  EcgTapCounter? _counter;
  StrapEvent? _tap;
  Timer? _timer;
  DateTime? _startedAt;
  DateTime? _lastFrameWall;
  Duration? _lastEnd;
  int _buzzes = 0;

  bool get active => _active;

  /// Begin the gesture for a live double tap. Returns once the stream is
  /// running (the rest happens as packets arrive). Throws if it could not
  /// start, with every flag already reset, so the caller can give the tap's
  /// claim back. A second tap while one gesture runs is ignored.
  Future<void> start(StrapEvent tap) async {
    if (_active) return;
    _active = true;
    _tap = tap;
    _counter = EcgTapCounter(
        max: maxTaps(), thresholds: thresholds(), stallAfter: stallAfter);
    try {
      step?.call('Double tap received. Starting the ECG stream.');
      if (!await beginStream()) {
        throw StateError('the ECG stream did not start');
      }
      _streamUp = true;
      _startedAt = _now();
      final sinceTap = _now().difference(tap.receivedAt).inMilliseconds;
      step?.call('ECG stream running, $sinceTap ms after the tap reached the '
          'phone. Thresholds: ${_counter!.thresholds}.');
      _handle(_counter!.start(tap, at: Duration.zero));
      if (_active) {
        _timer = Timer.periodic(pollEvery, (_) => poll());
      }
    } catch (e) {
      step?.call('Could not start: $e');
      await _finish(null, 'start_failed');
      rethrow;
    }
  }

  /// One decoded ECG packet. Contact is a non-zero sample: the stream is zeros
  /// until the finger is on the electrode.
  void onFrame(LabradorR17 r) {
    final c = _counter;
    if (!_active || c == null || !_streamUp) return;
    final base = Duration(microseconds: (r.strapTime * 1000000).round());
    _lastFrameWall = _now();
    _lastEnd = base + _samplePeriod * r.samples.length;
    if (_ackFinished && !_acked) _ackAt(base);
    if (!_acked) return;
    for (var i = 0; i < r.samples.length && _active; i++) {
      final t = base + _samplePeriod * i;
      final contact = r.samples[i] != 0;
      _handle(c.sample(t, contact: contact));
    }
  }

  /// Stall and liveness checks; also what the periodic timer runs.
  void poll() {
    final c = _counter;
    if (!_active || c == null) return;
    final start = _startedAt;
    if (!isStreamAlive()) {
      _handle(c.linkLost(_streamNow() ?? Duration.zero));
      return;
    }
    if (start != null && _now().difference(start) > startTimeout) {
      if (_lastFrameWall == null || !_acked) {
        step?.call('No usable stream $startTimeout after the tap.');
        _handle(c.linkLost(_streamNow() ?? Duration.zero));
        return;
      }
    }
    final now = _streamNow();
    if (now != null) _handle(c.tick(now));
  }

  /// The ECG sample clock "now": the end of the last packet plus the wall time
  /// since it arrived. Null before any packet.
  Duration? _streamNow() {
    final end = _lastEnd, at = _lastFrameWall;
    if (end == null || at == null) return null;
    return end + _now().difference(at);
  }

  void _ackAt(Duration t) {
    _acked = true;
    step?.call('Acknowledgement finished. First touch window opens at sample '
        'time ${t.inMilliseconds} ms.');
    _handle(_counter!.ackDone(t));
  }

  void _ackFinishedByBuzz() {
    _ackFinished = true;
    if (!_active || _acked) return;
    // A packet already seen fixes "now" on the sample clock; otherwise the
    // window opens at the first packet that arrives.
    final now = _streamNow();
    if (now != null) _ackAt(now);
  }

  void _handle(List<EcgTapOutput> outs) {
    for (final o in outs) {
      switch (o) {
        case EcgTapBuzz(:final at, :final pulses):
          step?.call('Buzz x$pulses requested at sample time '
              '${at.inMilliseconds} ms.');
          unawaited(_sendBuzz(pulses));
        case EcgTapDone(:final at, :final count):
          step?.call('Final count $count at sample time ${at.inMilliseconds} ms.');
          unawaited(_finish(count, null));
        case EcgTapAbandoned(:final reason):
          step?.call('Abandoned: $reason. No action.');
          unawaited(_finish(null, reason));
      }
    }
  }

  Future<void> _sendBuzz(int pulses) async {
    final tap = _tap;
    if (tap == null) return;
    final base = tap.plausible
        ? tap.identity
        : '${tap.identity}:${tap.receivedAt.microsecondsSinceEpoch}';
    final id = '$base:ecg:${_buzzes++}';
    final sent = _now();
    var ok = false;
    try {
      ok = await buzz(pulses, id);
    } catch (_) {
      ok = false;
    } finally {
      // Whether or not the write landed there is nothing more to wait for; the
      // window opens rather than the gesture hanging on a buzz.
      if (pulses == 2) _ackFinishedByBuzz();
    }
    step?.call('Buzz x$pulses ${ok ? 'written' : 'not delivered'} '
        '${_now().difference(sent).inMilliseconds} ms after the request.');
  }

  Future<void> _finish(int? count, String? reason) async {
    if (!_active) return;
    final up = _streamUp;
    try {
      _timer?.cancel();
    } finally {
      _timer = null;
      _active = false;
      _streamUp = false;
      _ackFinished = false;
      _acked = false;
      _counter = null;
      _tap = null;
      _startedAt = null;
      _lastFrameWall = null;
      _lastEnd = null;
      _buzzes = 0;
    }
    // Both are best effort and must not leak an error out of an unawaited
    // call; the stream is stopped even if the listener throws.
    try {
      onFinished(count, reason);
    } catch (_) {}
    if (up) {
      try {
        await endStream();
      } catch (_) {}
    }
  }
}
