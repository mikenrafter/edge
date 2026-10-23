// Shared laws for the "scrub panel on every chart" item (owner decision
// 2026-10-22, ui-feedback item 1; mock chart_panel_rest.png / _scrub.png).
// Not a test itself.
//
// PINNED CONTRACT the green phase must satisfy. Keys are ValueKey<String>:
//   chart-panel            the inset box: BoxDecoration(color: card2,
//                          borderRadius: R.rMd). At rest no visible border;
//                          while scrubbing a border in the series colour.
//                          ONE per ChartFrame (and per standalone ChartScrub
//                          row, e.g. the month grid), always present, fixed
//                          height: its rect never changes.
//   chart-panel-caption    a Text: "LATEST · <day>" at rest, "SELECTED · <day>"
//                          while scrubbing (any case). Series colour while
//                          scrubbing.
//   chart-panel-value      the big value + unit (one widget; its descendant
//                          Texts joined, whitespace removed, read "56bpm").
//                          "—" on a gap day.
//   chart-panel-stat:<id>  a secondary stat (e.g. 7-day avg, vs avg).
// The at-rest older-calculation strip (older-version-note:*) and the compact
// "*" (older-version-mark:*) live INSIDE chart-panel.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'older_version_fixtures.dart';

const panelKey = ValueKey('chart-panel');
const captionKey = ValueKey('chart-panel-caption');
const valueKey = ValueKey('chart-panel-value');

/// One chart under test. The dataset every rig serves: a value of `50 + back`
/// (back = days ago, 0 = today) on every day of its window, except
///   - a GAP at [gapBack] (no value that day),
///   - an OLDER-calculation (v104) value at [olderBack], and at 0 when
///     `olderLatest` is set.
class PanelRig {
  final String name;

  /// Opens the chart. Must leave it loaded and settled.
  final Future<void> Function(WidgetTester t,
      {double width, double scale, bool olderLatest}) open;

  /// Taps the plot on the day [back] days ago.
  final Future<void> Function(WidgetTester t, int back) scrubBack;

  /// Where the panel lives: the chart's frame (or its standalone scrub).
  final Finder scope;

  /// Colour of the series the panel speaks for.
  final Color Function(WidgetTester t) seriesColor;

  /// The value text (whitespace removed) for a day, null when the chart has no
  /// exact value to pin (the month grid's words).
  final String? Function(int back)? valueAt;

  /// Secondary stats the chart should carry ('7-day avg', 'vs avg'); 0 where
  /// the chart has none.
  final int minStats;

  const PanelRig(this.name,
      {required this.open,
      required this.scrubBack,
      required this.scope,
      required this.seriesColor,
      this.valueAt,
      this.minStats = 0});

  static const gapBack = 2;
  static const olderBack = 4;
  static const scrubbedBack = 3;
}

Finder panelOf(PanelRig r) =>
    find.descendant(of: r.scope.first, matching: find.byKey(panelKey));

String _plain(Text x) => x.data ?? x.textSpan?.toPlainText() ?? '';

String captionOf(WidgetTester t, Finder panel) {
  final f = find.descendant(of: panel, matching: find.byKey(captionKey));
  expect(f, findsOneWidget, reason: 'the panel has no caption');
  return _plain(t.widget<Text>(f));
}

String valueOf(WidgetTester t, Finder panel) {
  final f = find.descendant(of: panel, matching: find.byKey(valueKey));
  expect(f, findsOneWidget, reason: 'the panel has no value');
  final texts =
      t.widgetList<Text>(find.descendant(of: f, matching: find.byType(Text)));
  return [for (final x in texts) _plain(x)]
      .join()
      .replaceAll(RegExp(r'\s+'), '');
}

Finder statsIn(Finder panel) => find.descendant(
    of: panel,
    matching: find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('chart-panel-stat:')));

BoxDecoration decorationOf(WidgetTester t, Finder panel) {
  final w = t.widget(panel);
  if (w is Container) return w.decoration! as BoxDecoration;
  if (w is DecoratedBox) return w.decoration as BoxDecoration;
  fail('chart-panel must be a Container or DecoratedBox, got ${w.runtimeType}');
}

int rgb(Color c) => c.toARGB32() & 0xFFFFFF;

