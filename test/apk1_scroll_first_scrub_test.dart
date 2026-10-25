import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'backup/backup_support.dart';
import 'support/apk1_harness.dart';
import 'support/apk1_keys.dart';
import 'support/pin_tz.dart';

// Two production charts use the two relevant paths: Health's ChartScrub
// (including its frame's pointer listeners) and Sleep's direct Scrubber.
// Testing only Scrubber in isolation misses ChartScrub's outer Listeners.
const _charts = ['Health HRV', 'Sleep hypnogram'];

Widget _page(String chart) => chart == _charts.first
    ? HealthScreen(data: HealthData(daysWithData: 30, charts: {
        'hrv': [
          for (var d = 5; d <= 30; d++)
            ChartPoint(t: DateTime(2026, 9, d, 12).millisecondsSinceEpoch ~/ 1000,
                v: 60 + (d % 7).toDouble()),
          for (var d = 1; d <= 4; d++)
            ChartPoint(t: DateTime(2026, 10, d, 12).millisecondsSinceEpoch ~/ 1000,
                v: 60 + (d % 7).toDouble()),
        ],
      }))
    : SleepDetail(embedded: true, data: apk1Sleep());

Finder _plot(String chart) => find.byWidgetPredicate((w) => w is Scrubber &&
    w.label == (chart == _charts.first ? 'Heart rate variability' : 'Hypnogram'));

// The sleep panel is always there now; a selection is the panel scrubbed.
Finder _selection(String chart) => chart == _charts.first
    ? find.byWidgetPredicate((w) => w is ChartKeyReadout && w.scrubbed)
    : find.descendant(
        of: find.byKey(const ValueKey<String>(apk1SleepSelection)).first,
        matching: find.byWidgetPredicate((w) => w is ChartKeyReadout && w.scrubbed));

Future<ScrollPosition> _mount(WidgetTester t, String chart, double scale,
    Apk1Routes routes) async {
  await apk1Mount(t, page: _page(chart), routes: routes, scale: scale);
  await apk1Reveal(t, _plot(chart));
  expect(t.widget<Scrubber>(_plot(chart)).value, isNull);
  expect(_selection(chart), findsNothing);
  final scroll = t.state<ScrollableState>(find.ancestor(
      of: _plot(chart), matching: apk1VerticalScroll).first).position;
  expect(scroll.maxScrollExtent, greaterThan(100),
      reason: 'a real scrollable page, not a chart in an unscrollable box');
  expect(t.takeException(), isNull, reason: '360pt / $scale chart layout');
  return scroll;
}

// The panel's caption reads "SELECTED · <time>" once a chart is scrubbed.
final _selectedCaption = find.byWidgetPredicate((w) =>
    w.key == ChartKeyReadout.captionKey &&
    switch (w) {
      Text(:final data, :final textSpan) =>
        (data ?? textSpan?.toPlainText() ?? '').toUpperCase(),
      RichText(:final text) => text.toPlainText().toUpperCase(),
      _ => '',
    }.startsWith('SELECTED'));

