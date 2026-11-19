// Why: loading and absent content must reserve only explicitly requested slots;
// sizing copy must never become a reading or an accessibility announcement.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/skeleton/async_section.dart';
import 'package:openstrap_edge/ui2/skeleton/guide_plot.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/theme.dart';

Widget host(Widget child, {double scale = 1, bool reduced = false, bool rtl = false}) => MaterialApp(
  themeAnimationDuration: Duration.zero,
  theme: buildTheme(Brightness.dark),
  home: MediaQuery(data: MediaQueryData(textScaler: TextScaler.linear(scale), disableAnimations: reduced),
    child: Directionality(textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(body: Align(alignment: Alignment.topLeft,
        child: SingleChildScrollView(child: SizedBox(width: 300, child: child)))))),
);

void main() {
  for (final scale in [1.0, 2.0]) {
    // Catches: ignoring subMinLines or painting reserved unit copy as real data.
    testWidgets('signal subtitle slot survives empty to loaded at $scale', (t) async {
      Widget card(String sub, String unit) => SignalCard(Icons.favorite, Colors.red,
        'Heart rate', '—', sub: sub, unit: unit, reserveUnit: 'bpm', subMinLines: 2);
      final semantics = t.ensureSemantics();
      await t.pumpWidget(host(card('', ''), scale: scale));
      final empty = t.getSize(find.byType(SignalCard));
      expect(find.bySemanticsLabel('bpm'), findsNothing);
      await t.pumpWidget(host(card('A short note', 'bpm'), scale: scale));
      expect(t.getSize(find.byType(SignalCard)), empty);
      expect(t.takeException(), isNull);
      semantics.dispose();
    });
    // Catches: collapsing an absent footnote, or fixing it to unscaled pixels.
    testWidgets('chart footnote slot survives empty to loaded at $scale', (t) async {
      Widget chart(String? note, int lines) => ChartFrame(title: 'Heart rate', unit: 'bpm',
        footnote: note, footnoteLines: lines, height: 80, child: const SizedBox());
      await t.pumpWidget(host(chart('', 2), scale: scale));
      final reserved = t.getSize(find.byType(ChartFrame));
      await t.pumpWidget(host(chart('A short explanation', 2), scale: scale));
      expect(t.getSize(find.byType(ChartFrame)), reserved);
      await t.pumpWidget(host(chart(null, 0), scale: scale));
      expect(t.getSize(find.byType(ChartFrame)).height, lessThan(reserved.height));
      expect(t.takeException(), isNull);
    });
  }
  // Catches: ellipsizing default subtitles or ignoring the caller's one-line cap.
  testWidgets('metric subtitles wrap by default and cap only on request', (t) async {
    const sub = 'This status sentence is deliberately long enough to wrap across several lines in a narrow metric row';
    Widget row(int? lines) => MetricRow(Icons.favorite, Colors.red, 'Heart rate', '—',
      sub: sub, subMaxLines: lines);
    await t.pumpWidget(host(row(null)));
    final natural = t.getSize(find.byType(MetricRow)).height;
    await t.pumpWidget(host(row(1)));
    expect(t.getSize(find.byType(MetricRow)).height, lessThan(natural));
    expect(t.widget<Text>(find.text(sub)).maxLines, 1);
  });
  // Catches: labels and units being substituted as unknown values while loading.
  testWidgets('pending grammar names its section and marks known text', (t) async {
    final semantics = t.ensureSemantics();
    await t.pumpWidget(host(const PendingContent(pending: true,
      child: SignalCard(Icons.favorite, Colors.red, 'Heart rate', '42', unit: 'bpm'))));
    expect(find.bySemanticsLabel('Loading, Heart rate'), findsOneWidget);
    expect(find.bySemanticsLabel('42'), findsNothing);
    expect(find.ancestor(of: find.text('Heart rate'), matching: find.byType(PendingStatic)), findsOneWidget);
    expect(find.ancestor(of: find.text('bpm'), matching: find.byType(PendingStatic)), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    semantics.dispose();
  });
  // Catches: rendering all chart families as the same wave after extraction.
  testWidgets('pending chart families reuse their matching skeleton shapes', (t) async {
    const kinds = [SkeletonKind.sine, SkeletonKind.columns, SkeletonKind.steps,
      SkeletonKind.ring, SkeletonKind.dots, SkeletonKind.band];
    for (var i = 0; i < PendingChartShape.values.length; i++) {
      await t.pumpWidget(host(SizedBox(height: 80,
        child: PendingPlot(shape: PendingChartShape.values[i]))));
      final painter = t.widget<CustomPaint>(find.byType(CustomPaint).last).painter!;
      expect(skeletonKindOfPlot(painter as GuidePlot), kinds[i]);
      expect(t.takeException(), isNull);
    }
  });
}
