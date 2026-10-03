// ecg_tap_counter.dart — draft 3–5 tap gestures, counted as touches on the
// WHOOP MG ECG sensor after a live firmware double tap (phase 8L).
//
// The firmware only ever reports a double tap, so further taps are touches of
// the ECG electrode. This is a pure state machine: no Flutter, no wall clock,
// no DB, no BLE. Every `at` is ECG SAMPLE time (a Duration on the stream's own
// clock), never phone receipt time, because samples reach the phone in bursts
// and receipt time would turn a 200 ms window into noise.
//
// FIRST BUZZ = THE COUNT SO FAR. Nothing buzzes when the gesture starts. The
// first window decides the first buzz: a touch that engages in it (a finger
// already on the sensor counts) is tap 3 and buzzes three times; no touch by
// the deadline ends the gesture at 2 with two buzzes. Every later tap buzzes
// once, and a count that a window running out makes final gets one more
// confirming buzz. A count that is final the moment it is buzzed (2 at the
// first deadline, or [max] reached) gets no extra buzz: that buzz is the
// confirmation.
//
//  * A DEADLINE is only ever decided by a sample reaching it. [tick] exists to
//    notice a stalled stream and nothing else: it can abandon, never confirm.
//  * Contact must hold for the gap threshold to ENGAGE, and no-contact must hold
//    for the same gap threshold to RELEASE (contact that returns sooner is the
//    same touch). One value, two debounces.
//  * A touch counts only if it STARTS before the open window's deadline
//    (exclusive) and then engages. A candidate that started in time is waited
//    for even if the deadline passes while it is pending.
//  * After an engaged touch whose contact ended at E, the next window is
//    [E + gap, E + gap + confirm).
//  * Every output is a request. The caller routes buzzes through
//    AlertDispatcher and paces them; this class sends nothing.
//
// DISCONTINUITY POLICY (review finding E). Contact and no-contact only count
// when they are OBSERVED. Two consecutive samples further apart than
// [EcgTapCounter.maxSampleGap] (one 10 ms sample period + 40 ms tolerance) mean
// samples are missing, and the missing time is evidence of nothing:
//  * a pending engage candidate is dropped (contact has to be seen again for
//    the full gap threshold);
//  * a release timer restarts at the first sample after the hole, so unseen
//    time never completes a release; contact that is back after a hole during
//    a release is the same touch;
//  * a hole that swallows a window's deadline abandons the gesture with reason
//    `sample_gap`: whether a touch started inside the unseen part cannot be
//    known, and running the wrong count's actions is worse than running none;
//  * a hole that ends before the deadline only costs the unseen time.

import 'strap_event.dart';

class EcgTapThresholds {
  EcgTapThresholds({
    int startMs = 300,
    int gapMs = 200,
    int confirmMs = 200,
    this.extraSensitive = false,
  })  : startMs = _check('start', startMs, startRange),
        gapMs = _check('gap', gapMs, gapRange),
        confirmMs = _check('confirm', confirmMs, confirmRange);

  static const int stepMs = 50;
  static const (int, int) startRange = (200, 1100);
  static const (int, int) gapRange = (100, 1000);
  static const (int, int) confirmRange = (100, 1000);

  /// True when [v] is inside [range] and on the 50 ms grid. Used to validate
  /// stored values without throwing.
  static bool isValid(int v, (int, int) range) =>
      v >= range.$1 && v <= range.$2 && v % stepMs == 0;

  static int _check(String name, int v, (int, int) range) {
    if (!isValid(v, range)) {
      throw ArgumentError.value(
          v,
          '${name}Ms',
          'must be ${range.$1}–${range.$2} ms in steps of $stepMs; '
              'rejected, not clamped');
    }
    return v;
  }

  /// Window after the sensor is ready for the first touch to start (or to be
  /// there already).
  final int startMs;

  /// Contact / no-contact must hold this long to engage / release.
  final int gapMs;

  /// Extra window after a release for the next touch to start.
  final int confirmMs;

  /// "Extra sensitive subsequent tap detection". Off (the default): within one
  /// packet, everything from the first to the last reading with signal is
  /// contact, so an ECG trace crossing zero cannot break a touch, but a lift
  /// and re-touch inside the same packet (about a second) is one tap. On: every
  /// reading counts on its own. Applied by the session, which sees packets;
  /// the counter only ever sees samples.
  final bool extraSensitive;

