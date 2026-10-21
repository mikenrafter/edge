// Home rings card: every caption fits its reserved two lines at 360 and 390
// pt, text scale 1.0, real fonts, and a ring column stays the same height
// loaded as on first launch. No caption may be ellipsized.
//
// Every instant is injected (`RingTrio.now`); nothing reads the system clock.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/control_operations.dart'
    show ExpectedSleepSchedule;
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

Future<void> _pump(WidgetTester t, double width, HomeData d,
    {Locale locale = const Locale('en'), double scale = 1}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(width, 900);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    locale: locale,
    theme: buildTheme(Brightness.light),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!),
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

/// The narrow ring-column Pressables (the help strip is as wide as the card).
Iterable<Element> _columns(WidgetTester t) => find
    .descendant(of: find.byType(RingTrio), matching: find.byType(Pressable))
    .evaluate()
    .where((e) => t.getSize(find.byWidget(e.widget)).width < 150);

/// The caption of each ring column: the last Text in it.
List<Finder> _captions(WidgetTester t) => [
      for (final col in _columns(t))
        find
            .descendant(
                of: find.byWidget(col.widget), matching: find.byType(Text))
            .last
    ];

void main() {
  setUpAll(loadFonts);

  // locale, text scale, widths: the contract holds in each.
  final combos = <(String, double, List<double>)>[
    ('en', 1, [360, 390]),
    ('en', 1.3, [360, 390]),
    ('es', 1, [360, 390]),
    ('fr', 1, [360, 390]),
  ];
  for (final (lang, scale, widths) in combos) {
    for (final w in widths) {
      for (final e in _loaded.entries) {
        testWidgets(
            '$lang x$scale ${w.toInt()} pt, ${e.key}: sleep caption fits its two lines, whole',
            (t) async {
          await _pump(t, w, e.value, locale: Locale(lang), scale: scale);
          final caps = _captions(t);
          expect(caps.length, 3, reason: 'one caption per ring');
          final lineH = (F.cap.fontSize ?? 12) * (F.cap.height ?? 1.3) * scale;
          // A default-target estimate (estimate marker + cycles + duration +
          // default target) cannot be two lines of a ~91 pt column at 1.3x;
          // there it wraps whole onto extra lines rather than drop a part.
          final lines = scale > 1 && e.key == 'estimate, schedule, default target'
              ? (w < 375 ? 4 : 3)
              : 2;
          for (final f in caps) {
            final text = t.widget<Text>(f).data ?? '';
            expect(text.trim(), isNotEmpty, reason: 'empty caption');
            final box = t.renderObject<RenderParagraph>(f);
            expect(box.didExceedMaxLines, isFalse,
                reason: '"$text" is ellipsized/cut');
            expect(box.size.height, lessThanOrEqualTo(lines * lineH + 1),
                reason: '"$text" needs more than two lines');
          }
          // The sleep ring is the last column; its wording keeps its
          // qualifiers in whatever form fit.
          final sleep = t.widget<Text>(caps.last).data!;
          final isDefault = e.key.contains('default');
          final isEstimate = e.key.startsWith('estimate');
          final dflt = {'en': 'default', 'es': 'predet|por defecto', 'fr': 'défaut'}[lang]!;
          final wantDefault = RegExp(dflt, caseSensitive: false);
          expect(wantDefault.hasMatch(sleep), isDefault,
              reason: '"$sleep" default qualifier');
          if (isEstimate && lang == 'en') {
            expect(sleep.startsWith('on track') || sleep.startsWith('~'), isTrue,
                reason: '"$sleep" lost the estimate marker');
            expect(sleep, contains('cycles'));
          }
          if (!isEstimate) expect(sleep, matches(RegExp(r'\d+ ?%')));
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
}
