// 8F — ChartScrub: the one scrubbable wrapper for every chart.
//
// Tap or drag places a vertical cursor that tracks the finger; the values at
// that point are shown in a row under the chart (see chart_key_readout_test.dart
// for the row itself). Scatter/grid charts use the nearest mode (no line).
// Built on Scrubber. See test/phase8/CONTRACTS.md §8F.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _w = 300.0, _h = 200.0;

/// Four slots; slot 2 is a gap.
const _series = <double?>[60, 64, null, 70];

Future<void> _pump(WidgetTester t, Widget chart) async {
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: Center(child: SizedBox(width: _w, height: _h, child: chart)),
    ),
  ));
  await t.pump();
}

/// A point [frac] of the way across the chart. 1.0 is nudged inside: the
/// right edge itself is outside the hit box.
Offset _at(WidgetTester t, double frac) {
  final box = t.getTopLeft(find.byType(ChartScrub));
  return box + Offset(_w * frac.clamp(0.0, 0.995), 40);
}

Widget _line({ChartScrubMode mode = ChartScrubMode.line}) => ChartScrub(
      label: 'Heart rate',
      mode: mode,
      time: (at) => '${7 + ChartScrub.slotAt(_series.length, at)}:00',
      keys: [
        ChartKey.slots(
            'Heart rate (bpm)', Colors.red, _series, (i, v) => '${v.round()} bpm'),
      ],
      child: CustomPaint(
        size: Size.infinite,
        painter: LineChart(_series, Colors.red),
      ),
    );

void main() {
  testWidgets('nothing is drawn on the chart before a touch', (t) async {
    await _pump(t, _line());
    expect(find.byKey(ChartScrub.cursorKey), findsNothing);
  });

  testWidgets('is built on Scrubber (slider semantics come with it)',
      (t) async {
    await _pump(t, _line());
    expect(
        find.descendant(
            of: find.byType(ChartScrub), matching: find.byType(Scrubber)),
        findsOneWidget);
  });

  testWidgets('line chart: tap places the cursor at the finger', (t) async {
    await _pump(t, _line());
    await t.tapAt(_at(t, 0));
    await t.pump();
    expect(find.byKey(ChartScrub.cursorKey), findsOneWidget);
    expect(t.getCenter(find.byKey(ChartScrub.cursorKey)).dx,
        moreOrLessEquals(_at(t, 0).dx, epsilon: 2));
    expect(find.text('60 bpm'), findsOneWidget);
  });

  testWidgets('line chart: the cursor tracks a drag', (t) async {
    await _pump(t, _line());
    final g = await t.startGesture(_at(t, 1 / 3));
    await t.pump();
    expect(find.text('64 bpm'), findsOneWidget);
    await g.moveTo(_at(t, 1));
    await t.pump();
    expect(find.text('70 bpm'), findsOneWidget);
    expect(find.text('64 bpm'), findsNothing);
    expect(t.getCenter(find.byKey(ChartScrub.cursorKey)).dx,
        moreOrLessEquals(_at(t, 1).dx, epsilon: 2));
    await g.up();
  });

  testWidgets('a gap reads "—", never an interpolated value', (t) async {
    await _pump(t, _line());
    await t.tapAt(_at(t, 2 / 3));
    await t.pump();
    expect(ChartScrub.noData, 'No data here');
    expect(find.text('—'), findsOneWidget);
    expect(find.textContaining(' bpm'), findsNothing);
  });

  testWidgets('bar chart: same cursor over the bars, bar under the finger',
      (t) async {
    const bars = <double?>[3, 5, 2, 8];
    await _pump(
        t,
        ChartScrub(
          label: 'Steps by hour',
          time: (at) => 'hour ${ChartScrub.slotAt(4, at, bars: true)}',
          keys: [
            ChartKey.slots('Steps', Colors.blue, bars,
                (i, v) => '${v.round()} steps',
                bars: true),
          ],
          child: CustomPaint(
            size: Size.infinite,
            painter: Bars(bars, Colors.blue),
          ),
        ));
    await t.tapAt(_at(t, 1));
    await t.pump();
    expect(find.byKey(ChartScrub.cursorKey), findsOneWidget);
    expect(find.text('8 steps'), findsOneWidget);
    expect(find.text('hour 3'), findsOneWidget);
  });

  testWidgets('nearest mode (scatter/grid): no cursor line', (t) async {
    await _pump(t, _line(mode: ChartScrubMode.nearest));
    await t.tapAt(_at(t, 0));
    await t.pump();
    expect(find.byKey(ChartScrub.cursorKey), findsNothing);
    expect(find.text('60 bpm'), findsOneWidget);
  });

  testWidgets('the readout is also the slider value for a screen reader',
      (t) async {
    final handle = t.ensureSemantics();
    await _pump(t, _line());
    await t.tapAt(_at(t, 0));
    await t.pump();
    expect(find.bySemanticsLabel('Heart rate'), findsWidgets);
    final node = t.getSemantics(find.byType(Scrubber));
    expect(node.value, '7:00, Heart rate (bpm) 60 bpm');
    handle.dispose();
  });

  test('slotAt maps a fraction to the slot a line or a bar reads', () {
    expect(ChartScrub.slotAt(4, 0), 0);
    expect(ChartScrub.slotAt(4, 1), 3);
    expect(ChartScrub.slotAt(4, 2 / 3), 2);
    expect(ChartScrub.slotAt(4, 0.99, bars: true), 3);
    expect(ChartScrub.slotAt(4, 0.26, bars: true), 1);
    expect(ChartScrub.slotAt(1, 0.7), 0);
    expect(ChartScrub.slotAt(0, 0.5), 0);
  });
}
