// Fast mode against the shapes of the 2026-10-04 WHOOP MG capture
// (edge.research/ecg-hybrid-difference-2026-10-04.log), 9 sessions.
//
// What the capture showed, and what these tests pin:
//  * Every Fast gesture ended "Double tap" the instant the first packet with
//    samples arrived, touch or no touch. Fast opened the first touch window at
//    that packet's FIRST sample, the start window is 200 ms of sample time and
//    the packet only arrives about a second after its first sample, so the
//    window was already over when the packet was read.
//  * That first packet is a band warm-up artefact in 6 of 9 sessions in both
//    modes: 49 samples, "14 with contact (samples 35-48)", presence flipping on
//    with it. Fast now never counts it and opens the first window where it
//    ends, so the packet after it falls inside the window.
//  * The presence bit latches on with that packet and never drops (sample
//    contact went off and on for 1-8 s in the accurate sessions, presence
//    stayed on), so it vetoes nothing and is only traced.
//
// Packet shapes, as logged: packet 1 and 2 have no samples (flags 0x00 then
// 0x02, S2 1), packet 3 is the 49-sample warm-up ending 1 s later (flags 0x0a,
// S2 1, quality 1, contact 35-48), then 100-sample packets one second apart,
// each starting where the last one ended. Thresholds are the capture's: start
// 200 ms, gap 150 ms, confirm 750 ms, extra sensitive.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show LabradorR17;

import '../support/ecg_trace.dart';
import 'support/fast_rig.dart';
import 'support/presence_packets.dart' show t0;

EcgTapThresholds get _capture => EcgTapThresholds(
    startMs: 200, gapMs: 150, confirmMs: 750, extraSensitive: true);

/// Samples of [n] with a moving trace in [from, to) and zeros elsewhere.
List<int> _samples(int n, {int from = 0, int to = 0}) => [
      for (var i = 0; i < n; i++) i >= from && i < to ? (i.isEven ? 120 : -120) : 0,
    ];

/// The capture's timeline: strap time of each packet's newest sample, in
/// seconds after 1000.5, and the phone receives it that long after the first
/// packet (the capture shows every packet 0-25 ms behind the freshest).
class _Capture {
  _Capture(this.r);
  final FastRig r;
  int _k = 0; // packets fed so far

  Future<void> feed(
    int n, {
    int from = 0,
    int to = 0,
    int flags = 0x0a,
    int s2 = 1,
    int quality = 1,
  }) async {
    final strap = 1000.5 + _k; // newest sample, strap seconds
    _k++;
    r.now = t0.add(Duration(milliseconds: 300 + 2135 + (_k - 1) * 1000));
    final LabradorR17 p = r17(
      strapSeconds: strap.floor(),
      subseconds: ((strap - strap.floor()) * 32768).round(),
      samples: _samples(n, from: from, to: to),
      flags: flags,
      s2State: s2,
      quality: quality,
    );
    r.session.onFrame(p);
    await r.settle();
  }

  /// Packets 1 and 2 (no samples), then the 49-sample warm-up (contact 35-48
  /// unless [contact] is false).
  Future<void> upToWarmup({bool contact = true}) async {
    await feed(0, flags: 0x00, s2: 0, quality: 0);
    await feed(0, flags: 0x02, quality: 0);
    await feed(49, from: contact ? 35 : 0, to: contact ? 49 : 0);
  }
}

/// Strap milliseconds of the newest sample of packet [k] (0-based).
int _endMs(int k) => 1000500 + k * 1000;

