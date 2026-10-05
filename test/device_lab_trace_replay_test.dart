// 8V: the Device lab's ECG packet export replays off the band. The fixture is
// the 2026-10-02 18:17 lab run (five gestures on a WHOOP MG), reconstructed
// from that log; see its header and test/support/ecg_trace.dart.
//
// First the replay must reproduce what the band run decided, with the rules it
// ran under. Then it shows what the current rules do with the same packets.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';

import 'support/ecg_trace.dart';

const _fixture = 'test/fixtures/ecg_traces/2026-10-02_1817_lab.txt';

void main() {
  // The fixture's samples are reconstructed (a constant 120 where the log said
  // there was signal); 8X contact is movement, so they are loaded as a moving
  // trace over the same samples (see Trace.load).
  final trace = Trace.load(_fixture, reconstructed: true);

  test('the fixture has the five sessions and their packets', () {
    expect(trace.sessions, hasLength(5));
    expect(trace.packets, hasLength(57));
    for (final s in trace.sessions) {
      expect(trace.of(s.tag), isNotEmpty, reason: s.tag);
    }
  });

  group('replayed with the rules the band ran (no reacquire allowance)', () {
    for (final s in trace.sessions) {
      test('${s.tag}: ${s.count} taps, as on the band', () async {
        final r = await replayTrace(trace.of(s.tag),
            thresholds: thresholdsOf(s.settings), reacquire: Duration.zero);
        expect(r.count, s.count);
        expect(r.buzzes, [1],
            reason: 'one follow-up, for the increment from 2 to 3');
      });
    }

    test('every window opened 2.5 s after the stream\'s first sample',
        () async {
      for (final s in trace.sessions) {
        final r = await replayTrace(trace.of(s.tag),
            thresholds: thresholdsOf(s.settings), reacquire: Duration.zero);
        expect(r.steps, contains(contains('2500 ms after the first sample')),
            reason: s.tag);
      }
    });

    test('with the strap time read as the newest sample, every sampled packet '
        'after the first is continuous', () async {
      for (final s in trace.sessions) {
        final r = await replayTrace(trace.of(s.tag),
            thresholds: thresholdsOf(s.settings), reacquire: Duration.zero);
        final sampled = r.steps
            .where((l) => l.startsWith('Packet ') && !l.contains(': 0 samples'))
            .skip(1);
        expect(sampled, everyElement(contains('continuous with the last packet')),
            reason: s.tag);
      }
    });
  });

  group('replayed with the current rules (1.5 s reacquire)', () {
    // 18:19:10: the finger showed again 1.96 s after the lift, after the
    // 1.2 s window had closed.
    test('tap 18:19:10.695: the late re-touch is tap 4', () async {
      const tag = 'tap 18:19:10.695';
      final s = trace.sessions.firstWhere((x) => x.tag == tag);
      final r = await replayTrace(trace.of(tag),
          thresholds: thresholdsOf(s.settings));
      expect(r.counted, 4);
      expect(r.count, isNull,
          reason: 'the band stopped streaming before the new window ended');
    });

    // 18:19:41 (gap 500): the finger showed again 2.16 s after the lift, now
    // inside the window, but a 500 ms gap also needs 500 ms of contact to
    // engage and the stream ended 240 ms into it.
    test('tap 18:19:41.688: the late re-touch starts in time and is still '
        'being held when the stream ends', () async {
      const tag = 'tap 18:19:41.688';
      final s = trace.sessions.firstWhere((x) => x.tag == tag);
      final r = await replayTrace(trace.of(tag),
          thresholds: thresholdsOf(s.settings));
      expect(r.count, isNull, reason: 'no final count: the window is open');
      expect(r.counted, 3);
      expect(r.steps, isNot(contains(startsWith('Final count'))));
    });

    for (final tag in [
      'tap 18:17:57.367',
      'tap 18:18:19.181',
      'tap 18:18:34.728',
    ]) {
      test('$tag: still 3, now waiting longer for a fourth', () async {
        final s = trace.sessions.firstWhere((x) => x.tag == tag);
        final r = await replayTrace(trace.of(tag),
            thresholds: thresholdsOf(s.settings));
        expect(r.counted, 3);
        expect(r.count, isNull);
      });
    }
  });

  test('a copied Device lab log parses as a trace (the export round-trips)',
      () {
    final lab = DeviceLabLog();
    for (final p in trace.of('tap 18:19:10.695')) {
      lab.addPacket(p.r, p.receivedAt, tag: 'again');
    }
    final again = Trace.parse(lab.toPlainText());
    final orig = trace.of('tap 18:19:10.695');
    expect(again.packets, hasLength(orig.length));
    for (var i = 0; i < orig.length; i++) {
      expect(again.packets[i].tag, 'again');
      expect(again.packets[i].receivedAt, orig[i].receivedAt);
      expect(again.packets[i].r.strapTime, orig[i].r.strapTime);
      expect(again.packets[i].r.samples, orig[i].r.samples);
    }
  });
}
