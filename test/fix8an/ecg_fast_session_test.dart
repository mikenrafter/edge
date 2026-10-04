// EcgTapSession in fast mode (8AN C), over fakes. Counting stays SAMPLE-timed
// (EcgTapCounter and its start/gap/confirm ms thresholds on the 10 ms
// ecgContactMask), so quick taps still work. Fast mode differs from accurate
// in three ways: PREPARE has no raw-save (see ecg_fast_prepare_test), no
// steady-stream readiness wait, no sensorSettle. Instead it skips the band's
// warm-up packet (the first one with samples) and opens the first touch window
// at that packet's END. The band's presence bit is only traced; the capture
// replay is in ecg_fast_capture_test.dart.
//
// Fast mode starts the stream through `beginFastStream` and never calls
// `beginStream`; accurate mode never calls `beginFastStream`. Trace (8AN A):
// 'Presence on|off, N ms after the tap.' and 'Sample contact on|off, N ms
// after the tap.' as in ecg_fast_measure_test.dart; a step starting 'Fast
// mode' is logged when a fast gesture starts.
//
// Packet geometry: a packet is 100 samples at 10 ms; `from`/`to` are sample
// indexes of the moving trace. Contact 5..25 reads as a 200 ms touch (the mask
// widens it to whole 50 ms blocks, 5..29), long enough for the 200 ms gap
// threshold to engage; 5..15 is a 100 ms blip that must not count.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_mode.dart';

import 'support/fast_rig.dart';

EcgTapThresholds get _wide => EcgTapThresholds(startMs: 1100);