/// Whether [caption] names [back] days ago: the weekday and the day of the
/// month, or "today" / "yesterday" where the chart words it so.
bool namesDay(String caption, int back) {
  final c = caption.toLowerCase();
  final n = DateTime.now();
  final d = DateTime(n.year, n.month, n.day - back);
  const wd = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  if (back == 0 && c.contains('today')) return true;
  if (back == 1 && c.contains('yesterday')) return true;
  return c.contains(wd[d.weekday - 1]) &&
      RegExp('\\b${d.day}\\b').hasMatch(c);
}

Finder noteIn(Finder panel) => find.descendant(
    of: panel,
    matching: find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('older-version-note:')));

Finder markIn(Finder panel) => find.descendant(
    of: panel,
    matching: find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('older-version-mark:')));

/// The laws, once per chart.
void panelLaws(PanelRig r) {
  group('scrub panel: ${r.name}', () {
    testWidgets('at rest the panel exists: LATEST, its day, the value and '
        'unit, the secondary stats', (t) async {
      await r.open(t);
      final panel = panelOf(r);
      expect(panel, findsOneWidget, reason: 'no panel at rest');
      final cap = captionOf(t, panel);
      expect(cap.toLowerCase(), startsWith('latest'));
      expect(namesDay(cap, 0), isTrue, reason: 'caption "$cap" names no day');
      final v = valueOf(t, panel);
      expect(v, isNot('—'));
      final want = r.valueAt?.call(0);
      if (want != null) expect(v, want);
      expect(statsIn(panel), findsAtLeastNWidgets(r.minStats));
    });

    testWidgets('scrubbing: SELECTED, the scrubbed day, its value, a border '
        'in the series colour', (t) async {
      await r.open(t);
      final panel = panelOf(r);
      expect(panel, findsOneWidget, reason: 'no panel at rest');
      final rest = decorationOf(t, panel).border;
      expect(rest == null || rest.top.color.a == 0 || rest.top.width == 0,
          isTrue,
          reason: 'no visible border at rest');
      await r.scrubBack(t, PanelRig.scrubbedBack);
      expect(panel, findsOneWidget);
      final cap = captionOf(t, panel);
      expect(cap.toLowerCase(), startsWith('selected'));
      expect(namesDay(cap, PanelRig.scrubbedBack), isTrue,
          reason: 'caption "$cap" is not ${PanelRig.scrubbedBack} days back');
      final want = r.valueAt?.call(PanelRig.scrubbedBack);
      final v = valueOf(t, panel);
      expect(v, isNot('—'));
      if (want != null) expect(v, want);
      final colour = rgb(r.seriesColor(t));
      final b = decorationOf(t, panel).border;
      expect(b, isNotNull, reason: 'scrubbing draws a border');
      expect(b!.top.width, greaterThan(0));
      expect(rgb(b.top.color), colour);
      expect(b.top.color.a, greaterThan(0));
      final capText = t.widget<Text>(
          find.descendant(of: panel, matching: find.byKey(captionKey)));
      expect(rgb(capText.style!.color!), colour,
          reason: 'SELECTED is in the series colour');
    });

    testWidgets('a gap day reads "—" under SELECTED', (t) async {
      await r.open(t);
      final panel = panelOf(r);
      expect(panel, findsOneWidget, reason: 'no panel at rest');
      await r.scrubBack(t, PanelRig.gapBack);
      expect(captionOf(t, panel).toLowerCase(), startsWith('selected'));
      expect(namesDay(captionOf(t, panel), PanelRig.gapBack), isTrue);
      expect(valueOf(t, panel), startsWith('—'));
    });

    testWidgets('the panel rect is identical at rest, scrubbing, on a gap '
        'day and on an older day; the frame does not move', (t) async {
      await r.open(t);
      final panel = panelOf(r);
      expect(panel, findsOneWidget, reason: 'no panel at rest');
      final rect = t.getRect(panel);
      final frame = t.getRect(r.scope.first);
      for (final back in [
        PanelRig.scrubbedBack,
        PanelRig.gapBack,
        PanelRig.olderBack,
        0,
      ]) {
        await r.scrubBack(t, back);
        expect(panel, findsOneWidget);
        expect(t.getRect(panel), rect, reason: 'panel moved on day -$back');
        expect(t.getRect(r.scope.first), frame,
            reason: 'frame moved on day -$back');
      }
    });

    testWidgets('inset style: card2 fill, rMd radius, no shadow', (t) async {
      await r.open(t);
      final panel = panelOf(r);
      expect(panel, findsOneWidget, reason: 'no panel at rest');
      final p = P.of(t.element(panel));
      final d = decorationOf(t, panel);
      expect(d.color, p.card2);
      expect(d.borderRadius, R.rMd);
      expect(d.boxShadow, anyOf(isNull, isEmpty));
      expect(t.getRect(panel).left, greaterThanOrEqualTo(t.getRect(r.scope.first).left));
      expect(t.getRect(panel).right, lessThanOrEqualTo(t.getRect(r.scope.first).right));
    });

    testWidgets('latest older: the reason strip is inside the inset from the '
        'first frame and unchanged by a scrub', (t) async {
      await r.open(t, olderLatest: true);
      final panel = panelOf(r);
      expect(panel, findsOneWidget, reason: 'no panel at rest');
      expect(noteIn(panel), findsOneWidget,
          reason: 'the strip is inside the inset on load');
      expect(find.descendant(of: panel, matching: find.byIcon(LucideIcons.history)),
          findsOneWidget);
      final rect = t.getRect(panel);
      final at = t.getTopLeft(noteIn(panel));
      final size = t.getSize(noteIn(panel));
      await r.scrubBack(t, PanelRig.scrubbedBack); // a current day
      expect(noteIn(panel), findsOneWidget,
          reason: 'still the at-rest reason while scrubbing');
      expect(t.getTopLeft(noteIn(panel)), at);
      expect(t.getSize(noteIn(panel)), size);
      expect(t.getRect(panel), rect);
      // And the value scrubbed to does not carry a reason row of its own.
      expect(find.byKey(const ValueKey('older-version-note:selected')),
          findsNothing);
    });

    testWidgets('latest current: no strip; scrubbing onto an older day shows '
        'the compact * inside the inset and adds no row', (t) async {
      await r.open(t);
      final panel = panelOf(r);
      expect(panel, findsOneWidget, reason: 'no panel at rest');
      expect(noteIn(panel), findsNothing);
      final rect = t.getRect(panel);
      await r.scrubBack(t, PanelRig.olderBack);
      expect(markIn(panel), findsOneWidget,
          reason: 'the * rides with the scrubbed value, inside the panel');
      expect(noteIn(panel), findsNothing, reason: 'no reason row on scrub');
      expect(t.getRect(panel), rect);
    });

    for (final w in [360.0, 390.0]) {
      for (final s in [1.0, 1.3]) {
        testWidgets('no overflow at width $w, text scale $s', (t) async {
          await r.open(t, width: w, scale: s, olderLatest: true);
          final panel = panelOf(r);
          expect(panel, findsOneWidget, reason: 'no panel at rest');
          expect(t.takeException(), isNull);
          final box = t.getRect(r.scope.first);
          void inside() {
            final p = t.getRect(panel);
            expect(p.left, greaterThanOrEqualTo(box.left - .01));
            expect(p.right, lessThanOrEqualTo(box.right + .01));
          }

          inside();
          final rect = t.getRect(panel);
          await r.scrubBack(t, PanelRig.scrubbedBack);
          expect(t.takeException(), isNull);
          expect(panel, findsOneWidget);
          inside();
          expect(t.getRect(panel), rect);
          await r.scrubBack(t, PanelRig.gapBack);
          expect(t.takeException(), isNull);
          expect(t.getRect(panel), rect);
        });
      }
    }
  });
}

/// A stored point `back` days ago at local noon, valued `50 + back`.
Map<String, dynamic> panelPoint(int back, {bool older = false}) =>
    cp(back, 50 + back, older: older ? 104 : null);

/// [n] days ending today, with the rig's gap and older days.
List<Map<String, dynamic>> panelSeries(int n, {bool olderLatest = false}) => [
      for (var back = n - 1; back >= 0; back--)
        if (back != PanelRig.gapBack)
          panelPoint(back,
              older: back == PanelRig.olderBack || (olderLatest && back == 0)),
    ];