void _selectedOnce(WidgetTester t, String chart) {
  final scrubber = t.widget<Scrubber>(_plot(chart));
  expect(scrubber.value, isNotNull);
  expect(_selection(chart), findsOneWidget,
      reason: 'scrubbing must produce a visible selected-instant readout');
  if (chart == _charts.first) {
    expect(find.descendant(of: _selection(chart), matching: _selectedCaption),
        findsOneWidget);
    expect(find.descendant(of: _selection(chart),
        matching: find.textContaining(' ms')), findsOneWidget);
  } else {
    expect(find.descendant(of: _selection(chart), matching: _selectedCaption),
        findsOneWidget);
    for (final unit in [' bpm', ' ms']) {
      expect(find.descendant(of: _selection(chart),
          matching: find.textContaining(unit)), findsNothing,
          reason: 'a selected stage must not fabricate absent overnight HR/HRV');
    }
  }
  final spoken = scrubber.describe(scrubber.value!);
  expect(spoken, isNotEmpty);
  expect(apk1Spoken(t).join('\n').split(spoken).length - 1, 1,
      reason: 'the selection status is voiced once across slider and readout');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  pinProcessTimeZone();
  late BackupEnv env;
  setUpAll(() async => env = await apk1Environment('apk1_scrub.db'));
  tearDownAll(() => env.dispose());
  setUp(apk1ClearPrefs);

  for (final chart in _charts) {
    for (final scale in [1.0, 3.1]) {
      apk1Test('$chart mostly vertical chart drag scrolls without selecting at $scale', (t) async {
        final routes = Apk1Routes();
        final scroll = await _mount(t, chart, scale, routes);
        final before = scroll.pixels;
        final dy = scroll.extentAfter > 150 ? -130.0 : 130.0;
        expect(dy < 0 ? scroll.extentAfter : scroll.extentBefore, greaterThan(100),
            reason: 'the page has room to scroll in the tested direction');
        await t.timedDrag(_plot(chart), Offset(12, dy),
            const Duration(milliseconds: 350));
        await t.pumpAndSettle();
        expect((scroll.pixels - before).abs(), greaterThan(40),
            reason: 'a vertical drag beginning on the chart belongs to the page');
        // Reveal without touching the chart, because the drag can carry the
        // plot offscreen and dispose/rebuild a lazy list item.
        await apk1Reveal(t, _plot(chart));
        expect(t.widget<Scrubber>(_plot(chart)).value, isNull,
            reason: 'neither pointer-down nor vertical pointer-move may scrub');
        expect(_selection(chart), findsNothing);
        expect(routes.pushes, 1, reason: 'dragging a tappable chart must not open its parent card');
        expect(t.takeException(), isNull);
      });

      apk1Test('$chart first move of 24 horizontal and 60 vertical scrolls without selecting at $scale', (t) async {
        final routes = Apk1Routes();
        final scroll = await _mount(t, chart, scale, routes);
        final before = scroll.pixels;
        final dy = scroll.extentAfter > 150 ? -60.0 : 60.0;
        expect(dy < 0 ? scroll.extentAfter : scroll.extentBefore, greaterThan(100));
        final g = await t.startGesture(t.getCenter(_plot(chart)));
        // One event crosses BOTH axis slops. Splitting it into small moves
        // would let the vertical recognizer win before horizontal slop.
        await g.moveBy(Offset(24, dy));
        await t.pump();
        expect(t.widget<Scrubber>(_plot(chart)).value, isNull);
        expect(_selection(chart), findsNothing);
        // Continue the scroll after its recognizer has accepted the gesture.
        await g.moveBy(Offset(0, dy));
        await g.up();
        await t.pumpAndSettle();
        expect((scroll.pixels - before).abs(), greaterThan(40));
        await apk1Reveal(t, _plot(chart));
        expect(t.widget<Scrubber>(_plot(chart)).value, isNull);
        expect(_selection(chart), findsNothing);
        expect(routes.pushes, 1);
        expect(t.takeException(), isNull);
      });

      apk1Test('$chart waits for drag intent then selects horizontally without scrolling at $scale', (t) async {
        final routes = Apk1Routes();
        final scroll = await _mount(t, chart, scale, routes);
        final before = scroll.pixels;
        final pending = await t.startGesture(t.getCenter(_plot(chart)));
        await t.pump();
        expect(t.widget<Scrubber>(_plot(chart)).value, isNull,
            reason: 'an unresolved pointer-down must not flash a scrub during a page scroll');
        expect(_selection(chart), findsNothing);
        await pending.up();
        await t.pump();
        // A few points of vertical noise must not turn deliberate horizontal
        // scrubbing into page scroll. Endpoints stay within the narrow plot.
        await t.drag(_plot(chart), const Offset(60, 5));
        await t.pumpAndSettle();
        expect(scroll.pixels, closeTo(before, 1));
        _selectedOnce(t, chart);
        expect(routes.pushes, 1);
        expect(t.takeException(), isNull, reason: 'the selected readout fits at $scale');
      });

      apk1Test('$chart long press then vertical drag selects without scrolling at $scale', (t) async {
        final routes = Apk1Routes();
        final scroll = await _mount(t, chart, scale, routes);
        final before = scroll.pixels;
        final g = await t.startGesture(t.getCenter(_plot(chart)));
        await t.pump(const Duration(milliseconds: 700));
        _selectedOnce(t, chart);
        final startValue = t.widget<Scrubber>(_plot(chart)).value!;
        await g.moveBy(const Offset(-30, 90));
        await t.pump();
        expect(scroll.pixels, closeTo(before, 1),
            reason: 'a recognized long press owns subsequent vertical movement');
        expect(t.widget<Scrubber>(_plot(chart)).value, lessThan(startValue),
            reason: 'the held selection follows horizontal position too');
        _selectedOnce(t, chart);
        await g.up();
        await t.pumpAndSettle();
        expect(scroll.pixels, closeTo(before, 1));
        expect(routes.pushes, 1);
        expect(t.takeException(), isNull);
      });
    }
  }
}
