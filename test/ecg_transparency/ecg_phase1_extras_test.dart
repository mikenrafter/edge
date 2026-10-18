// Design 04 phase 1: small behaviours the other files do not pin.
//   * the screener page states the supported heart-rate ranges as the app's own
//     reading of the band's codes (R5), in the reader's language;
//   * a finding's words (notification text, composed with no BuildContext) come
//     from the ARBs in the language the app is showing (LocaleController
//     .currentStrings: override first, else the OS language, else English);
//   * every saved attempt can be opened from the capture screen, and a result
//     that is not a rhythm offers another reading.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/ecg/ecg_controller.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_outcome.dart';
import 'package:openstrap_edge/ecg/ecg_result.dart' show EcgMetric;
import 'package:openstrap_edge/ecg/ecg_waveform_buffer.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/screens/ecg.dart';
import 'package:openstrap_edge/ui2/screens/ecg_screener.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(WidgetTester t, Widget home, {Locale? locale}) async {
  t.view.physicalSize = const Size(1170, 12000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
  await t.pump();
}

String _allText(WidgetTester t) =>
    t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').join('\n');

Widget _body(EcgCaptureState s) => Scaffold(
  body: EcgCaptureBody(
    state: s,
    wrist: EcgWrist.right,
    phase: 0.25,
    live: EcgWaveformBuffer(capacity: 100),
    scheduler: EcgPreviewScheduler(),
    onRetry: () {},
    onTakeAnother: () {},
    onDone: () {},
    onView: () {},
  ),
);

const _noisy = EcgOutcome(
  kind: EcgOutcomeKind.notReadable,
  reasons: [EcgReason(EcgReasonId.significantNoise)],
  resultCode: 1,
  avgHr: 77,
  mask: 2,
);

