import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

// The scrubber's raw recognizers must use the device's touch slop, as
// GestureDetector would. With an 8 pt device slop and the 18 pt default, a
// gradual mostly-horizontal drag would lose to the page scroll at 9 pt.
Widget _page(ValueNotifier<double?> picked, double slop) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
            size: const Size(360, 800),
            gestureSettings: DeviceGestureSettings(touchSlop: slop)),
        child: Scaffold(
          body: ListView(children: [
            const SizedBox(height: 200),
            ValueListenableBuilder<double?>(
              valueListenable: picked,
              builder: (_, v, _) => Scrubber(
                value: v,
                onChanged: (x) => picked.value = x,
                label: 'Chart',
                describe: (x) => x.toStringAsFixed(2),
                child: const SizedBox(height: 160, width: 360),
              ),
            ),
            const SizedBox(height: 2000),
          ]),
        ),
      ),
    );

Future<void> _gradualDiagonal(WidgetTester t) async {
  final g = await t.startGesture(t.getCenter(find.byType(Scrubber)));
  // Small steps, each 14:9 (horizontal dominant by more than 1.5×).
  for (var i = 0; i < 6; i++) {
    await g.moveBy(const Offset(14 / 3, 3));
    await t.pump();
  }
  await g.up();
  await t.pump();
}

void main() {
  testWidgets('with an 8 pt device slop a gradual horizontal-dominant drag '
      'scrubs instead of scrolling', (t) async {
    final picked = ValueNotifier<double?>(null);
    await t.pumpWidget(_page(picked, 8));
    final scroll = t.state<ScrollableState>(find.byType(Scrollable)).position;
    await _gradualDiagonal(t);
    expect(picked.value, isNotNull, reason: 'the scrubber won the arena');
    expect(scroll.pixels, 0, reason: 'the page did not scroll');
  });
}