  Duration get start => Duration(milliseconds: startMs);
  Duration get gap => Duration(milliseconds: gapMs);
  Duration get confirm => Duration(milliseconds: confirmMs);

  EcgTapThresholds copyWith({
    int? startMs,
    int? gapMs,
    int? confirmMs,
    bool? extraSensitive,
  }) =>
      EcgTapThresholds(
        startMs: startMs ?? this.startMs,
        gapMs: gapMs ?? this.gapMs,
        confirmMs: confirmMs ?? this.confirmMs,
        extraSensitive: extraSensitive ?? this.extraSensitive,
      );

  /// One plain line for the Device lab: "start 300 ms, gap 200 ms, confirm 200 ms"
  /// (plus ", extra sensitive" when that is on).
  String get summary =>
      'start $startMs ms, gap $gapMs ms, confirm $confirmMs ms'
      '${extraSensitive ? ', extra sensitive' : ''}';

  @override
  bool operator ==(Object other) =>
      other is EcgTapThresholds &&
      other.startMs == startMs &&
      other.gapMs == gapMs &&
      other.confirmMs == confirmMs &&
      other.extraSensitive == extraSensitive;

  @override
  int get hashCode => Object.hash(startMs, gapMs, confirmMs, extraSensitive);

  @override
  String toString() => 'EcgTapThresholds(start $startMs, gap $gapMs, '
      'confirm $confirmMs${extraSensitive ? ', extra sensitive' : ''})';
}

sealed class EcgTapOutput {
  const EcgTapOutput(this.at);

  /// ECG sample time the output was decided at.
  final Duration at;
}

/// Ask the band to buzz [pulses] times.
final class EcgTapBuzz extends EcgTapOutput {
  const EcgTapBuzz(super.at, {this.pulses = 1});
  final int pulses;
}

/// The gesture ended with [count] taps; run that count's actions.
final class EcgTapDone extends EcgTapOutput {
  const EcgTapDone(super.at, this.count);
  final int count;
}

/// The gesture ended with no action: the link dropped or the stream stalled.
final class EcgTapAbandoned extends EcgTapOutput {
  const EcgTapAbandoned(super.at, this.reason);
  final String reason;
}

enum _Phase { awaitingOpen, idle, candidate, touching, releasing }

class EcgTapCounter {
  EcgTapCounter({
    required int max,
    EcgTapThresholds? thresholds,
    this.stallAfter = const Duration(milliseconds: 500),
    this.maxSampleGap = const Duration(milliseconds: 50),
  })  : max = _checkMax(max),
        thresholds = thresholds ?? EcgTapThresholds();

  static int _checkMax(int v) {
    if (v < 2 || v > 5) throw ArgumentError.value(v, 'max', 'must be 2..5');
    return v;
  }

  final int max;
  final EcgTapThresholds thresholds;

  /// No sample for this long (sample-clock time as advanced by the caller's
  /// ticks) abandons the gesture.
  final Duration stallAfter;

  /// Two consecutive samples further apart than this are a discontinuity (see
  /// the policy above). 100 Hz samples are 10 ms apart; the rest is tolerance
  /// for packet-boundary timestamp jitter, well under the 200 ms touch debounce.
  final Duration maxSampleGap;

  int _count = 0;
  bool _started = false;
  bool _finished = false;
  _Phase _phase = _Phase.awaitingOpen;
  Duration _deadline = Duration.zero;
  Duration _contactStart = Duration.zero;
  Duration _noContactStart = Duration.zero;
  Duration? _lastSampleAt;

  int get count => _count;
  bool get started => _started;
  bool get finished => _finished;

  /// A live double tap begins the gesture at count 2. Nothing buzzes yet: the
  /// first window decides whether the first buzz says 2 or 3. With [max] 2
  /// there is nothing to wait for, so it buzzes twice and ends. A late tap
  /// never starts it.
  List<EcgTapOutput> start(StrapEvent tap, {required Duration at}) {
    if (_started || _finished || !tap.isLive) return const [];
    _started = true;
    _count = 2;
    if (max == 2) {
      _finished = true;
      return [EcgTapBuzz(at, pulses: 2), EcgTapDone(at, 2)];
    }
    return const [];
  }

