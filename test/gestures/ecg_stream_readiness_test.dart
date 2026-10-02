// "Is the ECG stream really up?" The rule that gates the two-pulse
// acknowledgement. A command being written, or one stray packet, is not proof;
// two packets close together whose strap clock moves forward is.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_stream_readiness.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);

void main() {
  // Review finding F: "two packets within 1.5 s with a later strap time"
  // accepts a stale buffered burst (packets delivered back to back) and
  // strap-clock jumps. Steady means the SAMPLE clock is continuous (each
  // packet starts where the last one ended) and advances in step with the
  // wall clock.
  group('sample-clock continuity (finding F)', () {
    test('two packets delivered back to back are a burst, not a stream', () {
      final r = EcgStreamReadiness();
      r.offer(at: _t0, strapTime: 100);
      expect(
        r.offer(at: _t0.add(const Duration(milliseconds: 20)), strapTime: 101),
        isFalse,
        reason: '1 s of samples arrived in 20 ms: they were buffered',
      );
      expect(r.ready, isFalse);
    });

    test('a burst of stale packets then a live one becomes ready on the live '
        'pair only', () {
      final r = EcgStreamReadiness();
      for (var i = 0; i < 3; i++) {
        expect(
          r.offer(
              at: _t0.add(Duration(milliseconds: 10 * i)),
              strapTime: 100.0 + i),
          isFalse,
        );
      }
      expect(
        r.offer(at: _t0.add(const Duration(milliseconds: 1020)), strapTime: 103),
        isTrue,
      );
    });

    test('a strap-clock jump (100 -> 1000) is not continuous', () {
      final r = EcgStreamReadiness();
      r.offer(at: _t0, strapTime: 100);
      expect(
        r.offer(at: _t0.add(const Duration(seconds: 1)), strapTime: 1000),
        isFalse,
      );
      // ...but the jumped packet starts a new pair that can complete.
      expect(
        r.offer(at: _t0.add(const Duration(seconds: 2)), strapTime: 1001),
        isTrue,
      );
    });

    test('a packet that leaves a hole in the sample clock is not continuous',
        () {
      final r = EcgStreamReadiness();
      r.offer(at: _t0, strapTime: 100);
      expect(
        r.offer(at: _t0.add(const Duration(seconds: 1)), strapTime: 102),
        isFalse,
      );
    });

    test('packets with fewer samples are continuous by their own length', () {
      final r = EcgStreamReadiness();
      r.offer(at: _t0, strapTime: 100, sampleCount: 50);
      expect(
        r.offer(
          at: _t0.add(const Duration(milliseconds: 500)),
          strapTime: 100.5,
          sampleCount: 50,
        ),
        isTrue,
      );
    });

    test('start-to-end jitter inside 50 ms is still continuous', () {
      final r = EcgStreamReadiness();
      r.offer(at: _t0, strapTime: 100);
      expect(
        r.offer(at: _t0.add(const Duration(seconds: 1)), strapTime: 101.04),
        isTrue,
      );
    });

    test('samples that advance much faster than the wall clock are a burst',
        () {
      final r = EcgStreamReadiness();
      r.offer(at: _t0, strapTime: 100);
      // 1 s of samples arrived 300 ms after the last packet.
      expect(
        r.offer(at: _t0.add(const Duration(milliseconds: 300)), strapTime: 101),
        isFalse,
      );
    });
  });

  test('the pair window is 1.5 seconds', () {
    expect(EcgStreamReadiness.pairWindow, const Duration(milliseconds: 1500));
  });

  test('one packet is not enough', () {
    final r = EcgStreamReadiness();
    expect(r.offer(at: _t0, strapTime: 100), isFalse);
    expect(r.ready, isFalse);
  });

  test('a second packet within 1.5 s with a later strap time is ready', () {
    final r = EcgStreamReadiness();
    r.offer(at: _t0, strapTime: 100);
    expect(
      r.offer(at: _t0.add(const Duration(milliseconds: 1500)), strapTime: 101),
      isTrue,
    );
    expect(r.ready, isTrue);
  });

  test('a second packet after more than 1.5 s starts over', () {
    final r = EcgStreamReadiness();
    r.offer(at: _t0, strapTime: 100);
    expect(
      r.offer(at: _t0.add(const Duration(milliseconds: 1501)), strapTime: 101),
      isFalse,
    );
    // The late packet is the new first one; the next close packet completes it.
    expect(
      r.offer(at: _t0.add(const Duration(milliseconds: 2400)), strapTime: 102),
      isTrue,
    );
  });

  test('a repeated strap time (the same packet twice) is not flow', () {
    final r = EcgStreamReadiness();
    r.offer(at: _t0, strapTime: 100);
    expect(
      r.offer(at: _t0.add(const Duration(milliseconds: 100)), strapTime: 100),
      isFalse,
    );
    expect(r.ready, isFalse);
  });

  test('once ready it stays ready and offers keep returning true', () {
    final r = EcgStreamReadiness();
    r.offer(at: _t0, strapTime: 100);
    r.offer(at: _t0.add(const Duration(seconds: 1)), strapTime: 101);
    expect(
      r.offer(at: _t0.add(const Duration(seconds: 9)), strapTime: 102),
      isTrue,
    );
  });

  test('reset forgets the packets', () {
    final r = EcgStreamReadiness();
    r.offer(at: _t0, strapTime: 100);
    r.offer(at: _t0.add(const Duration(seconds: 1)), strapTime: 101);
    r.reset();
    expect(r.ready, isFalse);
    expect(r.offer(at: _t0.add(const Duration(seconds: 2)), strapTime: 102),
        isFalse);
  });
}
