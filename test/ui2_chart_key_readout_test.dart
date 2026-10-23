// The scrubbed values live in a panel UNDER the chart, not in a floating
// tooltip a thumb would cover.
//
// ChartScrub keeps the cursor. The values go to a ChartKeyReadout, now the
// scrub panel (owner decision 2026-10-22): a fixed-size inset with the caption
// "LATEST · <time>" / "SELECTED · <time>", the first series' value big, and
// the next series as secondary stats (label over value). At rest the panel
// shows the latest point; an absent value is "—", never a 0.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
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

Finder _panel() => find.byKey(ChartKeyReadout.panelKey);
Finder _big() => find.descendant(
    of: find.byKey(ChartKeyReadout.valueKey), matching: find.byType(Text));
Finder _stat(String label) => find.byKey(ValueKey('chart-panel-stat:$label'));
Finder _statValue(String label) =>
    find.descendant(of: _stat(label), matching: find.byType(Text)).last;
String _caption(WidgetTester t) =>
    t.widget<Text>(find.byKey(ChartKeyReadout.captionKey)).data!;

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

    testWidgets('the panel has the series colour and the value; a second '
        'series is a stat with its label and value', (t) async {
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
      expect(_panel(), findsOneWidget);
      expect(t.widget<Text>(_big().first).data, '60 bpm');
      final box = (t.widget<Container>(_panel()).decoration as BoxDecoration);
      expect(box.border!.top.color.toARGB32() & 0xFFFFFF,
          _red.toARGB32() & 0xFFFFFF,
          reason: 'the panel wears the series colour while scrubbing');
      final cap = t.widget<Text>(find.byKey(ChartKeyReadout.captionKey));
      expect(cap.style!.color!.toARGB32() & 0xFFFFFF,
          _red.toARGB32() & 0xFFFFFF);
      expect(
          find.descendant(
              of: _stat('Movement (% of time)'),
              matching: find.text('MOVEMENT (% OF TIME)')),
          findsOneWidget,
          reason: 'the stat names its series');
      expect(t.widget<Text>(_statValue('Movement (% of time)')).data, '10%');
    });

    testWidgets('the time comes first in the panel', (t) async {
      await _pump(
          t,
          _scrub(keys: [
            ChartKey.slots(
                'Heart rate (bpm)', _red, _hr, (i, v) => '${v.round()} bpm'),
            ChartKey.slots('Movement (% of time)', _blue,
                const [10, 20, 30, 40], (i, v) => '${v.round()}%'),
          ]));
      await t.tapAt(_at(t, 1 / 3));
      await t.pump();
      expect(_caption(t), 'SELECTED · 08:00');
      expect(t.getTopLeft(find.byKey(ChartKeyReadout.captionKey)).dx,
          lessThan(t.getTopLeft(_stat('Movement (% of time)')).dx));
    });

    testWidgets('nothing scrubbed: the latest point and its time', (t) async {
      await _pump(t, _scrub());
      // Slot 3 (10:00, 70 bpm) is the last one with data.
      expect(_caption(t), 'LATEST · 10:00');
      expect(find.text('70 bpm'), findsOneWidget);
      await t.tapAt(_at(t, 0));
      await t.pump();
      expect(_caption(t), 'SELECTED · 07:00');
    });

    testWidgets('the latest skips trailing holes', (t) async {
      await _pump(t, _scrub(hr: const [60, 64, 66, null, null]));
      expect(find.text('66 bpm'), findsOneWidget);
      expect(_caption(t), 'LATEST · 09:00');
    });

    testWidgets('before any data there is never a number', (t) async {
      await _pump(t, _scrub(hr: const [null, null, null]));
      // NOTE: the panel draws nothing at all here (it used to read "—"); the
      // guarantee kept is that no number, least of all a 0, is invented.
      expect(find.text('0 bpm'), findsNothing);
      expect(find.textContaining(RegExp(r'\d+ bpm')), findsNothing);
    });

    testWidgets('a hole under the finger is "—", not 0, not a neighbour',
        (t) async {
      await _pump(t, _scrub(gaps: true));
      await t.tapAt(_at(t, 2 / 3));
      await t.pump();
      expect(t.widget<Text>(_big().first).data, '—');
      expect(find.text('64 bpm'), findsNothing);
      expect(find.text('70 bpm'), findsNothing);
      expect(find.text('0 bpm'), findsNothing);
      // The time of the finger is still said.
      expect(_caption(t), 'SELECTED · 09:00');
    });

    testWidgets('the cursor and the row track a held drag', (t) async {
      await _pump(t, _scrub());
      final g = await t.startGesture(_at(t, 0));
      await t.pump();
      expect(t.widget<Scrubber>(find.byType(Scrubber)).value, isNull);
      await t.pump(const Duration(milliseconds: 700));
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

    testWidgets('one entry per series, in order', (t) async {
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
      expect(t.getTopLeft(_big().first).dx,
          lessThan(t.getTopLeft(_stat('Movement (% of time)')).dx));
    });

    // The panel no longer DRAWS a "Not recorded" entry (it has no colour, so
    // the panel skips it); the readout model still says it, so these two guard
    // the model. See the report: the panel's own "—" is all a user sees now.
    testWidgets('"Not recorded" only appears when the window has gaps',
        (t) async {
      List<String> labels(bool gaps, List<double?> hr) => [
            for (final c in ChartScrub.resolve(
                    keys: [
                      ChartKey.slots(
                          'Heart rate (bpm)', _red, hr, (i, v) => '${v.round()} bpm')
                    ],
                    gaps: gaps,
                    at: 0)
                .cells)
              c.label
          ];
      expect(labels(true, _hr), contains(ChartKeyReadout.notRecorded));
      expect(labels(false, const [60, 64, 66, 70]),
          isNot(contains(ChartKeyReadout.notRecorded)));
    });

    testWidgets('"Not recorded" says Here on a hole, shading keys aside',
        (t) async {
      final keys = [
        ChartKey.slots(
            'Heart rate (bpm)', _red, _hr, (i, v) => '${v.round()} bpm'),
        // Names a shaded stretch; "No" is not a recording.
        ChartKey('Asleep', _blue, (at) => 'No', latest: null, data: false),
      ];
      String? gap(double at) => ChartScrub.resolve(keys: keys, gaps: true, at: at)
          .cells
          .singleWhere((c) => c.label == ChartKeyReadout.notRecorded)
          .value;
      expect(gap(2 / 3), ChartKeyReadout.here);
      expect(gap(0), isNull);
    });

    testWidgets('a long label is never clipped', (t) async {
      const label = 'Movement (% of time moving)';
      await _pump(
          t,
          _scrub(keys: [
            ChartKey.slots(
                'Heart rate (bpm)', _red, _hr, (i, v) => '${v.round()} bpm'),
            ChartKey.slots(label, _blue, const [10, 20, 30, 40],
                (i, v) => '${v.round()}%'),
          ]));
      final f = find.text(label.toUpperCase());
      expect(f, findsOneWidget);
      final para = t.renderObject<RenderParagraph>(f);
      expect(para.didExceedMaxLines, isFalse,
          reason: 'the whole label fits in the stat, none of it is ellipsised');
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

  group('the panel never changes size', () {
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
        final rest = t.getSize(_panel());
        await t.tapAt(_at(t, 0));
        await t.pump();
        expect(t.getSize(_panel()), rest);
        await t.tapAt(_at(t, 2 / 3));
        await t.pump();
        expect(t.getSize(_panel()), rest);
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

    testWidgets('same order, one label each', (t) async {
      await _pump(t, frame(), h: 520);
      await t.tapAt(t.getTopLeft(find.byType(ChartScrub)) + const Offset(2, 30));
      await t.pump();
      // The key is not drawn twice: the second series is named once, in its
      // stat; the first is the panel's own value.
      expect(find.text('MOVEMENT (% OF TIME)'), findsOneWidget);
      expect(find.text('Movement (% of time)'), findsNothing);
      expect(t.getTopLeft(_big().first).dx,
          lessThan(t.getTopLeft(_stat('Movement (% of time)')).dx));
      expect(find.text('60 bpm'), findsOneWidget);
      expect(find.text('10%'), findsOneWidget);
    });

    testWidgets('the panel is under the x-axis labels, not over the plot',
        (t) async {
      await _pump(t, frame(), h: 520);
      expect(t.getTopLeft(find.text('07:00')).dy,
          lessThan(t.getTopLeft(_panel()).dy));
    });

    testWidgets('a key with no series behind it never takes the panel\'s '
        'value', (t) async {
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
          h: 520);
      expect(find.text('70 bpm'), findsOneWidget,
          reason: 'the heart rate is what the panel reads');
      expect(t.widget<Text>(_big().first).data, '70 bpm');
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
