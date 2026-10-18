// Sol r1 (feature/prv-diagnostics) P2 findings, red first.
//
//  P2-a  an EMPTY input must not persist `artifact_fraction` 1.0 ("100% of beats
//        are artifacts" beside zero beats): with nothing to divide by, the
//        diagnostic fraction is absent (null) on the batch day path, the batch
//        sleep path and the streaming path. Verdicts are unchanged.
//  P2-b  `1 - cleanFraction` counts CORRECTED beats too, and those stay in the
//        analysed series: the screen must not call the share "rejected". Every
//        locale says "classified as artifacts (corrected or dropped)", and the
//        abstention explanation says it too.
//  P2-c  a day from before v103 has a verdict but no diagnostics (and no sleep
//        pnn_pct): Export PRV log is still offered; the log says "not recorded".
//
// Fixed data; no real clock. Run with TZ=UTC.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/day_rr_state.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/prv_export.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/investigate.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/util/log_file.dart';

import '../support/incremental_day_fixture.dart';

Map<String, dynamic> _beats(Map<String, dynamic> screen) =>
    ((screen['diagnostics'] as Map)['beats'] as Map).cast<String, dynamic>();

Map<String, dynamic> _clinical(Map<String, dynamic> bundle) =>
    (bundle['clinical'] as Map).cast<String, dynamic>();

Map<String, dynamic> _diag({String? abstain, double artifact = 0.45}) => {
      'version': 1,
      'abstain': abstain,
      'beats': {
        'rr_raw': 1900,
        'nn_in': 1900,
        'nn_kept': 1900,
        'corrected': 700,
        'dropped': 155,
        'artifact_fraction': artifact,
      },
      'windows': null,
      'thresholds': {
        'min_beats': 500,
        'max_artifact': 0.3,
        'sd1sd2_flag': 0.7,
        'pnn_threshold_ms': 70.0,
        'pnn_flag_pct': 30.0,
        'window_minutes': 5.0,
        'min_window_beats': 40,
        'sustained_fraction': 0.5,
      },
    };

Future<String> _pump(WidgetTester t, Map<String, dynamic> heart,
    {PrvExportEnv? env}) async {
  t.view.physicalSize = const Size(390 * 3, 12000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Investigate(
      'hrv',
      prvExport: env,
      data: InvestigateData(day: '2026-10-07', heart: heart),
    ),
  ));
  await t.pumpAndSettle();
  return t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').join('\n');
}

