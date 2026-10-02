// "Is the ECG stream really up?" The rule that gates the two-pulse
// acknowledgement. A command being written, or one stray packet, is not proof;
// two packets close together whose strap clock moves forward is.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_stream_readiness.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);

void main() {
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
