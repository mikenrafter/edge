// Tap acknowledgement and the Breathing exercise: no confirm buzz after a
// breathe tap. The gesture's own start cue has played, and the first inhale
// cue follows at once; an ack on top would make it skip as busy. Same rule as
// Tell the time. Any OTHER action that ran on the same tap still acks.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/gestures/tap_ack.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 7, 8);
final int _t0Sec = _t0.millisecondsSinceEpoch ~/ 1000;

StrapEvent _tap() => StrapEvent(
      eventId: 14,
      tsEpoch: _t0Sec,
      receivedAt: _t0.add(const Duration(seconds: 1)),
      hex: '',
      deviceId: 'band',
    );

GestureOutcome _o(DeviceAction a, [GestureStatus s = GestureStatus.ran]) =>
    GestureOutcome(action: a, status: s, timeSource: EventTimeSource.strap);

void main() {
  test('a breathe tap alone is not acked', () {
    expect(shouldAckTap(_tap(), [_o(DeviceAction.breathe)]), isFalse);
  });

  test('nor is breathe with Tell the time', () {
    expect(
        shouldAckTap(_tap(), [_o(DeviceAction.breathe), _o(DeviceAction.tellTime)]),
        isFalse);
  });

  test('breathe plus another action that ran: acked, as that action would be',
      () {
    expect(
        shouldAckTap(_tap(), [_o(DeviceAction.breathe), _o(DeviceAction.markMoment)]),
        isTrue);
  });

  test('breathe that failed, with nothing else ran: not acked', () {
    expect(
        shouldAckTap(_tap(), [_o(DeviceAction.breathe, GestureStatus.failed)]),
        isFalse);
  });

  test('the other in-app actions still ack (the rule is unchanged)', () {
    for (final a in [DeviceAction.markMoment, DeviceAction.logWater,
        DeviceAction.workoutToggle]) {
      expect(shouldAckTap(_tap(), [_o(a)]), isTrue, reason: a.id);
    }
  });
}
