import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_chart.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/skeleton/guide_plot.dart';
import 'package:openstrap_edge/ui2/charts.dart' show SleepStage;
import '../support/pin_tz.dart';

// WHY: both routes must use one elapsed-time rule (spec §4.3).
// CLAIM(timeline-shared-zoom). Catches: editor-specific 50% zoom or 15m floor.
void main() {
  pinProcessTimeZone('America/Denver');
  TimelineController controller([int end = 86400]) =>
      TimelineController(homeStartSec: 0, homeEndSec: end);
  test('Z1 double tap is literally 70 percent around its instant', () {
    final c = controller();
    addTearDown(c.dispose);
    c.zoomAt(43200);
    expect(c.view.start, closeTo(12960, 1e-8));
    expect(c.view.end, closeTo(73440, 1e-8));
  });
  test('Z2 repeated zoom stops at thirty minutes', () {
    final c = controller();
    addTearDown(c.dispose);
    for (var i = 0; i < 30; i++) {
      c.zoomAt(43200);
    }
    expect(c.view.span, 1800);
  });
  test('Z3 short domain resets exactly', () {
    final c = controller(600);
    addTearDown(c.dispose);
    c.selectRange(100, 200);
    c.resetZoom();
    expect(c.view, const TimelineView(0, 600));
    expect(c.zoomed, isFalse);
  });
  test('Z4 selection cannot exceed domain and preserves floor', () {
    final c = controller();
    addTearDown(c.dispose);
    c.selectRange(-500, 100);
    expect(c.view, const TimelineView(0, 1800));
  });
  test('Z5 offscreen selection pans the same span', () {
    final c = controller();
    addTearDown(c.dispose);
    c.selectRange(3600, 7200);
    c.reveal(80000);
    expect(c.view, const TimelineView(78200, 81800));
    expect(c.scrub, 80000);
  });
  test('Z6 normal, DST, nap-only, long sleep and whole outlying entries', () {
    // Literal elapsed expectations: Denver spring is 23h; autumn is 25h.
    for (final day in ['2026-03-08', '2026-11-01']) {
      final expected = day == '2026-03-08' ? 82800 : 90000;
      expect(timelineHome(day).span, expected);
    }
    final normal = localDayStartSec('2026-10-06')!;
    expect(
      timelineHome(
        '2026-10-06',
        entries: [(start: normal + 14 * 3600, end: normal + 15 * 3600)],
      ),
      TimelineView(normal.toDouble(), (normal + 24 * 3600).toDouble()),
    );
    expect(
      timelineHome(
        '2026-10-06',
        main: (start: normal - 3600, end: normal + 7 * 3600),
      ).span,
      86400,
    );
    final base = localDayStartSec('2026-10-06')!;
    final home = timelineHome(
      '2026-10-06',
      main: (start: base + 23 * 3600, end: base + 50 * 3600),
      entries: [(start: base - 3600, end: base + 100)],
    );
    expect(
      home,
      TimelineView((base - 3600).toDouble(), (base + 50 * 3600).toDouble()),
    );
  });
  test('Z7 daytime main uses containing midnight day', () {
    final base = localDayStartSec('2026-10-06')!;
    expect(
      timelineHome(
        '2026-10-06',
        main: (
          start: base + 6 * 3600 + 39 * 60,
          end: base + 16 * 3600 + 15 * 60,
        ),
      ),
      TimelineView(base.toDouble(), localDayEndSec('2026-10-06')!.toDouble()),
    );
    expect(localDayNoonSec('2026-10-06'), base + 12 * 3600);
  });
  test('Z8 overnight home includes day-afternoon nap by membership', () {
    final base = localDayStartSec('2026-10-06')!;
    expect(
      timelineHome(
        '2026-10-06',
        main: (start: base - 3600, end: base + 7 * 3600),
        entries: [(start: base + 14 * 3600, end: base + 15 * 3600)],
      ),
      TimelineView(
        (base - 12 * 3600).toDouble(),
        (base + 15 * 3600).toDouble(),
      ),
    );
  });
  Future<void> mount(
    WidgetTester t,
    TimelineController c, {
    bool reduced = false,
  }) async {
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Scaffold(
            body: Column(
              children: [
                timelineChart(
                  controller: c,
                  graph: DayGraph(dayStart: 0, hr: List.filled(1440, 60)),
                  annotations: const [],
                  onAnnotationSelected: (_) {},
                ),
                TimelineZoomControls(controller: c),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('Z9 range glides for 1.5 to 2 seconds', (t) async {
    final c = controller();
    await mount(t, c);
    c.selectRange(3600, 7200);
    await t.pump();
    await t.pump(const Duration(milliseconds: 750));
    expect(c.view.start, greaterThan(0));
    expect(c.view.start, lessThan(3600));
    await t.pump(const Duration(seconds: 2));
    expect(c.view, const TimelineView(3600, 7200));
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('Z10 retarget starts at rendered range', (t) async {
    final c = controller();
    await mount(t, c);
    c.selectRange(3600, 7200);
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    final before = c.view;
    c.selectRange(10000, 20000);
    expect(c.view, before);
    await t.pump();
    await t.pump(const Duration(milliseconds: 1));
    expect((c.view.start - before.start).abs(), lessThan(1));
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('Z11 reduced motion applies the final range immediately', (
    t,
  ) async {
    final c = controller();
    await mount(t, c, reduced: true);
    c.selectRange(3600, 7200);
    expect(c.view, const TimelineView(3600, 7200));
    expect(c.animating, isFalse);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('Z12 released scrub persists and every movement notifies', (
    t,
  ) async {
    final c = controller();
    await mount(t, c);
    final chart = find.byKey(const ValueKey('shared-timeline-plot'));
    expect(chart, findsOneWidget);
    final point = t.getCenter(chart);
    await t.dragFrom(point, const Offset(25, 0));
    await t.pump();
    final at = c.scrub;
    expect(at, isNotNull);
    await t.pump(const Duration(seconds: 1));
    expect(c.scrub, at);
    var changes = 0;
    c.scrubChanges.addListener(() => changes++);
    c.setScrub(100);
    c.setScrub(101);
    expect(changes, 2);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('Z13 pure zoom does not rebuild scrub readout Text', (t) async {
    final c = controller();
    await mount(t, c);
    c.setScrub(100);
    await t.pump();
    final text = find
        .descendant(
          of: find.byKey(const ValueKey('timeline-readout')),
          matching: find.byType(Text),
        )
        .first;
    expect(text, findsOneWidget);
    final before = t.widget(text);
    c.zoomAt(43200);
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(identical(t.widget(text), before), isTrue);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  // Catches: a chart call site using its own 50% zoom instead of the controller.
  testWidgets('shared chart gesture uses exactly the controller zoom', (
    t,
  ) async {
    final c = controller();
    await mount(t, c);
    final chart = find.byKey(const ValueKey('shared-timeline-plot'));
    final rect = t.getRect(chart);
    final at = Offset(rect.left + 44 + (rect.width - 52) / 2, rect.center.dy);
    await t.tapAt(at);
    await t.pump(const Duration(milliseconds: 100));
    await t.tapAt(at);
    await t.pumpAndSettle();
    expect(c.view.span, closeTo(60480, 1e-8));
    expect(c.view.center, closeTo(43200, 1e-8));
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('Z14 replacing chart controller disposes both tickers', (
    t,
  ) async {
    final c = controller(), next = controller();
    await mount(t, c);
    c.selectRange(3600, 7200);
    c.reveal(20000);
    await t.pump();
    await mount(t, next);
    expect(c.animating, isFalse);
    c.dispose();
    await t.pumpWidget(const SizedBox());
    next.dispose();
    expect(t.takeException(), isNull);
  });
  // WHY: guide placeholders must classify real data (spec §2).
  // Catches: unclassified copied pilot painter; missing 48dp zoom target.
  testWidgets('G1 chart painter declares its guide role', (t) async {
    final wave = stageWave([
      SleepStage.deep,
      SleepStage.light,
      SleepStage.awake,
      SleepStage.deep,
      null,
      SleepStage.light,
    ]);
    expect(
      wave.map((run) => run.map((point) => point.depth).toList()).toList(),
      [
        [2.5, 2.5, 0.0, 3.0],
        [2.0],
      ],
    );
    final c = controller();
    await mount(t, c);
    final painters = t
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byKey(const ValueKey('shared-timeline-plot')),
            matching: find.byType(CustomPaint),
          ),
        )
        .map((w) => w.painter)
        .whereType<CustomPainter>();
    expect(painters.whereType<GuidePlot>().length, greaterThan(0));
    for (final p in painters) {
      expect(
        p is GuidePlot || p is GuideDecoration || p is GuidePlotOverlay,
        isTrue,
      );
    }
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  // WHY: a known sleep span is measured context even when its HR is absent.
  // CLAIM(timeline-whole-domain): readout and gap paint must tell the same truth.
  testWidgets('known sleep does not claim an unrecorded gap in the readout', (
    t,
  ) async {
    final c = controller();
    final graph = DayGraph(
      dayStart: 0,
      hr: List.filled(1440, null),
      rest: const [(0, 60, Colors.blue)],
    );
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: timelineChart(
            controller: c,
            graph: graph,
            annotations: const [],
            onAnnotationSelected: (_) {},
          ),
        ),
      ),
    );
    c.setScrub(1800);
    await t.pump();
    expect(find.text('Here'), findsNothing);
    c.setScrub(7200);
    await t.pump();
    expect(find.text('Here'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('G2 zoom has a real 48dp target and selected instruction', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    final c = controller();
    await mount(t, c);
    final button = find.byKey(const ValueKey('timeline-zoom'));
    expect(button, findsOneWidget);
    expect(t.getSize(button).height, greaterThanOrEqualTo(48));
    await t.tap(button);
    await t.pump();
    expect(c.selection, isNotNull);
    expect(
      t.getSemantics(button).getSemanticsData().value,
      'Choose range, then activate again',
    );
    semantics.dispose();
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });
}
