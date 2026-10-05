// The scrubbed values live in a row UNDER the chart, in the
// chart's own key, not in a floating tooltip a thumb would cover.
//
// ChartScrub keeps the cursor. The values go to a ChartKeyReadout: a fixed-
// height row with the time first, then one cell per series (swatch, label,
// value). Inside a ChartFrame the cells ARE the frame's key, so the value sits
// directly under its own label. At rest the row shows the latest point; before
// any data it shows "—"; an absent value is "—", never a 0.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _w = 300.0;

const _hr = <double?>[60, 64, null, 70];
const _red = Color(0xFFE5484D);
const _blue = Color(0xFF3E63DD);

String _t(int i) => '${(7 + i).toString().padLeft(2, '0')}:00';

ChartScrub _scrub({
  List<double?> hr = _hr,
  bool gaps = false,
  List<ChartKey>? keys,
  ChartScrubMode mode = ChartScrubMode.line,
}) =>
    ChartScrub(
      label: 'Heart rate',
      mode: mode,
      gaps: gaps,
      time: (at) => _t(ChartScrub.slotAt(hr.length, at)),
      keys: keys ??
          [
            ChartKey.slots(
                'Heart rate (bpm)', _red, hr, (i, v) => '${v.round()} bpm'),
          ],
      child: CustomPaint(size: Size.infinite, painter: LineChart(hr, _red)),
    );

Future<void> _pump(WidgetTester t, Widget chart,
    {double scale = 1, double h = 220}) async {
  // A phone-width view tall enough for the tallest case; the test surface is
  // 800x600 by default and would clamp the chart's box.
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(400, 3000);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: Center(child: SizedBox(width: _w, height: h, child: chart)),
      ),
    ),
  ));
  await t.pump();
}

Offset _at(WidgetTester t, double frac) {
  final box = t.getTopLeft(find.byType(ChartScrub));
  return box + Offset(_w * frac.clamp(0.0, 0.995), 40);
}

Finder _cell(String label) => find.byKey(ValueKey('chart-key-cell:$label'));
Finder _value(String label) => find.byKey(ValueKey('chart-key-value:$label'));
Finder _swatch(String label) =>
    find.byKey(ValueKey('chart-key-swatch:$label'));

