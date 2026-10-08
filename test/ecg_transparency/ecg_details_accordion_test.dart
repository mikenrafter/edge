// Design 04 phase 1 (RED) - item 4 and the outcome on screen (R1, R3):
//   * every reading's detail screen has an always-available Details accordion
//     (key `ecg-details`), NOT gated by the Nerd stats density setting, with
//     every app-known number and rule, named "band's own logic is proprietary
//     and unknown", and "captured with table vN / shown now with table vM";
//   * a column that is NULL (legacy row, or a provider that knew nothing) reads
//     "not recorded" - never inferred, the 0xffff sentinel never prints as
//     65535;
//   * Keep waveform on and off both work (packets row says how many / "not
//     kept");
//   * the headline, the history row and the capture body all show the SAME
//     outcome: a set band mask is "Not readable", never a rhythm label.
//
// ASSUMED widget keys (the contract with the implementer): `ecg-details` (the
// accordion header, tap to expand), `ecg-detail:<field>` for each R7' field
// name (result_code, category, avg_hr, live_hr, quality, unreadable_mask,
// mask_any, variability_raw, min_uv, max_uv, rms_uv, sample_count,
// missing_segments, interruptions, stop_reason, firmware_version,
// capture_app_version, capture_table_version, start_offset_min, packets,
// outcome), `ecg-detail:band-logic`, `ecg-detail:rules`, and
// `ecg-attempt:<reading id>` for each attempt of the group. Rows are built only
// while expanded.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_controller.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_outcome.dart';
import 'package:openstrap_edge/ecg/ecg_waveform_buffer.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/app_localizations_en.dart';
import 'package:openstrap_edge/ui2/screens/ecg.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/cardio_fixtures.dart';

