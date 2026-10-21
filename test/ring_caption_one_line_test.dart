// Home rings card: every ring's caption (the `sub` line under the value) is one
// line at 360 and 390 pt, text scale 1.0, real fonts, and a ring column is the
// same height loaded as on first launch. Today the loaded SLEEP caption
// ("94% of 8h 00m (default)", "on track for 5 cycles, 7h 30m · target 8h 00m
// (default)") wraps to two lines.
//
// Every instant is injected (`RingTrio.now`); nothing reads the system clock.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/control_operations.dart'
    show ExpectedSleepSchedule;
import 'package:openstrap_edge/ui2/grammar.dart' show Pressable;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/bundled_fonts.dart';

final _evening = DateTime(2026, 10, 8, 22, 0);
const _schedule = ExpectedSleepSchedule(onsetMinute: 1380, wakeMinute: 420);
const _stages = SleepStageMin(deep: 70, rem: 95, light: 277, awake: 30);

Metric _min(num v) =>
    Metric(value: v, unit: 'min', confidence: .8, tier: MetricTier.estimate);

const _rec = Metric(value: 82, confidence: .8, tier: MetricTier.high);
const _str = Metric(value: 9.0, confidence: .6, tier: MetricTier.estimate);

/// name -> loaded data. Each is a realistic Home state with all three rings.
final Map<String, HomeData> _loaded = {
  // A scored night with stages and no learned need: "92% of 8h 00m (default)".
  'slept, default target': HomeData(
      dayId: '2026-10-09',
      readiness: _rec,
      strain: _str,
      sleepMin: _min(442),
      sleepStages: _stages),
  // A scored night against a learned need: "96% of 7h 42m".
  'slept, learned need': HomeData(
      dayId: '2026-10-09',
      readiness: _rec,
      strain: _str,
      sleepMin: _min(442),
      sleepNeedMin: _min(462),
      sleepStages: _stages),
  // Evening, nothing slept yet, a saved schedule: the longest caption,
  // "on track for 5 cycles, 8h 00m · target 8h 00m (default)".
  'estimate, schedule, default target': HomeData(
      dayId: '2026-10-08',
      readiness: _rec,
      strain: _str,
      sleepSchedule: _schedule),
  // Same with a learned need and an armed alarm.
  'estimate, alarm, learned need': HomeData(
      dayId: '2026-10-08',
      readiness: _rec,
      strain: _str,
      sleepNeedMin: _min(462),
      sleepSchedule: _schedule,
      nextAlarm: DateTime(2026, 10, 9, 6, 45)),
};

Future<void> _pump(WidgetTester t, double width, HomeData d) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(width, 900);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: RingTrio(d: d, now: _evening),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

/// The caption Texts: the only `maxLines: 2` Text in a ring column.
List<Text> _captions(WidgetTester t) => [
      for (final e in find
          .descendant(of: find.byType(RingTrio), matching: find.byType(Text))
          .evaluate())
        if ((e.widget as Text).maxLines == 2) e.widget as Text
    ];

void main() {
  setUpAll(loadFonts);

  for (final w in [360.0, 390.0]) {
    for (final e in _loaded.entries) {
      testWidgets('${w.toInt()} pt, ${e.key}: every ring caption is one line',
          (t) async {
        await _pump(t, w, e.value);
        final caps = _captions(t);
        expect(caps.length, 3, reason: 'one caption per ring');
        final bad = <String>[];
        for (final c in caps) {
          final f = find.byWidget(c);
          final para = t.renderObject<RenderParagraph>(f);
          // Distinct line tops. (The paragraph's own height is padded to the
          // reserved two lines, so it cannot say.)
          final len = para.text.toPlainText().length;
          final lines = {
            for (final b in para.getBoxesForSelection(
                TextSelection(baseOffset: 0, extentOffset: len)))
              b.top.round()
          }.length;
          if (lines != 1 || para.didExceedMaxLines) {
            bad.add('"${c.data}" -> $lines line(s), '
                'exceededMaxLines=${para.didExceedMaxLines}');
          }
        }
        expect(bad, isEmpty, reason: 'wrapping captions:\n${bad.join('\n')}');
      });

      testWidgets(
          '${w.toInt()} pt, ${e.key}: ring columns are as tall as on first launch',
          (t) async {
        // The ring columns are the narrow Pressables (the help strip is as
        // wide as the card).
        List<double> heights() => [
              for (final e in find
                  .descendant(
                      of: find.byType(RingTrio), matching: find.byType(Pressable))
                  .evaluate())
                if (t.getSize(find.byWidget(e.widget)).width < 150)
                  t.getSize(find.byWidget(e.widget)).height
            ];
        await _pump(t, w, const HomeData());
        final empty = heights();
        await _pump(t, w, e.value);
        final loaded = heights();
        expect(empty.length, 3);
        expect(loaded, empty,
            reason: 'column heights loaded $loaded vs empty $empty');
      });
    }
  }
}
