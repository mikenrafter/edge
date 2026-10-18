// EcgSampleClock (review finding F): where "now" is on the ECG sample clock.
//
// A packet's newest sample was acquired some time before the phone got it, and
// BLE buffering can make that 1 s or more. The estimate uses the packet that
// was LEAST delayed, (receipt - newest sample time) minimised over recent
// packets: the true delay is at least that, so mapping through it never anchors
// the touch window behind the real sample clock.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_stream_readiness.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);

Duration _ms(int v) => Duration(milliseconds: v);
Duration _s(double v) => Duration(microseconds: (v * 1e6).round());

void main() {
  test('no packets: no estimate', () {
    final c = EcgSampleClock();
    expect(c.hasEstimate, isFalse);
    expect(c.sampleAt(_t0), isNull);
    expect(c.baseline, isNull);
  });

  test('one packet maps its receipt to its newest sample', () {
    final c = EcgSampleClock()
      ..add(receivedAt: _t0.add(_ms(500)), sampleEnd: _s(1001));
    expect(c.sampleAt(_t0.add(_ms(500))), _s(1001));
    expect(c.sampleAt(_t0.add(_ms(800))), _s(1001.3));
  });

  test('the least-delayed packet sets the offset', () {
    final c = EcgSampleClock()
      // on time: received exactly when its newest sample was made
      ..add(receivedAt: _t0.add(_s(1.0)), sampleEnd: _s(1001))
      // the same stream, 1 s late
      ..add(receivedAt: _t0.add(_s(3.0)), sampleEnd: _s(1002));
    expect(c.sampleAt(_t0.add(_s(3.0))), _s(1003),
        reason: 'the late packet does not drag the clock back');
  });

  test('a stale initial burst never pulls the estimate behind the fresh packet',
      () {
    final c = EcgSampleClock()
      ..add(receivedAt: _t0.add(_ms(300)), sampleEnd: _s(1001))
      ..add(receivedAt: _t0.add(_ms(310)), sampleEnd: _s(1002))
      ..add(receivedAt: _t0.add(_ms(320)), sampleEnd: _s(1003))
      // live: arrives 1 s after the burst with 1 s more samples
      ..add(receivedAt: _t0.add(_ms(1320)), sampleEnd: _s(1004));
    // 0.18 s after the live packet, its samples are at 1004.18, not 1004.0+.
    expect(c.sampleAt(_t0.add(_ms(1500))), _s(1004.18));
  });

  test('excess is how much later a packet was than the best one', () {
    final c = EcgSampleClock()
      ..add(receivedAt: _t0.add(_s(1.0)), sampleEnd: _s(1001))
      ..add(receivedAt: _t0.add(_s(3.0)), sampleEnd: _s(1002));
    expect(c.excessOf(receivedAt: _t0.add(_s(3.0)), sampleEnd: _s(1002)),
        _s(1.0));
    expect(c.excessOf(receivedAt: _t0.add(_s(1.0)), sampleEnd: _s(1001)),
        Duration.zero);
  });

  test('only the most recent packets are kept', () {
    final c = EcgSampleClock(keep: 3)
      ..add(receivedAt: _t0, sampleEnd: _s(1000)) // best, but will fall out
      ..add(receivedAt: _t0.add(_s(2.5)), sampleEnd: _s(1001))
      ..add(receivedAt: _t0.add(_s(3.5)), sampleEnd: _s(1002))
      ..add(receivedAt: _t0.add(_s(4.5)), sampleEnd: _s(1003));
    // baseline now 1.5 s, not 0.
    expect(c.baseline, _s(-1000 + 1.5) + _t0.difference(DateTime.utc(1970)));
  });

  test('reset forgets everything', () {
    final c = EcgSampleClock()..add(receivedAt: _t0, sampleEnd: _s(1000));
    c.reset();
    expect(c.hasEstimate, isFalse);
  });
}
