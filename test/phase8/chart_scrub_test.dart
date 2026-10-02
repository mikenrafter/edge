// 8F — ChartScrub: the one scrubbable wrapper for every chart.
//
// Tap or drag places a vertical cursor that tracks the finger and a readout
// pill with whatever the chart says is at that point; a point with no data
// reads "No data here". Scatter/grid charts use the nearest mode (no line).
// Built on Scrubber. See test/phase8/CONTRACTS.md §8F.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _w = 300.0, _h = 120.0;

/// Four slots; slot 2 is a gap.
const _series = <double?>[60, 64, null, 70];

String? _readout(double at) {
  final i = (at * (_series.length - 1)).round();
  final v = _series[i];
  return v == null ? null : '0${7 + i}:00 · ${v.round()} bpm';
}

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
  return box + Offset(_w * frac.clamp(0.0, 0.995), _h / 2);
}

Widget _line({ChartScrubMode mode = ChartScrubMode.line}) => ChartScrub(
      label: 'Heart rate',
      readout: _readout,
      mode: mode,
      child: CustomPaint(
        size: Size.infinite,
        painter: LineChart(_series, Colors.red),
      ),
    );

void main() {
  testWidgets('nothing is drawn before a touch', (t) async {
    await _pump(t, _line());
    expect(find.byKey(ChartScrub.cursorKey), findsNothing);
    expect(find.byKey(ChartScrub.readoutKey), findsNothing);
  });

  testWidgets('is built on Scrubber (slider semantics come with it)',
      (t) async {
    await _pump(t, _line());
    expect(
        find.descendant(
            of: find.byType(ChartScrub), matching: find.byType(Scrubber)),
        findsOneWidget);
  });

  testWidgets('line chart: tap places cursor + readout at the finger',
      (t) async {
    await _pump(t, _line());
    await t.tapAt(_at(t, 0));
    await t.pump();
    expect(find.byKey(ChartScrub.cursorKey), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(ChartScrub.readoutKey),
            matching: find.text('07:00 · 60 bpm')),
        findsOneWidget);
    expect(t.getCenter(find.byKey(ChartScrub.cursorKey)).dx,
        moreOrLessEquals(_at(t, 0).dx, epsilon: 2));
  });

  testWidgets('line chart: the cursor and readout track a drag', (t) async {
    await _pump(t, _line());
    final g = await t.startGesture(_at(t, 1 / 3));
    await t.pump();
    expect(find.text('08:00 · 64 bpm'), findsOneWidget);
    await g.moveTo(_at(t, 1));
    await t.pump();
    expect(find.text('10:00 · 70 bpm'), findsOneWidget);
    expect(find.text('08:00 · 64 bpm'), findsNothing);
    expect(t.getCenter(find.byKey(ChartScrub.cursorKey)).dx,
        moreOrLessEquals(_at(t, 1).dx, epsilon: 2));
    await g.up();
  });

  testWidgets('a gap reads "No data here", never an interpolated value',
      (t) async {
    await _pump(t, _line());
    await t.tapAt(_at(t, 2 / 3));
    await t.pump();
    expect(ChartScrub.noData, 'No data here');
    expect(
        find.descendant(
            of: find.byKey(ChartScrub.readoutKey),
            matching: find.text('No data here')),
        findsOneWidget);
    expect(find.textContaining('bpm'), findsNothing);
  });

  testWidgets('bar chart: same cursor and readout over the bars', (t) async {
    await _pump(
        t,
        ChartScrub(
          label: 'Steps by hour',
          readout: (at) => 'bar ${(at * 3).round()}',
          child: CustomPaint(
            size: Size.infinite,
            painter: Bars(const [3, 5, 2, 8], Colors.blue),
          ),
        ));
    await t.tapAt(_at(t, 1));
    await t.pump();
    expect(find.byKey(ChartScrub.cursorKey), findsOneWidget);
    expect(find.text('bar 3'), findsOneWidget);
  });

  testWidgets('nearest mode (scatter/grid): readout, but no cursor line',
      (t) async {
    await _pump(t, _line(mode: ChartScrubMode.nearest));
    await t.tapAt(_at(t, 0));
    await t.pump();
    expect(find.byKey(ChartScrub.cursorKey), findsNothing);
    expect(find.text('07:00 · 60 bpm'), findsOneWidget);
  });

  testWidgets('the readout is also the slider value for a screen reader',
      (t) async {
    final handle = t.ensureSemantics();
    await _pump(t, _line());
    await t.tapAt(_at(t, 0));
    await t.pump();
    expect(
        find.bySemanticsLabel('Heart rate'), findsWidgets);
    final node = t.getSemantics(find.byType(Scrubber));
    expect(node.value, '07:00 · 60 bpm');
    handle.dispose();
  });
}
