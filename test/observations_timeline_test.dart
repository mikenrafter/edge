// CLAIM obs-timeline: explore dated findings without changing their wording or
// adding a duplicate latest-week summary. These are interaction/design checks, no pixels.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/findings_log.dart';
import 'package:openstrap_edge/ui2/why_row.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'support/skeleton_fixture.dart';

const events = [
  Finding(FindingKind.irregularRhythm, '2026-11-14'),
  Finding(FindingKind.lowReadiness, '2026-11-14', score: 22),
  Finding(FindingKind.rhrShift, '2026-11-05', risen: true),
];
void main() {
  testWidgets('day detail stays navigable without a latest-week summary', (
    t,
  ) async {
    skTallView(t);
    await t.pumpWidget(skHost(const FindingsLog(events, today: '2026-11-15')));
    expect(
      find.byKey(const ValueKey('observations-latest-week')),
      findsNothing,
    );
    expect(find.byType(ChartFrame), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-why:finding:irregularRhythm:2026-11-14')),
      findsOneWidget,
    );
    final l = lookupAppLocalizations(const Locale('en'));
    final row = t.widget<WhyRow>(find.byType(WhyRow).first);
    expect(
      row.body,
      findingDetail(l, events.first),
      reason: 'the pulse wording stays owned by findings.dart',
    );
    expect(row.fullText, isTrue);
    expect(
      row.title,
      contains('14 November'),
      reason: 'each historical row keeps its own date',
    );
    await t.tap(find.byTooltip('Earlier week'));
    await t.pump();
    expect(
      find.byKey(const ValueKey('home-why:finding:rhrShift:2026-11-05')),
      findsOneWidget,
    );
    await t.tap(find.byTooltip('Later week'));
    await t.pump();
    final plot = t.getRect(find.byType(ChartScrub));
    await t.dragFrom(
      Offset(plot.center.dx, plot.center.dy),
      Offset(plot.width * .47, 0),
    );
    await t.pump();
    expect(find.text('Nothing flagged on this day.'), findsOneWidget);
    expect(find.byType(WhyRow), findsNothing);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'types have distinct inks and focused counts describe the stacked events',
    (t) async {
      skTallView(t);
      await t.pumpWidget(
        skHost(const FindingsLog(events, today: '2026-11-15')),
      );
      expect(
        FindingKind.values.map(findingColor).toSet().length,
        FindingKind.values.length,
      );
      final readout = t.widget<ChartKeyReadout>(find.byType(ChartKeyReadout));
      expect(readout.cells.map((c) => c.value), ['2', '1', '1']);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );
  // CLAIM obs-axis: event counts have whole-number ticks, and dates belong
  // between the bars and the readout, never below its explanation.
  for (final count in [1, 3]) {
    testWidgets('count $count uses integer ticks and plot-adjacent dates', (
      t,
    ) async {
      skTallView(t);
      await t.pumpWidget(
        skHost(
          FindingsLog([
            for (var i = 0; i < count; i++)
              Finding(FindingKind.values[i], '2026-11-14'),
          ], today: '2026-11-15'),
        ),
      );
      final frame = t.widget<ChartFrame>(find.byType(ChartFrame));
      expect(
        frame.yAxis!.tickValues.reversed,
        count == 1 ? [0.0, 1.0] : [0.0, 1.0, 2.0, 3.0],
      );
      expect(
        t
            .getBottomLeft(
              find.byKey(const ValueKey('observation-day:2026-11-14')),
            )
            .dy,
        lessThanOrEqualTo(t.getTopLeft(find.byType(ChartKeyReadout)).dy),
      );
    });
  }
  testWidgets('empty history has a week graph and an honest empty day', (
    t,
  ) async {
    skTallView(t);
    await t.pumpWidget(skHost(const FindingsLog([], today: '2026-11-15')));
    expect(find.byType(ChartFrame), findsOneWidget);
    expect(find.text('Nothing flagged on this day.'), findsOneWidget);
    expect(
      t
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Earlier week',
            ),
          )
          .onPressed,
      isNull,
    );
  });
  test('week dates cross DST as calendar days', () {
    expect(observationWeek('2026-11-03', 0), [
      '2026-10-28',
      '2026-10-29',
      '2026-10-30',
      '2026-10-31',
      '2026-11-01',
      '2026-11-02',
      '2026-11-03',
    ]);
  });
}