void main() {
  group('readout row, standalone', () {
    testWidgets('there is no floating tooltip: the value is in the row only',
        (t) async {
      await _pump(t, _scrub());
      await t.tapAt(_at(t, 0));
      await t.pump();
      expect(find.byKey(ChartScrub.cursorKey), findsOneWidget);
      final v = find.text('60 bpm');
      expect(v, findsOneWidget);
      expect(find.ancestor(of: v, matching: find.byType(ChartKeyReadout)),
          findsOneWidget);
      // The old pill was a Positioned overlay inside the chart's own stack.
      expect(
          find.descendant(
              of: find.byType(Scrubber), matching: find.text('60 bpm')),
          findsNothing);
    });

    testWidgets('a cell has the swatch colour, the label and the value',
        (t) async {
      await _pump(t, _scrub());
      await t.tapAt(_at(t, 0));
      await t.pump();
      expect(_cell('Heart rate (bpm)'), findsOneWidget);
      expect(
          find.descendant(
              of: _cell('Heart rate (bpm)'),
              matching: find.text('Heart rate (bpm)')),
          findsOneWidget);
      expect(
          find.descendant(
              of: _cell('Heart rate (bpm)'),
              matching: _value('Heart rate (bpm)')),
          findsOneWidget);
      final sw = t.widget<DecoratedBox>(find.descendant(
          of: _swatch('Heart rate (bpm)'), matching: find.byType(DecoratedBox)));
      expect((sw.decoration as BoxDecoration).color, _red);
    });

    testWidgets('the time comes first in the row', (t) async {
      await _pump(t, _scrub());
      await t.tapAt(_at(t, 1 / 3));
      await t.pump();
      final time = find.byKey(ChartKeyReadout.timeKey);
      expect(find.descendant(of: time, matching: find.text('08:00')),
          findsOneWidget);
      expect(t.getTopLeft(time).dx,
          lessThan(t.getTopLeft(_cell('Heart rate (bpm)')).dx));
    });

    testWidgets('nothing scrubbed: the latest point and its time', (t) async {
      await _pump(t, _scrub());
      // Slot 3 (10:00, 70 bpm) is the last one with data.
      expect(find.text('10:00'), findsOneWidget);
      expect(find.text('70 bpm'), findsOneWidget);
      expect(find.text(ChartKeyReadout.latest), findsOneWidget);
      await t.tapAt(_at(t, 0));
      await t.pump();
      expect(find.text(ChartKeyReadout.selected), findsOneWidget);
    });

    testWidgets('the latest skips trailing holes', (t) async {
      await _pump(t, _scrub(hr: const [60, 64, 66, null, null]));
      expect(find.text('66 bpm'), findsOneWidget);
      expect(find.text('09:00'), findsOneWidget);
    });

    testWidgets('before any data the row reads "—", never a number',
        (t) async {
      await _pump(t, _scrub(hr: const [null, null, null]));
      expect(
          find.descendant(
              of: _value('Heart rate (bpm)'), matching: find.text('—')),
          findsOneWidget);
      expect(find.text('0 bpm'), findsNothing);
      expect(
          find.descendant(
              of: find.byKey(ChartKeyReadout.timeKey), matching: find.text('—')),
          findsOneWidget);
    });

    testWidgets('a hole under the finger is "—", not 0, not a neighbour',
        (t) async {
      await _pump(t, _scrub(gaps: true));
      await t.tapAt(_at(t, 2 / 3));
      await t.pump();
      expect(
          find.descendant(
              of: _value('Heart rate (bpm)'), matching: find.text('—')),
          findsOneWidget);
      expect(find.text('64 bpm'), findsNothing);
      expect(find.text('70 bpm'), findsNothing);
      expect(find.text('0 bpm'), findsNothing);
      // The time of the finger is still said.
      expect(find.text('09:00'), findsOneWidget);
    });

    testWidgets('the cursor and the row track a drag', (t) async {
      await _pump(t, _scrub());
      final g = await t.startGesture(_at(t, 0));
      await t.pump();
      expect(find.text('60 bpm'), findsOneWidget);
      await g.moveTo(_at(t, 1 / 3));
      await t.pump();
      expect(find.text('64 bpm'), findsOneWidget);
      expect(find.text('60 bpm'), findsNothing);
      expect(t.getCenter(find.byKey(ChartScrub.cursorKey)).dx,
          moreOrLessEquals(_at(t, 1 / 3).dx, epsilon: 2));
      await g.up();
    });

    testWidgets('nearest mode: row, but no cursor line', (t) async {
      await _pump(t, _scrub(mode: ChartScrubMode.nearest));
      await t.tapAt(_at(t, 0));
      await t.pump();
      expect(find.byKey(ChartScrub.cursorKey), findsNothing);
      expect(find.text('60 bpm'), findsOneWidget);
    });

    testWidgets('one cell per series, in order', (t) async {
      await _pump(
          t,
          _scrub(keys: [
            ChartKey.slots(
                'Heart rate (bpm)', _red, _hr, (i, v) => '${v.round()} bpm'),
            ChartKey.slots('Movement (% of time)', _blue,
                const [10, 20, 30, 40], (i, v) => '${v.round()}%'),
          ]));
      await t.tapAt(_at(t, 0));
      await t.pump();
      expect(find.text('60 bpm'), findsOneWidget);
      expect(find.text('10%'), findsOneWidget);
      expect(t.getTopLeft(_cell('Heart rate (bpm)')).dx,
          lessThan(t.getTopLeft(_cell('Movement (% of time)')).dx));
    });

    testWidgets('"Not recorded" only appears when the window has gaps',
        (t) async {
      await _pump(t, _scrub(gaps: true));
      expect(find.text('Not recorded'), findsOneWidget);
      await _pump(t, _scrub(hr: const [60, 64, 66, 70], gaps: false));
      expect(find.text('Not recorded'), findsNothing);
    });

    testWidgets('"Not recorded" says Here on a hole, shading keys aside',
        (t) async {
      await _pump(
          t,
          _scrub(gaps: true, keys: [
            ChartKey.slots(
                'Heart rate (bpm)', _red, _hr, (i, v) => '${v.round()} bpm'),
            // Names a shaded stretch; "No" is not a recording.
            ChartKey('Asleep', _blue, (at) => 'No', latest: null, data: false),
          ]));
      await t.tapAt(_at(t, 2 / 3));
      await t.pump();
      expect(
          find.descendant(
              of: _value('Not recorded'), matching: find.text('Here')),
          findsOneWidget);
      await t.tapAt(_at(t, 0));
      await t.pump();
      expect(find.text('Here'), findsNothing);
    });

    testWidgets('a long label wraps in full, it is never clipped', (t) async {
      const label = 'Movement (% of time moving)';
      await _pump(
          t,
          _scrub(keys: [
            ChartKey.slots(
                'Heart rate (bpm)', _red, _hr, (i, v) => '${v.round()} bpm'),
            ChartKey.slots(label, _blue, const [10, 20, 30, 40],
                (i, v) => '${v.round()}%'),
          ]));
      final text = t.widget<Text>(find.text(label));
      expect(text.overflow, isNull);
      expect(text.maxLines, isNull);
    });

    testWidgets('the spoken value is the same text the row shows', (t) async {
      final handle = t.ensureSemantics();
      await _pump(t, _scrub());
      await t.tapAt(_at(t, 0));
      await t.pump();
      final v = t.getSemantics(find.byType(Scrubber)).value;
      expect(v, contains('07:00'));
      expect(v, contains('Heart rate (bpm)'));
      expect(v, contains('60 bpm'));
      handle.dispose();
    });
  });

  group('the row never changes height', () {
    for (final scale in [1.0, 2.0, 3.1]) {
      testWidgets('scrubbing a value, a hole and nothing at ${scale}x',
          (t) async {
        await _pump(
            t,
            _scrub(gaps: true, keys: [
              ChartKey.slots(
                  'Heart rate (bpm)', _red, _hr, (i, v) => '${v.round()} bpm'),
              ChartKey.slots('Movement (% of time)', _blue,
                  const [10, 20, null, 40], (i, v) => '${v.round()}%'),
            ]),
            scale: scale,
            h: 2200);
        final rest = t.getSize(find.byType(ChartKeyReadout));
        await t.tapAt(_at(t, 0));
        await t.pump();
        expect(t.getSize(find.byType(ChartKeyReadout)), rest);
        await t.tapAt(_at(t, 2 / 3));
        await t.pump();
        expect(t.getSize(find.byType(ChartKeyReadout)), rest);
        // No RenderFlex overflow or other exception was thrown meanwhile.
        expect(t.takeException(), isNull);
      });
    }
  });

  group('inside a ChartFrame the value sits under its own key', () {
    Widget frame({List<double?> hr = _hr, bool gaps = false}) => ChartFrame(
          title: 'Heart rate',
          unit: 'bpm',
          height: 100,
          xLabels: const ['07:00', '10:00'],
          legend: [('Heart rate (bpm)', _red), ('Movement (% of time)', _blue)],
          child: ChartScrub(
            label: 'Heart rate',
            gaps: gaps,
            time: (at) => _t(ChartScrub.slotAt(hr.length, at)),
            keys: [
              ChartKey.slots(
                  'Heart rate (bpm)', _red, hr, (i, v) => '${v.round()} bpm'),
              ChartKey.slots('Movement (% of time)', _blue,
                  const [10, 20, 30, 40], (i, v) => '${v.round()}%'),
            ],
            child:
                CustomPaint(size: Size.infinite, painter: LineChart(hr, _red)),
          ),
        );

    testWidgets('same column, same order, one label each', (t) async {
      await _pump(t, frame(), h: 420);
      await t.tapAt(t.getTopLeft(find.byType(ChartScrub)) + const Offset(2, 30));
      await t.pump();
      // The key is not drawn twice.
      expect(find.text('Heart rate (bpm)'), findsOneWidget);
      expect(find.text('Movement (% of time)'), findsOneWidget);
      for (final k in ['Heart rate (bpm)', 'Movement (% of time)']) {
        expect(t.getTopLeft(_value(k)).dx,
            moreOrLessEquals(t.getTopLeft(_swatch(k)).dx, epsilon: 0.5),
            reason: '$k value shares its swatch column');
        expect(t.getTopLeft(_value(k)).dy,
            greaterThan(t.getTopLeft(_swatch(k)).dy));
      }
      expect(t.getTopLeft(_cell('Heart rate (bpm)')).dx,
          lessThan(t.getTopLeft(_cell('Movement (% of time)')).dx));
      expect(find.text('60 bpm'), findsOneWidget);
      expect(find.text('10%'), findsOneWidget);
    });

    testWidgets('the row is under the x-axis labels, not over the plot',
        (t) async {
      await _pump(t, frame(), h: 420);
      expect(t.getTopLeft(find.text('07:00')).dy,
          lessThan(t.getTopLeft(_cell('Heart rate (bpm)')).dy));
    });

    testWidgets('a key with no series behind it stays a plain key', (t) async {
      await _pump(
          t,
          ChartFrame(
            title: 'Night',
            unit: 'min',
            legend: [('Asleep', _blue)],
            child: ChartScrub(
              label: 'Night',
              keys: [
                ChartKey.slots('Heart rate (bpm)', _red, _hr,
                    (i, v) => '${v.round()} bpm')
              ],
              child: CustomPaint(
                  size: Size.infinite, painter: LineChart(_hr, _red)),
            ),
          ),
          h: 420);
      expect(_cell('Asleep'), findsOneWidget);
      expect(_cell('Heart rate (bpm)'), findsOneWidget);
    });
  });

  group('hasChartGaps decides "Not recorded"', () {
    test('a hole between two readings is a gap', () {
      expect(
          hasChartGaps([
            const [1, null, 3]
          ]),
          isTrue);
    });
    test('a full series is not', () {
      expect(
          hasChartGaps([
            const [1, 2, 3]
          ]),
          isFalse);
    });
    test('non-finite counts as absent', () {
      expect(
          hasChartGaps([
            const [1, double.nan, 3]
          ]),
          isTrue);
      expect(
          hasChartGaps([
            const [1, double.infinity, 3]
          ]),
          isTrue);
    });
    test('nothing at all is no data, not a gap', () {
      expect(hasChartGaps([const <double?>[]]), isFalse);
      expect(
          hasChartGaps([
            const [null, null]
          ]),
          isFalse);
    });
    test('leading holes count: the band was off before it began', () {
      expect(
          hasChartGaps([
            const [null, null, 3, 4]
          ]),
          isTrue);
    });
    test('trailing holes are not a gap unless the window is finished', () {
      expect(
          hasChartGaps([
            const [1, 2, null, null]
          ]),
          isFalse);
      expect(
          hasChartGaps([
            const [1, 2, null, null]
          ], trailing: true),
          isTrue);
    });
    test('any series with a gap is enough', () {
      expect(
          hasChartGaps([
            const [1, 2, 3],
            const [1, null, 3]
          ]),
          isTrue);
    });
  });
}