void main() {
  group('P2-a: no beats, no artifact share', () {
    test('the streaming day state with no beats stores no fraction', () {
      final j = DayRrState().irregular24hDetailedHeavy().toJson();
      final b = _beats(j);
      expect(b['rr_raw'], 0, reason: 'the corrector saw zero beats: a measured 0');
      expect(b, contains('artifact_fraction'));
      expect(b['artifact_fraction'], isNull);
      expect((j['diagnostics'] as Map)['abstain'], 'too_few_beats');
      expect(j['value'], '—', reason: 'the verdict is unchanged: absent');
    });

    test('a day with no beats at all (24 h and sleep): both fractions absent',
        () {
      final input = incrementalDay(nightSeconds: 3600)
        ..['sleep_rr_ms'] = <double>[]
        ..['sleep_rr_ts_ms'] = <double>[]
        ..['day_rr_ms'] = <double>[]
        ..['day_rr_ts_ms'] = <double>[];
      final clin = _clinical(deriveDayBundle(copyDay(input)));
      final day = (clin['irregular_24h'] as Map).cast<String, dynamic>();
      final sleep = (clin['irregular'] as Map).cast<String, dynamic>();
      expect(_beats(day)['rr_raw'], 0);
      expect(_beats(day)['artifact_fraction'], isNull);
      expect(_beats(sleep)['rr_raw'], 0);
      expect(_beats(sleep)['artifact_fraction'], isNull);
      expect(day['value'], '—');
      expect(sleep['flag'], isNull);
    });

    test('a night with beats keeps its measured fraction', () {
      final clin = _clinical(deriveDayBundle(copyDay(incrementalDay())));
      final sleep = (clin['irregular'] as Map).cast<String, dynamic>();
      expect(_beats(sleep)['rr_raw'], greaterThan(0));
      expect(_beats(sleep)['artifact_fraction'], isA<num>());
    });

    testWidgets('and the screen shows no share row for it', (t) async {
      final d = _diag(abstain: 'too_few_beats');
      d['beats'] = <String, Object?>{
        'rr_raw': 0,
        'nn_in': 0,
        'nn_kept': 0,
        'corrected': 0,
        'dropped': 0,
        'artifact_fraction': null,
      };
      final text = await _pump(t, {
        'irregular_24h': {
          'value': '—',
          'confidence': 0.0,
          'tier': 'ESTIMATE',
          'inputs_used': ['rr_cleaned'],
          'diagnostics': d,
        },
      });
      expect(RegExp(r'100(\.0)? ?%').hasMatch(text), isFalse);
      expect(text.toLowerCase(), isNot(contains('share of beats')));
    });
  });

  group('P2-b: the share is of beats classified as artifacts, not "rejected"', () {
    const locales = ['en', 'de', 'es', 'fr', 'hi', 'zh'];
    // Per locale: what the new strings must say, and the old wording that must
    // be gone.
    const must = {
      'en': 'corrected or dropped',
      'de': 'korrigiert oder verworfen',
      'es': 'corregidos o descartados',
      'fr': 'corrigés ou écartés',
      'hi': 'सुधारी या हटाई गई',
      'zh': '已校正或已丢弃',
    };
    const gone = {
      'en': 'rejected',
      'de': 'bei der Bereinigung verworfenen',
      'es': 'rechazados',
      'fr': 'rejetés',
      'hi': 'अस्वीकृत',
      'zh': '剔除',
    };

    for (final loc in locales) {
      test('$loc: the share label and the abstention say corrected or dropped, '
          'and no longer say rejected', () {
        final arb = jsonDecode(File('lib/l10n/app_$loc.arb').readAsStringSync())
            as Map<String, dynamic>;
        for (final k in ['investigatePrvArtifactShare', 'investigatePrvWhyArtifact']) {
          final text = arb[k] as String;
          expect(text, contains(must[loc]!), reason: '$loc $k');
          expect(text, isNot(contains(gone[loc]!)), reason: '$loc $k');
        }
      });
    }

    testWidgets('en: the screen words the abstention and the share the same way',
        (t) async {
      final text = await _pump(t, {
        'irregular': {
          'sd1': null,
          'sd2': null,
          'flag': null,
          'confidence': 0.0,
          'diagnostics': _diag(abstain: 'artifact'),
        },
      });
      expect(text, contains('classified as artifacts'));
      expect(text.toLowerCase(), isNot(contains('rejected')));
      expect(text, contains('45.0 %'));
    });
  });

  group('P2-c: a day from before v103 can still export its verdict', () {
    const legacySleep = {
      'sd1': 30.0,
      'sd2': 60.0,
      'flag': true,
      'confidence': 0.7,
      'note': 'irregular-rhythm SCREEN (not a diagnosis)',
    };
    const legacyDay = {
      'value': {
        'sd1_ms': 41.2,
        'sd2_ms': 55.3,
        'sd1_sd2': 0.75,
        'pnn_pct': 33.1,
        'n_beats': 12100,
        'flag': false,
      },
      'confidence': 0.62,
      'tier': 'ESTIMATE',
      'inputs_used': ['rr_cleaned'],
    };
    final button = find.byKey(const ValueKey('prv-log-export'));

    testWidgets('a verdict without diagnostics shows the export button, and the '
        'log says not recorded', (t) async {
      final saved = <String>[];
      await _pump(
        t,
        {'irregular': legacySleep, 'irregular_24h': legacyDay},
        env: PrvExportEnv(
          appVersion: () async => '9.9.9',
          now: () => DateTime.utc(2026, 10, 8, 12, 30, 5),
          save: (n, text) async {
            saved.add(text);
            return const LogSaveOk();
          },
        ),
      );
      expect(button, findsOneWidget);
      await t.tap(button);
      await t.pumpAndSettle();
      expect(saved, hasLength(1));
      final log = saved.single;
      expect(log, contains('day: 2026-10-07'));
      expect(log, contains('artifact_fraction: not recorded'));
      expect(log, contains('rr_raw: not recorded'));
      expect(log, contains('pnn_pct: 33.1'), reason: 'what the day does hold');
    });

    testWidgets('a 24 h verdict alone is enough', (t) async {
      await _pump(t, {'irregular_24h': legacyDay});
      expect(button, findsOneWidget);
    });

    testWidgets('a sleep verdict alone is enough', (t) async {
      await _pump(t, {'irregular': legacySleep});
      expect(button, findsOneWidget);
    });

    testWidgets('no verdict and no diagnostics: nothing to export', (t) async {
      await _pump(t, {
        'irregular': {'sd1': null, 'sd2': null, 'flag': null, 'confidence': 0.0},
        'irregular_24h': {'value': '—', 'confidence': 0.0},
      });
      expect(button, findsNothing);
    });
  });
}