void main() {
  group('the fast start', () {
    test('starts the stream through the fast entry only', () async {
      final r = FastRig();
      await r.begin();
      expect(r.beganFast, 1);
      expect(r.beganAccurate, 0);
      expect(r.steps.any((s) => s.startsWith('Fast mode')), isTrue,
          reason: r.steps.join('\n'));
    });

    test('accurate mode never touches the fast entry', () async {
      final r = FastRig(mode: EcgTapMode.accurate);
      await r.begin();
      expect(r.beganAccurate, 1);
      expect(r.beganFast, 0);
    });

    test('no settle wait: a touch in the packet right after the warm-up is '
        'counted at once', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      expect(r.cues, ['start']);
      await r.warmup(1000);
      expect(r.cues, ['start'], reason: 'the warm-up never counts');
      await r.feed(1001, presence: true, from: 5, to: 25);
      expect(r.cues, ['start', 'follow'],
          reason: 'accurate mode would still be settling for 2.5 s');
      expect(r.session.active, isTrue);
    });

    test('no steady-stream wait: the warm-up and ONE packet are enough to '
        'decide', () async {
      final r = FastRig(max: 3, th: _wide);
      await r.begin();
      await r.warmup(1000);
      await r.feed(1001, presence: true, from: 5, to: 25);
      expect(r.results, [(3, null)]);
      expect(r.cues, ['start', 'follow', 'confirm']);
    });

    test('a touch two packets after the warm-up still counts inside a wide '
        'first window', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.warmup(1000);
      await r.feed(1001, presence: true, from: 0, to: 0);
      expect(r.cues, ['start']);
      expect(r.results, isEmpty, reason: 'the first window is still open');
      await r.feed(1002, presence: true, from: 5, to: 25);
      expect(r.cues, ['start', 'follow']);
    });

    test('with no touch in the first window the gesture is a plain double '
        'tap', () async {
      final r = FastRig();
      await r.begin();
      await r.warmup(1000);
      expect(r.results, isEmpty, reason: r.steps.join('\n'));
      await r.feed(1001, presence: true);
      expect(r.results, [(2, null)]);
      expect(r.cues, ['start', 'confirm']);
      expect(r.ended, 1);
    });
  });

  group('sample-timed counting', () {
    test('a 200 ms tap counts', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.warmup(1000);
      await r.feed(1001, presence: true, from: 5, to: 25);
      expect(r.cues, ['start', 'follow']);
    });

    test('a 100 ms blip does not count (the ms thresholds still decide, not '
        'whole packets)', () async {
      final r = FastRig(th: _wide, max: 3);
      await r.begin();
      await r.warmup(1000);
      await r.feed(1001, presence: true, from: 5, to: 15);
      await r.feed(1002, presence: true);
      expect(r.cues, isNot(contains('follow')));
      expect(r.results, [(2, null)]);
    });

    test('presence says yes but the samples say no: not a touch', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.warmup(1000, contact: false);
      await r.feed(1001, presence: true);
      await r.feed(1002, presence: true);
      expect(r.cues, isNot(contains('follow')));
      expect(r.results, [(2, null)]);
    });

    test('the band reporting no presence does not veto a touch: presence is '
        'only traced', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.warmup(1000);
      await r.feed(1001, presence: false, from: 5, to: 25);
      expect(r.cues, ['start', 'follow'], reason: r.steps.join('\n'));
    });

    test('contact in the warm-up packet never counts, however long', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.feed(1000, presence: true, count: 49, from: 0, to: 49);
      expect(r.cues, ['start']);
      expect(r.steps.where((s) => s.startsWith('Warm-up packet skipped')),
          hasLength(1));
    });

    test('only the first packet with samples is skipped', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.feed(999, count: 0); // an empty packet is not the warm-up
      expect(r.steps.where((s) => s.startsWith('Warm-up packet skipped')),
          isEmpty);
      await r.warmup(1000);
      await r.feed(1001, presence: true, from: 5, to: 25);
      expect(r.steps.where((s) => s.startsWith('Warm-up packet skipped')),
          hasLength(1));
      expect(r.cues, ['start', 'follow']);
    });
  });

  group('the trace (8AN A, fast mode)', () {
    test('presence and sample-contact transitions carry the ms since the tap',
        () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.feed(999, count: 0);
      await r.warmup(1000, contact: false);
      await r.feed(1001, presence: true, from: 5, to: 25);
      final lines = r.steps.where((s) =>
          RegExp(r'^(Presence|Sample contact) (on|off), \d+ ms after the tap')
              .hasMatch(s));
      expect(lines.map((s) => s.split(' ms').first), [
        'Presence on, 2500',
        'Sample contact on, 3500',
      ], reason: r.steps.join('\n'));
    });

    test('the warm-up packet is traced like any other: its raw contact is '
        'logged though it never counts', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.warmup(1000);
      expect(r.steps.where((s) => s.startsWith('Sample contact on, 2500')),
          hasLength(1),
          reason: r.steps.join('\n'));
      expect(r.steps.where((s) => s.startsWith('Presence on, 2500')),
          hasLength(1));
      expect(r.steps.where((s) => s.contains('14 with contact')), isNotEmpty);
    });
  });

  group('every exit stops the stream once', () {
    test('counted: the stream is stopped and the interval written', () async {
      final r = FastRig(max: 3, th: _wide);
      await r.begin();
      await r.warmup(1000);
      await r.feed(1001, presence: true, from: 5, to: 25);
      expect(r.ended, 1);
      expect(r.records, hasLength(1));
      expect(r.records.single.finalCount, 3);
      expect(r.session.active, isFalse);
    });

    test('abandoned on a lost link', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.warmup(1000);
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
      expect(r.results.single.$2, contains('link_lost'));
      expect(r.records, hasLength(1));
    });

    test('abandoned on a stall', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.warmup(1000);
      r.now = r.now.add(const Duration(seconds: 10));
      r.session.poll();
      await r.settle();
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
      expect(r.results.single.$2, contains('stalled'));
    });

    test('abandoned on a stall before the warm-up has arrived', () async {
      final r = FastRig(th: _wide);
      await r.begin();
      await r.feed(999, count: 0);
      r.now = r.now.add(const Duration(seconds: 10));
      r.session.poll();
      await r.settle();
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
      expect(r.results.single.$2, contains('stalled'));
    });

    test('a throwing result listener still stops the stream and frees the '
        'session', () async {
      final r = FastRig(max: 3, th: _wide, throwOnFinish: true);
      await r.begin();
      await r.warmup(1000);
      await r.feed(1001, presence: true, from: 5, to: 25);
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
      await r.begin(); // and the next gesture can run
      expect(r.session.active, isTrue);
    });

    test('a fast start that never answers is stopped and the gesture ends',
        () async {
      final r = FastRig(
        beginTimeout: const Duration(milliseconds: 20),
        beginFast: () => Completer<bool>().future,
      );
      await r.begin();
      await r.settle();
      expect(r.session.active, isFalse);
      expect(r.ended, greaterThanOrEqualTo(1),
          reason: 'a late-starting stream is stopped');
      expect(r.beganFast, 2, reason: 'the start is retried once (8AK)');
      expect(r.beganAccurate, 0, reason: 'the retry stays on the fast entry');
      expect(r.results.single.$1, 2, reason: 'double-tap fallback');
    });

    test('a refused fast start is retried once, then ends', () async {
      final r = FastRig(beginFast: () async => false);
      await r.begin();
      await r.settle();
      expect(r.beganFast, 2);
      expect(r.beganAccurate, 0);
      expect(r.session.active, isFalse);
      expect(r.results, hasLength(1));
    });

    test('a session is reusable after every exit, and the next gesture skips '
        'its own warm-up packet', () async {
      final r = FastRig(max: 3, th: _wide);
      await r.begin();
      await r.warmup(1000);
      await r.feed(1001, presence: true, from: 5, to: 25);
      expect(r.session.active, isFalse);
      await r.begin();
      expect(r.session.active, isTrue);
      // The first sampled packet of the new gesture is a warm-up again.
      await r.feed(1000, presence: true, from: 5, to: 25);
      expect(r.cues.where((c) => c == 'follow'), hasLength(1));
      expect(r.results, [(3, null)]);
      await r.feed(1001, presence: true, from: 5, to: 25);
      expect(r.cues.where((c) => c == 'follow'), hasLength(2));
      expect(r.results, [(3, null), (3, null)]);
    });
  });
}