void main() {
  test('no touch: the warm-up packet alone does not end the gesture, and the '
      'double tap is decided only after the start window that follows it',
      () async {
    final r = FastRig(th: _capture);
    final c = _Capture(r);
    await r.begin();
    await c.upToWarmup(contact: false);
    expect(r.results, isEmpty,
        reason: 'the capture ended "Double tap" right here\n'
            '${r.steps.join('\n')}');
    expect(r.cues, ['start']);
    expect(r.steps.where((s) => s.startsWith('Warm-up packet skipped')),
        hasLength(1));
    // The first window opens where the warm-up packet ENDS (its newest
    // sample), not at its first sample.
    expect(
        r.steps.any((s) =>
            s.startsWith('Touch window open at sample time ${_endMs(2)} ms')),
        isTrue,
        reason: r.steps.join('\n'));
    await c.feed(100); // the next packet: still no finger
    expect(r.results, [(2, null)], reason: r.steps.join('\n'));
    expect(r.cues, ['start', 'confirm']);
    expect(r.ended, 1);
    expect(r.beganFast, 1);
    expect(r.beganAccurate, 0);
  });

  test('contact inside the warm-up packet never counts', () async {
    final r = FastRig(th: _capture);
    final c = _Capture(r);
    await r.begin();
    await c.upToWarmup(); // 14 samples of contact, 35-48
    expect(r.cues, ['start'], reason: r.steps.join('\n'));
    expect(r.results, isEmpty);
    await c.feed(100); // no finger afterwards: a plain double tap
    expect(r.results, [(2, null)], reason: r.steps.join('\n'));
    expect(r.cues.where((x) => x == 'follow'), isEmpty);
  });

  test('a touch in the packet after the warm-up is counted', () async {
    final r = FastRig(th: _capture, max: 3);
    final c = _Capture(r);
    await r.begin();
    await c.upToWarmup();
    await c.feed(100, from: 5, to: 40); // a touch, 50 ms into the window
    expect(r.results, [(3, null)], reason: r.steps.join('\n'));
    expect(r.cues, ['start', 'follow', 'confirm']);
  });

  test('a touch that is already down when the warm-up ends counts', () async {
    final r = FastRig(th: _capture, max: 3);
    final c = _Capture(r);
    await r.begin();
    await c.upToWarmup();
    await c.feed(100, from: 0, to: 100); // whole packet of contact
    expect(r.results, [(3, null)], reason: r.steps.join('\n'));
  });

  test('a full gesture from the capture shapes: count 4, lift and re-touch '
      'after the follow-up cue', () async {
    final r = FastRig(th: _capture, max: 4);
    final c = _Capture(r);
    await r.begin();
    await c.upToWarmup();
    await c.feed(100, from: 0, to: 100); // touch -> count 3, cue starts
    expect(r.cues, ['start', 'follow']);
    await c.feed(100); // the lift while the cue plays
    await r.cuePlayed();
    await c.feed(100, from: 85, to: 100); // finger back, sensor latency
    await c.feed(100, from: 0, to: 100); // held -> count 4, done at max
    expect(r.results, [(4, null)], reason: r.steps.join('\n'));
    expect(r.cues, ['start', 'follow', 'follow', 'confirm']);
  });

  test('presence flips on with the warm-up and stays on: it is traced, and '
      'nothing is held back by it', () async {
    final r = FastRig(th: _capture, max: 3);
    final c = _Capture(r);
    await r.begin();
    await c.upToWarmup();
    await c.feed(100, from: 5, to: 40, flags: 0x0a);
    expect(r.steps.where((s) => s.startsWith('Presence on')), hasLength(1));
    expect(r.steps.where((s) => s.startsWith('Presence off')), isEmpty);
    expect(r.results, [(3, null)]);
  });

  test('the warm-up is whatever packet first carries samples: a 100-sample '
      'first packet is skipped too', () async {
    final r = FastRig(th: _capture, max: 3);
    final c = _Capture(r);
    await r.begin();
    await c.feed(0, flags: 0x00, s2: 0, quality: 0);
    await c.feed(100, from: 0, to: 100); // first with samples: warm-up
    expect(r.results, isEmpty, reason: r.steps.join('\n'));
    expect(r.cues, ['start']);
    await c.feed(100, from: 5, to: 40);
    expect(r.results, [(3, null)], reason: r.steps.join('\n'));
  });
}