  /// The sensor is ready: opens the first window `[at, at + start)`. Samples
  /// before [at] are ignored; contact already there at [at] is a touch that
  /// started in time.
  List<EcgTapOutput> open(Duration at) {
    if (!_started || _finished || _phase != _Phase.awaitingOpen) return const [];
    _phase = _Phase.idle;
    _deadline = at + thresholds.start;
    _lastSampleAt = at;
    return const [];
  }

  List<EcgTapOutput> sample(Duration at, {required bool contact}) {
    if (!_started || _finished || _phase == _Phase.awaitingOpen) return const [];
    final last = _lastSampleAt;
    if (last != null && at < last) return const []; // out of order
    _lastSampleAt = at;
    final out = <EcgTapOutput>[];

    if (last != null && at - last > maxSampleGap) {
      final gone = _onGap(at, contact);
      if (gone != null) return gone;
    }

    // A touch that has ended its release wait falls through to the idle rules
    // for this same sample.
    if (_phase == _Phase.releasing) {
      if (at - _noContactStart >= thresholds.gap) {
        _deadline = _noContactStart + thresholds.gap + thresholds.confirm;
        _phase = _Phase.idle;
      } else if (contact) {
        _phase = _Phase.touching;
        return out;
      } else {
        return out;
      }
    }

    switch (_phase) {
      case _Phase.idle:
        // Deadlines are checked before the sample's own contact state.
        if (at >= _deadline) return _confirm(at, out);
        if (contact) {
          _phase = _Phase.candidate;
          _contactStart = at;
        }
      case _Phase.candidate:
        if (!contact) {
          // A blip shorter than the gap: nothing was touched.
          _phase = _Phase.idle;
          if (at >= _deadline) return _confirm(at, out);
        } else if (at - _contactStart >= thresholds.gap) {
          _count++;
          // Tap 3 is the first buzz of the gesture: it says the whole count.
          out.add(EcgTapBuzz(at, pulses: _count == 3 ? 3 : 1));
          if (_count >= max) {
            _finished = true;
            out.add(EcgTapDone(at, _count));
          } else {
            _phase = _Phase.touching;
          }
        }
      case _Phase.touching:
        if (!contact) {
          _phase = _Phase.releasing;
          _noContactStart = at;
        }
      case _Phase.awaitingOpen:
      case _Phase.releasing:
        break;
    }
    return out;
  }

  /// A hole in the sample clock ended at [at]. Returns the outputs when the
  /// hole decided the gesture (abandon), or null to carry on with the sample.
  List<EcgTapOutput>? _onGap(Duration at, bool contact) {
    switch (_phase) {
      case _Phase.candidate:
        _phase = _Phase.idle; // contact must be seen again from scratch
        if (at >= _deadline) return _abandon(at, 'sample_gap');
      case _Phase.idle:
        if (at >= _deadline) return _abandon(at, 'sample_gap');
      case _Phase.releasing:
        _noContactStart = at; // unseen time is not no-contact
      case _Phase.touching:
      case _Phase.awaitingOpen:
        break;
    }
    return null;
  }

  /// Stall detection only. [now] is on the same clock as [sample].
  List<EcgTapOutput> tick(Duration now) {
    if (!_started || _finished || _phase == _Phase.awaitingOpen) return const [];
    final last = _lastSampleAt;
    if (last == null || now - last < stallAfter) return const [];
    return _abandon(now, 'stalled');
  }

  List<EcgTapOutput> linkLost(Duration at) {
    if (!_started || _finished) return const [];
    return _abandon(at, 'link_lost');
  }

  /// A window ran out. At count 2 nothing has buzzed yet, so the two-pulse
  /// count buzz is also the confirmation; later counts were already buzzed
  /// and get one confirming buzz.
  List<EcgTapOutput> _confirm(Duration at, List<EcgTapOutput> out) {
    _finished = true;
    final pulses = _count == 2 ? 2 : 1;
    return [...out, EcgTapBuzz(at, pulses: pulses), EcgTapDone(at, _count)];
  }

  List<EcgTapOutput> _abandon(Duration at, String reason) {
    _finished = true;
    return [EcgTapAbandoned(at, reason)];
  }
}
