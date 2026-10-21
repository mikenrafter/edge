// Survey + screenshot harness for the Home rings card. Not a regression test:
// skipped unless RING_SURVEY=1. With it set:
//
//   RING_SURVEY=1 RING_VARIANT=<name> flutter test test/ring_caption_survey_test.dart
//
// writes /tmp/ring-survey-<name>.md (for each locale x width x scale: column or
// row layout, and the rings' height empty / loaded) and PNGs of the loaded
// card (en and es, 360 and 390 pt, x1.0) to
// ../edge.research/shots/ring-captions/<name>-<lang>-<w>-<state>.png.
// Every instant is injected; nothing reads the system clock.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/control_operations.dart'
    show ExpectedSleepSchedule;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/bundled_fonts.dart';

final _on = Platform.environment['RING_SURVEY'] == '1';
final _variant = Platform.environment['RING_VARIANT'] ?? 'x';
const _shots = '/home/mini/Documents/repos/edge.research/shots/ring-captions';

final _evening = DateTime(2026, 10, 8, 22, 0);
const _schedule = ExpectedSleepSchedule(onsetMinute: 1380, wakeMinute: 420);
const _stages = SleepStageMin(deep: 70, rem: 95, light: 277, awake: 30);
Metric _min(num v) =>
    Metric(value: v, unit: 'min', confidence: .8, tier: MetricTier.estimate);
const _rec = Metric(value: 82, confidence: .8, tier: MetricTier.high);
const _str = Metric(value: 9.0, confidence: .6, tier: MetricTier.estimate);

final _slept = HomeData(
    dayId: '2026-10-09',
    readiness: _rec,
    strain: _str,
    sleepMin: _min(442),
    sleepStages: _stages);
final _long = HomeData(
    dayId: '2026-10-08',
    readiness: _rec,
    strain: _str,
    sleepSchedule: _schedule,
    nextAlarm: DateTime(2026, 10, 9, 8, 30));
final _estimate = HomeData(
    dayId: '2026-10-08',
    readiness: _rec,
    strain: _str,
    sleepSchedule: _schedule);

Future<GlobalKey> _pump(WidgetTester t, double w, HomeData d, String lang,
    double scale, double dpr) async {
  t.view.devicePixelRatio = dpr;
  t.view.physicalSize = Size(w * dpr, 900 * dpr);
  addTearDown(t.view.reset);
  final key = GlobalKey();
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: Locale(lang),
    theme: buildTheme(Brightness.light),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!),
    home: Scaffold(
      body: SingleChildScrollView(
        child: RepaintBoundary(
          key: key,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: RingTrio(d: d, now: _evening),
          ),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
  return key;
}

Iterable<Element> _units(WidgetTester t) => find
    .descendant(
        of: find.byType(RingTrio),
        matching: find.byWidgetPredicate((w) =>
            w.runtimeType.toString() == '_RingColumn' ||
            w.runtimeType.toString() == '_RingRow'))
    .evaluate();

String _layout(WidgetTester t) =>
    _units(t).first.widget.runtimeType.toString() == '_RingRow' ? 'rows' : 'cols';


void main() {
  setUpAll(loadFonts);
  const langs = ['en', 'es', 'fr', 'de', 'ru', 'hi', 'zh'];
  final out = StringBuffer(
      '| locale | width | x1.0 | x1.15 | x1.3 |\n|---|---|---|---|---|\n');

  testWidgets('survey', (t) async {
    for (final lang in langs) {
      for (final w in [320.0, 360.0, 390.0, 430.0]) {
        final cells = <String>[];
        for (final s in [1.0, 1.15, 1.3]) {
          // Rings' own height per state, and whether the sleep caption is cut.
          double units() => [
                for (final u in _units(t)) t.getSize(find.byWidget(u.widget)).height
              ].fold(0.0, (a, b) => _layout(t) == 'rows' ? a + b : (a > b ? a : b));
          bool clipped() {
            final cap = find
                .descendant(
                    of: find.byWidget(_units(t).last.widget),
                    matching: find.byType(Text))
                .last;
            return t.renderObject<RenderParagraph>(cap).didExceedMaxLines;
          }

          await _pump(t, w, const HomeData(), lang, s, 1);
          final lay = _layout(t);
          final he = units();
          final hs = <double>[];
          var clip = false;
          var mismatch = false;
          for (final d in [_estimate, _long, _slept]) {
            await _pump(t, w, d, lang, s, 1);
            if (_layout(t) != lay) mismatch = true;
            hs.add(units());
            clip |= clipped();
          }
          final same = hs.every((h) => (h - he).abs() < .5);
          cells.add('$lay${mismatch ? " LAYOUT-DIFF" : ""}'
              ' ${he.round()}${same ? "=" : "!=${hs.map((h) => h.round()).join("/")}"}'
              '${clip ? " CLIP" : ""}');
        }
        out.writeln('| $lang | ${w.toInt()} | ${cells.join(' | ')} |');
      }
    }
    File('/tmp/ring-survey-$_variant.md').writeAsStringSync(out.toString());
  }, skip: !_on);

  testWidgets('shots', (t) async {
    Directory(_shots).createSync(recursive: true);
    for (final lang in ['en', 'es']) {
      for (final w in [360.0, 390.0]) {
        for (final st in {'slept': _slept, 'estimate': _estimate}.entries) {
          final key = await _pump(t, w, st.value, lang, 1.0, 3);
          final b = t.renderObject(find.byKey(key)) as RenderRepaintBoundary;
          await t.runAsync(() async {
            final img = await b.toImage(pixelRatio: 3);
            final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
            File('$_shots/$_variant-$lang-${w.toInt()}-${st.key}.png')
                .writeAsBytesSync(bytes!.buffer.asUint8List());
          });
        }
      }
    }
  }, skip: !_on);
}
