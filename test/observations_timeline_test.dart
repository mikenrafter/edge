// CLAIM obs-timeline: explore dated findings without changing their wording or
// losing the latest-week summary. These are interaction/design checks, no pixels.
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
  testWidgets('latest summary stays above the graph while earlier weeks change focus', (t) async {
    skTallView(t);
    await t.pumpWidget(skHost(const FindingsLog(events, today: '2026-11-15')));
    final summary = find.byKey(const ValueKey('observations-latest-week'));
    expect(find.byType(ChartFrame), findsOneWidget);
    expect(t.getTopLeft(summary).dy, lessThan(t.getTopLeft(find.byType(ChartFrame)).dy));
    final original = t.widgetList<Text>(find.descendant(of: summary, matching: find.byType(Text))).map((w) => w.data).toList();
    expect(find.byKey(const ValueKey('home-why:finding:irregularRhythm:2026-11-14')), findsOneWidget);
    final l = lookupAppLocalizations(const Locale('en'));
    final row = t.widget<WhyRow>(find.byType(WhyRow).first);
    expect(row.body, findingDetail(l, events.first), reason: 'the pulse wording stays owned by findings.dart');
    expect(row.fullText, isTrue);
    await t.tap(find.byTooltip('Earlier week')); await t.pump();
    expect(find.byKey(const ValueKey('home-why:finding:rhrShift:2026-11-05')), findsOneWidget);
    expect(t.widgetList<Text>(find.descendant(of: summary, matching: find.byType(Text))).map((w) => w.data), original);
    await t.tap(find.byTooltip('Later week')); await t.pump();
    await t.tap(find.byKey(const ValueKey('observation-day:2026-11-15'))); await t.pump();
    expect(find.text('Nothing flagged on this day.'), findsOneWidget);
    expect(find.byType(WhyRow), findsNothing);
    expect(t.takeException(), isNull);
  });
  testWidgets('types have distinct inks and focused counts describe the stacked events', (t) async {
    skTallView(t);
    await t.pumpWidget(skHost(const FindingsLog(events, today: '2026-11-15')));
    expect(FindingKind.values.map(findingColor).toSet().length, FindingKind.values.length);
    final readout = t.widget<ChartKeyReadout>(find.byType(ChartKeyReadout));
    expect(readout.cells.map((c) => c.value), ['1', '1', '0']);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
  testWidgets('empty history has a week graph and an honest empty day', (t) async {
    skTallView(t);
    await t.pumpWidget(skHost(const FindingsLog([], today: '2026-11-15')));
    expect(find.byType(ChartFrame), findsOneWidget);
    expect(find.text('Nothing flagged this week.'), findsOneWidget);
    expect(t.widget<IconButton>(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Earlier week')).onPressed, isNull);
  });
  test('week dates cross DST as calendar days', () {
    expect(observationWeek('2026-11-03', 0), ['2026-10-28','2026-10-29','2026-10-30','2026-10-31','2026-11-01','2026-11-02','2026-11-03']);
  });
}
