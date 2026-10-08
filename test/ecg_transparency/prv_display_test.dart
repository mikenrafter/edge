// Design 04 phase 1 (RED) - item 8 (R4): the PRV screen shows the evidence it
// ALREADY persists, and changes nothing it derives.
//
//   * Nerd stats (Investigate 'hrv') shows the 24 h SD1 / SD2 / ratio / pNN70 /
//     beats analysed (already there) AND the 24 h confidence, plus the sleep
//     screen's confidence and the sleep-window `coverage.clean_fraction` -
//     values read from the stored day bundle, nothing recomputed;
//   * a value that was not persisted shows no row (never a 0 / 0 %);
//   * the flag rows read flagged / not flagged / not screened - a screen that
//     did not run is "not screened", never "not flagged" and never a dash that
//     reads as one;
//   * (Phase 1 only) NO day_result payload change. The PRV diagnostics item
//     that followed (test/prv_diagnostics/) changed the payload on purpose:
//     kAlgoVersion 102 -> 103 (and 104 for the empty-input repin) and the analytics pin moved, so the version
//     test below now pins THAT state.
//
// Fed through InvestigateData exactly as the repository shapes it
// (lib/data/local_repository_impl.dart getDayHeart / getDayHrv).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion, kAnalyticsPin, kProtocolPin;
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/investigate.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Map<String, dynamic> _irr24({bool? flag = false, double? confidence = 0.62}) => {
  'value': {
    'sd1_ms': 41.2,
    'sd2_ms': 55.3,
    'sd1_sd2': 0.75,
    'pnn_pct': 33.1,
    'n_beats': 1234,
    'flag': flag,
  },
  'confidence': ?confidence,
  'tier': 'estimate',
  'inputs_used': ['rr_cleaned'],
};

Map<String, dynamic> _irrSleep({bool? flag = true, double confidence = 0.7}) => {
  'sd1': 30.0,
  'sd2': 60.0,
  'flag': flag,
  'confidence': confidence,
};

Future<String> _pump(
  WidgetTester t, {
  Map<String, dynamic> heart = const {},
  Map<String, dynamic> hrv = const {},
}) async {
  t.view.physicalSize = const Size(390 * 3, 9000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Investigate(
      'hrv',
      data: InvestigateData(day: '2026-10-07', heart: heart, hrv: hrv),
    ),
  ));
  await t.pumpAndSettle();
  return t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').join('\n');
}

void main() {
  group('already-persisted PRV evidence is on screen', () {
    testWidgets('24 h: SD1, SD2, ratio, pNN70, beats analysed, and now the '
        'confidence', (t) async {
      final text = await _pump(t, heart: {'irregular_24h': _irr24()});
      expect(text, contains('41.2'));
      expect(text, contains('55.3'));
      expect(text, contains('0.75'));
      expect(text, contains('33.1'));
      expect(text, contains('1,234'));
      expect(RegExp(r'confidence', caseSensitive: false).hasMatch(text), isTrue);
      expect(RegExp(r'(^|[^\d.])0\.62(?!\d)|(^|[^\d.])62(\.0)? ?%').hasMatch(text), isTrue,
          reason: 'the stored 24 h confidence, 0.62');
    });

    testWidgets('sleep window: its confidence and the clean fraction of the '
        'beats behind it', (t) async {
      final text = await _pump(
        t,
        heart: {'irregular': _irrSleep(confidence: 0.7)},
        hrv: {
          'coverage': {
            'rr_beats': 500,
            'nn_clean': 406,
            'clean_fraction': 0.8123,
            'sleep_seconds': 25000,
          },
        },
      );
      expect(RegExp(r'clean', caseSensitive: false).hasMatch(text), isTrue);
      expect(RegExp(r'81\.2 ?%|(^|[^\d.])0\.81(?!\d)|81 ?%').hasMatch(text), isTrue,
          reason: 'coverage.clean_fraction 0.8123');
      expect(RegExp(r'(^|[^\d.])0\.7(0)?(?!\d)|70(\.0)? ?%').hasMatch(text), isTrue,
          reason: 'the sleep screen\'s stored confidence 0.7');
    });

    testWidgets('nothing persisted, nothing invented: no 0 % clean fraction, '
        'no 0.00 confidence', (t) async {
      final text = await _pump(t, heart: {'irregular_24h': _irr24(confidence: null)});
      expect(RegExp(r'(^|\n)0(\.0+)? ?%($|\n)').hasMatch(text), isFalse);
      expect(RegExp(r'(^|\n)0\.00($|\n)').hasMatch(text), isFalse);
    });
  });

  group('the flag rows', () {
    testWidgets('flagged / not flagged', (t) async {
      await _pump(t, heart: {
        'irregular': _irrSleep(flag: true),
        'irregular_24h': _irr24(flag: false),
      });
      expect(find.text('flagged'), findsOneWidget);
      expect(find.text('not flagged'), findsOneWidget);
      expect(find.text('clear'), findsNothing);
      expect(find.text('raised'), findsNothing);
    });

    testWidgets('a screen that did not run says "not screened" on both rows',
        (t) async {
      await _pump(t, heart: {
        'irregular': _irrSleep(flag: null),
        'irregular_24h': _irr24(flag: null),
      });
      expect(find.text('not screened'), findsNWidgets(2));
      expect(find.text('not flagged'), findsNothing,
          reason: 'not screened is not nothing flagged');
    });
  });

  group('no derived output changes (R4)', () {
    test('kAlgoVersion and both sibling pins are exactly what the PRV '
        'diagnostics change set (v103) and its empty-input repin (v104)', () {
      expect(kAlgoVersion, 104);
      expect(kAnalyticsPin, '0fc57682b988c44cb5943c6e39a0746167388d46');
      expect(kProtocolPin, 'bc7d8d0df706e40a2546ffde4545263f09d0fecb');
    });

    test('the persisted irregular blocks keep their keys (the pipeline writes '
        'the same payload)', () {
      final p = File('lib/compute/onehz_pipeline.dart').readAsStringSync();
      for (final k in [
        "'sd1': irrSleep == null",
        "'flag': irrSleep?.flag",
        "'confidence': irregularSleep.metric.present",
        "'clean_fraction': _round(corrected.cleanFraction, 4)",
        "'irregular_24h': irregular24hJson",
      ]) {
        expect(p.contains(k), isTrue, reason: k);
      }
    });

    test('display only: the repository read seam passes the same blocks '
        'through', () {
      final r = File('lib/data/local_repository_impl.dart').readAsStringSync();
      expect(r.contains("'irregular_24h': _sub(b, 'clinical')?['irregular_24h']"), isTrue);
      expect(r.contains("'coverage': _sub(b, 'coverage')"), isTrue);
    });
  });
}
