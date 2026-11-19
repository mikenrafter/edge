// A classifier stub for dispatcher payload tests. Counting itself is covered
// through DoubleTapRepeatSession in double_tap_repeat_dispatch_test.dart.
import 'package:openstrap_edge/gestures/double_tap_repeat.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';

class CountedTapSession extends DoubleTapRepeatSession {
  CountedTapSession(this.nextCount)
      : super(maxTaps: () => 5, window: () => const Duration(seconds: 1));
  final int Function() nextCount;

  @override
  Future<int> begin(StrapEvent first) async => nextCount();
}