void main() {
  group('the screener page states the supported ranges', () {
    testWidgets('English: the ranges and "not from a validation of this '
        'device"', (t) async {
      await _pump(t, const EcgScreenerScreen(), locale: const Locale('en'));
      final text = _allText(t);
      expect(text, contains('51–99 bpm'));
      expect(text, contains('151–200 bpm'));
      expect(text, contains('not from a validation of this device'));
      expect(text, contains('A wrist band records a single lead.'));
    });

    testWidgets('German: the same numbers, in German', (t) async {
      await _pump(t, const EcgScreenerScreen(), locale: const Locale('de'));
      final text = _allText(t);
      expect(text, contains('51–99 bpm'));
      expect(text, contains('Validierung dieses Geräts'));
      expect(text, isNot(contains('validation of this device')));
    });
  });

  group('words composed without a BuildContext', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('no override: the OS language, which is English under test', () async {
      final l = await LocaleController.currentStrings();
      expect(
        findingTitle(l, const Finding(FindingKind.irregularRhythm, 'd')),
        'Irregular pulse pattern flagged',
      );
    });

    test('the wearer\'s language override wins', () async {
      SharedPreferences.setMockInitialValues({'locale_override': 'de'});
      final l = await LocaleController.currentStrings();
      expect(
        findingTitle(l, const Finding(FindingKind.irregularRhythm, 'd')),
        'Unregelmäßiges Pulsmuster markiert',
      );
    });

    test('no override: the whole preferred-language list, not just the first '
        'entry - [pt-BR, es] reads Spanish (the app shows Spanish)', () async {
      final l = await LocaleController.currentStrings(
        osLocales: const [Locale('pt', 'BR'), Locale('es')],
      );
      expect(l.localeName, 'es');
      // The UI resolver is the same function: the two cannot disagree.
      expect(
        resolveAppLocale(
          const [Locale('pt', 'BR'), Locale('es')],
          AppLocalizations.supportedLocales,
        ),
        const Locale('es'),
      );
      expect(
        resolveAppLocale(const [Locale('pt')], AppLocalizations.supportedLocales),
        const Locale('en'),
        reason: 'nothing matches: English, not the alphabetically first arb',
      );
    });

    test('the app\'s MaterialApp resolves through the same function', () {
      final app = File('lib/app.dart').readAsStringSync();
      expect(app.contains('localeListResolutionCallback: resolveAppLocale'), isTrue);
    });

    test('an override the app no longer ships falls back, never throws',
        () async {
      SharedPreferences.setMockInitialValues({'locale_override': 'xx'});
      final l = await LocaleController.currentStrings();
      expect(
        findingTitle(l, const Finding(FindingKind.illness, 'd')),
        'Possible illness onset',
      );
    });
  });

  group('the capture result for an attempt', () {
    testWidgets('unreadable: the saved attempt can be viewed, and another '
        'taken', (t) async {
      await _pump(
        t,
        _body(const EcgCaptureState(
          phase: EcgCapturePhase.unreadable,
          readingId: 'att',
          unreadableMask: 2,
          outcome: _noisy,
        )),
      );
      expect(find.text('View reading'), findsOneWidget);
      expect(find.text('Take another'), findsOneWidget);
    });

    testWidgets('unreadable with nothing saved offers no view', (t) async {
      await _pump(
        t,
        _body(const EcgCaptureState(
          phase: EcgCapturePhase.unreadable,
          unreadableMask: 2,
        )),
      );
      expect(find.text('View reading'), findsNothing);
      expect(find.text('Take another'), findsOneWidget);
    });

    testWidgets('a completed reading the app will not read as a rhythm offers '
        'another one; a band result does not', (t) async {
      await _pump(
        t,
        _body(const EcgCaptureState(
          phase: EcgCapturePhase.completed,
          result: EcgReadingStatus.completed,
          readingId: 'r',
          outcome: _noisy,
        )),
      );
      expect(find.text('Take another'), findsOneWidget);
      await _pump(
        t,
        _body(const EcgCaptureState(
          phase: EcgCapturePhase.completed,
          result: EcgReadingStatus.completed,
          readingId: 'r',
          outcome: EcgOutcome(
            kind: EcgOutcomeKind.bandResult,
            bandResult: EcgCategory.sinusRhythm,
            caveats: [EcgCaveat.bandReportedQualityUnchecked],
            resultCode: 1,
            avgHr: 77,
            mask: 0,
          ),
        )),
      );
      expect(find.text('Take another'), findsNothing);
    });

    testWidgets('a rate beside "Not readable" is not shown in the headline',
        (t) async {
      await _pump(
        t,
        _body(EcgCaptureState(
          phase: EcgCapturePhase.completed,
          result: EcgReadingStatus.completed,
          readingId: 'r',
          outcome: _noisy,
          metrics: [
            const EcgMetric(key: 'avgHr', name: 'Average heart rate', value: 77, unit: 'bpm'),
          ],
        )),
      );
      expect(_allText(t), isNot(contains('77 bpm')));
    });

    testWidgets('a first terminal that saved as Not readable (result 6 with a '
        'noise mask) says so on the retry screen, with its reason AND the '
        'retry', (t) async {
      await _pump(
        t,
        _body(const EcgCaptureState(
          phase: EcgCapturePhase.inconclusiveRetry,
          readingId: 'att',
          outcome: _noisy,
        )),
      );
      final text = _allText(t);
      expect(text, contains('Not readable'));
      expect(text, isNot(contains('Inconclusive')));
      expect(text, contains('· Significant noise'));
      expect(find.text('Try once more'), findsOneWidget);
      expect(find.text('View reading'), findsOneWidget);
    });

    testWidgets('a retry screen whose outcome is Inconclusive keeps its '
        'words and the retry', (t) async {
      await _pump(
        t,
        _body(const EcgCaptureState(
          phase: EcgCapturePhase.inconclusiveRetry,
          readingId: 'att',
          outcome: EcgOutcome(
            kind: EcgOutcomeKind.inconclusive,
            resultCode: 6,
            avgHr: 70,
            mask: 0,
          ),
        )),
      );
      expect(_allText(t), contains('Inconclusive'));
      expect(find.text('Try once more'), findsOneWidget);
    });

    testWidgets('a first inconclusive that was saved can be viewed',
        (t) async {
      await _pump(
        t,
        _body(const EcgCaptureState(
          phase: EcgCapturePhase.inconclusiveRetry,
          readingId: 'att',
        )),
      );
      expect(find.text('Try once more'), findsOneWidget);
      expect(find.text('View reading'), findsOneWidget);
    });
  });
}