Future<void> _pump(WidgetTester t, Widget home) async {
  t.view.physicalSize = const Size(1170, 12000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
  await t.pump();
}

String _allText(WidgetTester t) =>
    t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').join('\n');

Finder _key(String k) => find.byKey(ValueKey(k));
Finder _detail(String f) => _key('ecg-detail:$f');

String _rowText(WidgetTester t, String field) => t
    .widgetList<Text>(
      find.descendant(of: _detail(field), matching: find.byType(Text)),
    )
    .map((w) => w.data ?? '')
    .join(' ');

Future<void> _expand(WidgetTester t) async {
  await t.tap(_key('ecg-details'));
  await t.pumpAndSettle();
}

EcgDetailData _data(EcgReading r, {int packets = 0, List<EcgReading> attempts = const []}) =>
    EcgDetailData(
      reading: r,
      packets: [for (var i = 0; i < packets; i++) cardioPacket(i)],
      attempts: attempts,
    );

EcgReading get _full => cardioReading(
  id: 'full',
  unreadableMask: 2,
  maskAny: 6,
  avgHr: 77,
  liveHr: 78,
  quality: 3,
  variabilityRaw: 1234,
  interruptions: 1,
  firmwareVersion: '5.2.1',
  captureAppVersion: '0.9.30+88',
  captureTableVersion: kEcgOutcomeTableVersion - 1,
  startOffsetMin: -420,
);

void main() {
  group('the accordion is there for EVERY reading, with no Nerd stats setting',
      () {
    final variants = <String, (EcgReading, int)>{
      'completed, Keep waveform off': (cardioReading(), 0),
      'completed, Keep waveform on': (cardioReading(), 3),
      'inconclusive': (inconclusiveAt(kC0 + 100), 0),
      'unreadable': (unreadableEndingAt(kC0 + 100), 2),
      'partial': (partialAt(kC0 + 100), 0),
      'full provenance': (_full, 3),
      'legacy, every new column NULL': (cardioReading(), 0),
    };
    for (final e in variants.entries) {
      testWidgets(e.key, (t) async {
        await _pump(t, EcgDetailScreen(data: _data(e.value.$1, packets: e.value.$2)));
        expect(_key('ecg-details'), findsOneWidget);
      });
    }

    testWidgets('collapsed it shows no rows; tapping opens it', (t) async {
      await _pump(t, EcgDetailScreen(data: _data(_full, packets: 3)));
      expect(_detail('result_code'), findsNothing);
      await _expand(t);
      expect(_detail('result_code'), findsOneWidget);
    });
  });

  group('every app-known number, with its meaning', () {
    testWidgets('a fully recorded reading lists each field with its value',
        (t) async {
      await _pump(t, EcgDetailScreen(data: _data(_full, packets: 3)));
      await _expand(t);
      expect(_rowText(t, 'result_code'), contains('1'));
      expect(_rowText(t, 'avg_hr'), contains('77'));
      expect(_rowText(t, 'live_hr'), contains('78'));
      expect(_rowText(t, 'quality'), contains('3'));
      expect(_rowText(t, 'quality').toLowerCase(), contains('unknown'),
          reason: 'band-reported, scale unknown');
      expect(_rowText(t, 'unreadable_mask').toLowerCase(), contains('noise'));
      expect(_rowText(t, 'mask_any').toLowerCase(),
          allOf(contains('noise'), contains('unstable')));
      expect(_rowText(t, 'variability_raw'), contains('1234'));
      expect(_rowText(t, 'variability_raw').toLowerCase(), contains('unknown'),
          reason: 'raw, unit unknown');
      expect(_rowText(t, 'min_uv'), contains('-500'));
      expect(_rowText(t, 'max_uv'), contains('700'));
      expect(_rowText(t, 'rms_uv'), contains('120'));
      expect(_rowText(t, 'sample_count'), contains('3000'));
      expect(_rowText(t, 'interruptions'), contains('1'));
      expect(_rowText(t, 'missing_segments'), contains('0'));
      expect(_rowText(t, 'firmware_version'), contains('5.2.1'));
      expect(_rowText(t, 'capture_app_version'), contains('0.9.30+88'));
      expect(_rowText(t, 'start_offset_min'),
          anyOf(contains('-420'), contains('-07:00')));
    });

    testWidgets('the outcome row says what the app decided and why', (t) async {
      await _pump(t, EcgDetailScreen(data: _data(_full)));
      await _expand(t);
      final text = _rowText(t, 'outcome');
      expect(text, contains('Not readable'));
      expect(text.toLowerCase(), contains('noise'));
    });

    testWidgets('captured-vs-current table version: both are shown when they '
        'differ', (t) async {
      await _pump(t, EcgDetailScreen(data: _data(_full)));
      await _expand(t);
      final text = _rowText(t, 'capture_table_version');
      expect(text.toLowerCase(), contains('captured'));
      expect(text.toLowerCase(), contains('now'));
      expect(text, contains('${kEcgOutcomeTableVersion - 1}'));
      expect(text, contains('$kEcgOutcomeTableVersion'));
    });

    testWidgets('the rate-mapping text is stated as the app\'s reverse-'
        'engineered reading, not a validation', (t) async {
      await _pump(t, EcgDetailScreen(data: _data(_full)));
      await _expand(t);
      final rules = _allTextOf(t, 'rules').toLowerCase();
      expect(rules, contains('51–99 bpm'));
      expect(rules, contains('100–150 bpm'));
      expect(rules, contains('151–200 bpm'));
      expect(rules, contains('not from a validation of this device'));
      expect(rules, contains('average heart rate'),
          reason: 'the one HR source is named');
      expect(rules, anyOf(contains('reason bit'), contains('mask')),
          reason: 'the override rule is stated');
    });

    testWidgets('the band\'s own logic is named as proprietary and unknown',
        (t) async {
      await _pump(t, EcgDetailScreen(data: _data(cardioReading())));
      await _expand(t);
      final text = _allTextOf(t, 'band-logic').toLowerCase();
      expect(text, contains('proprietary'));
      expect(text, contains('unknown'));
    });

    testWidgets('Keep waveform on: the packets row says how many were kept; '
        'off: "not kept"', (t) async {
      await _pump(t, EcgDetailScreen(data: _data(cardioReading(), packets: 3)));
      await _expand(t);
      expect(_rowText(t, 'packets'), contains('3'));
      expect(_rowText(t, 'packets').toLowerCase(), isNot(contains('not kept')));

      await _pump(t, EcgDetailScreen(data: _data(cardioReading())));
      await _expand(t);
      expect(_rowText(t, 'packets').toLowerCase(), contains('not kept'));
    });

    testWidgets('a partial reading lists why it stopped', (t) async {
      await _pump(t, EcgDetailScreen(data: _data(partialAt(kC0 + 100))));
      await _expand(t);
      expect(_rowText(t, 'stop_reason'), contains('paused'));
    });
  });

  group('NULL is "not recorded" - never inferred', () {
    testWidgets('a legacy row (every new column NULL) says so, field by field',
        (t) async {
      await _pump(t, EcgDetailScreen(data: _data(cardioReading())));
      await _expand(t);
      for (final f in [
        'mask_any',
        'live_hr',
        'variability_raw',
        'firmware_version',
        'capture_app_version',
        'capture_table_version',
        'start_offset_min',
      ]) {
        expect(_rowText(t, f).toLowerCase(), contains('not recorded'), reason: f);
      }
      expect(_rowText(t, 'variability_raw'), isNot(contains('65535')));
      expect(_rowText(t, 'variability_raw'), isNot(contains('0')),
          reason: 'not recorded is not zero');
      expect(_rowText(t, 'live_hr'), isNot(contains('77')),
          reason: 'live HR is not inferred from the average');
    });

    testWidgets('a legacy row still shows the table version in force now',
        (t) async {
      await _pump(t, EcgDetailScreen(data: _data(cardioReading())));
      await _expand(t);
      expect(_rowText(t, 'capture_table_version'), contains('$kEcgOutcomeTableVersion'));
    });

    testWidgets('a measured zero is "0", not "not recorded"', (t) async {
      await _pump(
        t,
        EcgDetailScreen(
          data: _data(cardioReading(maskAny: 0, startOffsetMin: 0, variabilityRaw: 0)),
        ),
      );
      await _expand(t);
      expect(_rowText(t, 'mask_any').toLowerCase(), isNot(contains('not recorded')));
      expect(_rowText(t, 'variability_raw').toLowerCase(), isNot(contains('not recorded')));
      expect(_rowText(t, 'start_offset_min').toLowerCase(), isNot(contains('not recorded')));
    });
  });

  group('the attempts of the group are listed in Details', () {
    final a = unreadableEndingAt(kC0 + 100, id: 'A')
        .copy(attemptGroup: 'A', attempt: 1, supersededBy: 'B');
    final b = inconclusiveAt(kC0 + 300, id: 'B')
        .copy(attemptGroup: 'A', attempt: 2, supersededBy: 'C');
    final c = cardioReading(id: 'C', startTs: kC0 + 360)
        .copy(attemptGroup: 'A', attempt: 3);

    testWidgets('three attempts, in attempt order, each openable', (t) async {
      await _pump(t, EcgDetailScreen(data: _data(c, attempts: [a, b, c])));
      await _expand(t);
      for (final id in ['A', 'B', 'C']) {
        expect(_key('ecg-attempt:$id'), findsOneWidget, reason: id);
      }
      final ys = [
        for (final id in ['A', 'B', 'C']) t.getTopLeft(_key('ecg-attempt:$id')).dy,
      ];
      expect(ys, orderedEquals([...ys]..sort()));
    });

    testWidgets('a reading with no earlier attempt lists no other attempt',
        (t) async {
      await _pump(t, EcgDetailScreen(data: _data(cardioReading(id: 'solo'))));
      await _expand(t);
      for (final id in ['A', 'B', 'C']) {
        expect(_key('ecg-attempt:$id'), findsNothing);
      }
    });
  });

  group('one outcome on the headline, the history row and the capture body',
      () {
    final noisy = cardioReading(id: 'noisy', unreadableMask: 2, maskAny: 2);
    final en = AppLocalizationsEn();
    final sinusLabel = ecgCategoryLabel(en, EcgCategory.sinusRhythm);

    testWidgets('DETAIL: a set noise bit on a "regular rhythm" reading is '
        '"Not readable - the band reported ... noise", with no rhythm label',
        (t) async {
      await _pump(t, EcgDetailScreen(data: _data(noisy)));
      final text = _allText(t);
      expect(text, contains('Not readable'));
      expect(text.toLowerCase(), contains('noise'));
      expect(text, isNot(contains(sinusLabel)),
          reason: 'collapsed Details: no rhythm label anywhere');
      expect(text, isNot(contains('Regular rhythm, nothing flagged')));
    });

    testWidgets('DETAIL: a clean band result shows the band label AND the '
        'caveat that the app has not checked the recording quality',
        (t) async {
      await _pump(t, EcgDetailScreen(data: _data(cardioReading(maskAny: 0))));
      final text = _allText(t);
      expect(text, contains(sinusLabel));
      expect(text.toLowerCase(), contains("not checked this recording's quality"));
    });

    testWidgets('DETAIL: inconclusive and partial keep their own names',
        (t) async {
      await _pump(t, EcgDetailScreen(data: _data(inconclusiveAt(kC0 + 100))));
      expect(_allText(t), contains('Inconclusive'));
      await _pump(t, EcgDetailScreen(data: _data(partialAt(kC0 + 100))));
      expect(_allText(t), contains('Stopped early'));
    });

    testWidgets('DETAIL: an unknown band result code is not readable and says '
        'which code', (t) async {
      await _pump(
        t,
        EcgDetailScreen(data: _data(cardioReading(resultCode: 9, category: EcgCategory.unreadable))),
      );
      final text = _allText(t);
      expect(text, contains('Not readable'));
      expect(text, contains('9'));
    });

    testWidgets('HISTORY ROW: the same outcome', (t) async {
      await _pump(t, Scaffold(body: EcgReadingRow(reading: noisy)));
      final text = _allText(t);
      expect(text, contains('Not readable'));
      expect(text, isNot(contains(sinusLabel)));
    });

    testWidgets('HISTORY ROW: a band result keeps its label; a legacy row '
        'whose live-HR category was wrong is re-judged from avg_hr',
        (t) async {
      await _pump(t, Scaffold(body: EcgReadingRow(reading: cardioReading())));
      expect(_allText(t), contains(sinusLabel));
      await _pump(
        t,
        Scaffold(body: EcgReadingRow(reading: cardioReading(avgHr: 120))),
      );
      expect(_allText(t), contains('Not readable'));
      expect(_allText(t), isNot(contains(sinusLabel)));
    });

    testWidgets('CAPTURE BODY: completed with a not-readable outcome says so '
        'and shows no rhythm label', (t) async {
      await _pump(
        t,
        Scaffold(
          body: _body(const EcgCaptureState(
            phase: EcgCapturePhase.completed,
            result: EcgReadingStatus.completed,
            readingId: 'noisy',
            outcome: EcgOutcome(
              kind: EcgOutcomeKind.notReadable,
              reasons: [EcgReason(EcgReasonId.significantNoise)],
              resultCode: 1,
              avgHr: 77,
              mask: 2,
            ),
          )),
        ),
      );
      final text = _allText(t);
      expect(text, contains('Not readable'));
      expect(text.toLowerCase(), contains('noise'));
      expect(text, isNot(contains(sinusLabel)));
    });

    testWidgets('CAPTURE BODY: completed with a band result shows the label '
        'and the caveat', (t) async {
      await _pump(
        t,
        Scaffold(
          body: _body(const EcgCaptureState(
            phase: EcgCapturePhase.completed,
            result: EcgReadingStatus.completed,
            readingId: 'ok',
            outcome: EcgOutcome(
              kind: EcgOutcomeKind.bandResult,
              bandResult: EcgCategory.sinusRhythm,
              caveats: [EcgCaveat.bandReportedQualityUnchecked],
              resultCode: 1,
              avgHr: 77,
              mask: 0,
            ),
          )),
        ),
      );
      final text = _allText(t);
      expect(text, contains(sinusLabel));
      expect(text.toLowerCase(), contains("not checked this recording's quality"));
    });

    testWidgets('CAPTURE BODY: the unreadable phase says "Not readable" with '
        'the band\'s reasons', (t) async {
      await _pump(
        t,
        Scaffold(
          body: _body(const EcgCaptureState(
            phase: EcgCapturePhase.unreadable,
            unreadableMask: 2,
            readingId: 'att',
            outcome: EcgOutcome(
              kind: EcgOutcomeKind.notReadable,
              reasons: [EcgReason(EcgReasonId.significantNoise)],
              resultCode: 2,
              avgHr: null,
              mask: 2,
            ),
          )),
        ),
      );
      final text = _allText(t);
      expect(text, contains('Not readable'));
      expect(text.toLowerCase(), contains('noise'));
    });
  });
}

String _allTextOf(WidgetTester t, String field) => t
    .widgetList<Text>(
      find.descendant(of: _detail(field), matching: find.byType(Text)),
    )
    .map((w) => w.data ?? '')
    .join('\n');

Widget _body(EcgCaptureState s) => EcgCaptureBody(
  state: s,
  wrist: EcgWrist.right,
  phase: 0.25,
  live: EcgWaveformBuffer(capacity: 100),
  scheduler: EcgPreviewScheduler(),
  onRetry: () {},
  onTakeAnother: () {},
  onDone: () {},
  onView: () {},
);

extension on EcgReading {
  /// This reading with the attempt-group fields set (test-only convenience).
  EcgReading copy({String? attemptGroup, int? attempt, String? supersededBy}) =>
      EcgReading(
        id: id,
        deviceId: deviceId,
        wrist: wrist,
        startTs: startTs,
        endTs: endTs,
        strapTerminalTs: strapTerminalTs,
        strapTerminalSubsec: strapTerminalSubsec,
        resultCode: resultCode,
        category: category,
        avgHr: avgHr,
        quality: quality,
        unreadableMask: unreadableMask,
        interruptions: interruptions,
        sampleCount: sampleCount,
        minUv: minUv,
        maxUv: maxUv,
        rmsUv: rmsUv,
        missingSegments: missingSegments,
        status: status,
        notes: notes,
        createdAt: createdAt,
        stopReason: stopReason,
        maskAny: maskAny,
        supersededBy: supersededBy ?? this.supersededBy,
        attemptGroup: attemptGroup ?? this.attemptGroup,
        attempt: attempt ?? this.attempt,
        liveHr: liveHr,
        variabilityRaw: variabilityRaw,
        firmwareVersion: firmwareVersion,
        captureAppVersion: captureAppVersion,
        captureTableVersion: captureTableVersion,
        startOffsetMin: startOffsetMin,
      );
}
