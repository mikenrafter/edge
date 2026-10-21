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
import 'package:openstrap_edge/state/locale_controller.dart';
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
  // hm() reads the presentation locale, not MaterialApp.locale: bind it too,
  // so durations are measured in the fixture's own format.
  final lc = LocaleController.seed(locale.languageCode)..useForPresentation();
  addTearDown(lc.dispose);
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

/// The ring columns (or rows, in the big-text layout), one per ring.
Iterable<Element> _units(WidgetTester t) => find
    .descendant(
        of: find.byType(RingTrio),
        matching: find.byWidgetPredicate((w) =>
            w.runtimeType.toString() == '_RingColumn' ||
            w.runtimeType.toString() == '_RingRow'))
    .evaluate();

bool _rows(WidgetTester t) =>
    _units(t).first.widget.runtimeType.toString() == '_RingRow';

/// The caption of each ring: the last Text in its column / row.
List<Finder> _captions(WidgetTester t) => [
      for (final u in _units(t))
        find
            .descendant(of: find.byWidget(u.widget), matching: find.byType(Text))
            .last
    ];

/// The rings' own height (the help strip below them is a separate slot).
double _trioHeight(WidgetTester t) => [
      for (final u in _units(t)) t.getSize(find.byWidget(u.widget)).height
    ].fold(0.0, (a, b) => a + b);

void main() {
  setUpAll(loadFonts);

  // locale, text scale, widths: the contract holds in each.
  final combos = <(String, double, List<double>)>[
    ('en', 1, [360, 390]),
    ('en', 1.3, [360, 390]),
    ('en', 1.15, [360, 390]),
    ('es', 1.15, [360, 390]),
    ('fr', 1.15, [360, 390]),
    ('de', 1, [360, 390]),
    ('ru', 1, [360, 390]),
    ('hi', 1, [360, 390]),
    ('es', 1, [360, 390]),
    ('fr', 1, [360, 390]),
    // The centred three-column layout is only chosen where the worst-case
    // caption fits it: wide viewports, and zh (short wording).
    ('en', 1, [600]),
    ('zh', 1, [360]),
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
          // Columns hold two lines; the row layout has no line cap.
          final rows = _rows(t);
          for (final f in caps) {
            final text = t.widget<Text>(f).data ?? '';
            expect(text.trim(), isNotEmpty, reason: 'empty caption');
            final box = t.renderObject<RenderParagraph>(f);
            expect(box.didExceedMaxLines, isFalse,
                reason: '"$text" is ellipsized/cut');
            if (!rows) {
              expect(box.size.height, lessThanOrEqualTo(3 * lineH + 1),
                  reason: '"$text" needs more than three lines');
            }
          }
          // The sleep ring is the last column; its wording keeps its
          // qualifiers in whatever form fit.
          final sleep = t.widget<Text>(caps.last).data!;
          final isDefault = e.key.contains('default');
          final isEstimate = e.key.startsWith('estimate');
          final dflt = {
            'en': 'default',
            'es': 'predet|por defecto',
            'fr': 'défaut',
            'zh': '默认',
            'de': 'Standard',
            'ru': 'умолч',
            'hi': 'डिफ़ॉल्ट'
          }[lang]!;
          final wantDefault = RegExp(dflt, caseSensitive: false);
          expect(wantDefault.hasMatch(sleep), isDefault,
              reason: '"$sleep" default qualifier');
          if (isEstimate && isDefault) {
            // The default qualifier names the TARGET (or goal), in every form.
            expect(
                RegExp('target|goal|objetivo|meta|objectif|cible|目标|Ziel|цель|लक्ष्य',
                        caseSensitive: false)
                    .hasMatch(sleep),
                isTrue,
                reason: '"$sleep" does not name the default target');
          }
          if (isEstimate && lang == 'en') {
            expect(sleep.startsWith('on track') || sleep.startsWith('~'), isTrue,
                reason: '"$sleep" lost the estimate marker');
            expect(sleep, contains('cycles'));
          }
          if (!isEstimate) expect(sleep, matches(RegExp(r'\d+ ?%')));
        });

        testWidgets(
            '$lang x$scale ${w.toInt()} pt, ${e.key}: same layout and height as first launch',
            (t) async {
          await _pump(t, w, const HomeData(),
              locale: Locale(lang), scale: scale);
          final emptyRows = _rows(t);
          final empty = _trioHeight(t);
          await _pump(t, w, e.value, locale: Locale(lang), scale: scale);
          expect(_rows(t), emptyRows, reason: 'layout depends on the data');
          expect(_trioHeight(t), empty,
              reason: 'card height loaded vs empty (rows: $emptyRows)');
        });
    }
  }
  }

  testWidgets('en x1.4 360 pt: the stacked row layout, empty and loaded, equal height',
      (t) async {
    await _pump(t, 360, const HomeData(), scale: 1.4);
    expect(_rows(t), isTrue, reason: 'bigText uses rows');
    final empty = _trioHeight(t);
    await _pump(t, 360, _loaded['estimate, schedule, default target']!,
        scale: 1.4);
    expect(_rows(t), isTrue);
    expect(_trioHeight(t), empty);
    final cap = t.widget<Text>(_captions(t).last).data!;
    expect(cap, contains('default'));
    expect(cap, startsWith('on track'));
  });

  // 320 pt at x1.3 is where the shortest wordings need the most room (and the
  // ru numeral wraps to three lines): what the rings reserve must not depend
  // on the day's data.
  for (final lang in ['es', 'de', 'ru']) {
    testWidgets('$lang x1.3 320 pt: rings are as tall loaded as empty',
        (t) async {
      await _pump(t, 320, const HomeData(),
          locale: Locale(lang), scale: 1.3);
      final empty = _trioHeight(t);
      expect(_rows(t), isFalse);
      for (final e in _loaded.entries) {
        await _pump(t, 320, e.value, locale: Locale(lang), scale: 1.3);
        expect(_rows(t), isFalse);
        expect(_trioHeight(t), empty, reason: '$lang ${e.key}: loaded vs empty');
      }
    });
  }

  // The big-text row layout (left-aligned, no line cap): a scored numeral can
  // wrap where the empty dash does not, so the slot is reserved there too.
  for (final lang in ['ru', 'en']) {
    for (final scale in [1.4, 2.0, 3.0]) {
      testWidgets('$lang x$scale 320 pt: row layout, rings as tall loaded as empty',
          (t) async {
        await _pump(t, 320, const HomeData(), locale: Locale(lang), scale: scale);
        expect(_rows(t), isTrue);
        final empty = _trioHeight(t);
        for (final e in _loaded.entries) {
          await _pump(t, 320, e.value, locale: Locale(lang), scale: scale);
          expect(_rows(t), isTrue);
          expect(_trioHeight(t), empty,
              reason: '$lang x$scale ${e.key}: loaded vs empty');
        }
      });
    }
  }
}
