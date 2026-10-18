// Design 04 phase 1 (RED) - item 7 (R6'): one rule for the coach, on both entry
// points, and both read the SAME outcome (ecgOutcome).
//
//   outcome                                   button          get_ecg_reading
//   notReadable / inconclusive / partial      ABSENT, status  outcome + reasons + band values;
//                                             "No rhythm      NO waveform samples; an instruction
//                                             reading to      not to interpret rhythm
//                                             analyze - <r>"
//   bandResult, waveform not kept             ABSENT, status  outcome + band values; no samples
//                                             "Waveform not
//                                             kept"
//   bandResult, waveform kept                 shown           outcome FIRST (with its caveat),
//                                                             samples, "quality scale unknown"
//   and the "0-3 higher is better" quality claim is gone.
//
// ASSUMED payload shape (lib/coach/coach_actions.dart ecgReading): a top-level
// `outcome` map {kind: EcgOutcomeKind.name, band_result: category name|null,
// reasons: [EcgReason.toString()], caveats: [EcgCaveat.name]} as the FIRST key;
// `waveform_kept` bool; `instruction` String present when no rhythm may be read;
// no `waveform` key (and no "samples" key anywhere) without a readable, kept
// reading. Status line / button keys on the detail screen: absent
// `Analyze now` text; status text "No rhythm reading to analyze - <reason>"
// (U+2014 dash) or "Waveform not kept".

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_actions.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_outcome.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/ecg.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/cardio_fixtures.dart';

// id -> (reading, packets kept)
final _cases = <String, (EcgReading, int)>{
  'ok_kept': (cardioReading(id: 'ok_kept', startTs: kC0), 3),
  'ok_nokeep': (cardioReading(id: 'ok_nokeep', startTs: kC0 + 100), 0),
  // terminal-only mask: the legacy column the outcome must not miss (R1'')
  'noisy': (cardioReading(id: 'noisy', startTs: kC0 + 200, unreadableMask: 2), 3),
  'inconclusive': (inconclusiveAt(kC0 + 330, id: 'inconclusive'), 3),
  'unreadable': (unreadableEndingAt(kC0 + 430, id: 'unreadable'), 3),
  'partial': (partialAt(kC0 + 530, id: 'partial'), 3),
  'unknown_code': (
    cardioReading(
      id: 'unknown_code',
      startTs: kC0 + 600,
      resultCode: 9,
      category: EcgCategory.unreadable,
    ),
    3,
  ),
  'hr_mismatch': (
    // the old live-HR path stored "regular"; the average rate says otherwise
    cardioReading(id: 'hr_mismatch', startTs: kC0 + 700, avgHr: 120),
    3,
  ),
};

Future<Map<String, dynamic>> _tool(String id) async {
  final out = await CoachActions.ecgReading(await LocalDb.instance, id);
  return jsonDecode(out) as Map<String, dynamic>;
}

Future<String> _toolRaw(String id) async =>
    CoachActions.ecgReading(await LocalDb.instance, id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_ecg_coach_policy_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    for (final (r, n) in _cases.values) {
      await LocalDb.insertEcgReading(
        r.toRow(),
        [for (var i = 0; i < n; i++) cardioPacketRow(i)],
      );
    }
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  group('get_ecg_reading: the same outcome, no samples when none may be read',
      () {
    for (final id in [
      'noisy',
      'inconclusive',
      'unreadable',
      'partial',
      'unknown_code',
      'hr_mismatch',
    ]) {
      test('$id: outcome + reasons + band values, NO waveform samples, and an '
          'instruction not to interpret rhythm', () async {
        final raw = await _toolRaw(id);
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final reading = _cases[id]!.$1;
        final o = ecgOutcome(reading);
        expect(o.kind, isNot(EcgOutcomeKind.bandResult), reason: 'precondition');
        final jo = j['outcome'] as Map<String, dynamic>;
        expect(jo['kind'], o.kind.name);
        expect(jo['reasons'], [for (final r in o.reasons) r.toString()]);
        expect(jo['band_result'], isNull);
        expect(j['result_code'], reading.resultCode, reason: 'band values stay');
        expect(j.containsKey('avg_hr'), isTrue);
        expect(RegExp(r'"samples"\s*:').hasMatch(raw), isFalse,
            reason: 'no waveform samples');
        expect(j.containsKey('waveform'), isFalse);
        expect((j['instruction'] as String).toLowerCase(),
            contains('do not interpret'));
      });
    }

    test('terminal-only mask: the coach sees notReadable for a reading the '
        'band called "regular"', () async {
      final j = await _tool('noisy');
      expect((j['outcome'] as Map)['kind'], EcgOutcomeKind.notReadable.name);
      expect(((j['outcome'] as Map)['reasons'] as List).join(' '),
          contains(EcgReasonId.significantNoise));
    });

    test('bandResult, waveform NOT kept: outcome + band values, no samples, '
        'said plainly', () async {
      final raw = await _toolRaw('ok_nokeep');
      final j = jsonDecode(raw) as Map<String, dynamic>;
      expect((j['outcome'] as Map)['kind'], EcgOutcomeKind.bandResult.name);
      expect((j['outcome'] as Map)['band_result'], 'sinusRhythm');
      expect(j['waveform_kept'], isFalse);
      expect(RegExp(r'"samples"\s*:').hasMatch(raw), isFalse);
      expect(j['result_code'], 1);
    });

    test('bandResult, waveform kept: the outcome comes FIRST with its caveat, '
        'then the samples', () async {
      final j = await _tool('ok_kept');
      expect(j.keys.first, 'outcome');
      final o = j['outcome'] as Map<String, dynamic>;
      expect(o['kind'], EcgOutcomeKind.bandResult.name);
      expect(o['band_result'], 'sinusRhythm');
      expect(o['caveats'],
          [EcgCaveat.bandReportedQualityUnchecked.name]);
      expect(j['waveform_kept'], isTrue);
      expect(((j['waveform'] as Map)['samples'] as List), isNotEmpty);
    });

    test('the outcome is FIRST in every payload', () async {
      for (final id in _cases.keys) {
        expect((await _tool(id)).keys.first, 'outcome', reason: id);
      }
    });

    test('the quality scale is "unknown", and the "0-3, higher is better" '
        'claim is gone - from the payload and from the source', () async {
      for (final id in ['ok_kept', 'ok_nokeep', 'noisy']) {
        final raw = await _toolRaw(id);
        expect(raw.toLowerCase(), isNot(contains('higher is better')), reason: id);
        expect(raw, isNot(contains('0-3')), reason: id);
      }
      final j = await _tool('ok_kept');
      final q = ((j['how_to_read'] as Map)['quality'] as String).toLowerCase();
      expect(q, contains('unknown'));
      final src = File('lib/coach/coach_actions.dart').readAsStringSync();
      expect(src.toLowerCase().contains('higher is'), isFalse);
      expect(src.contains('0-3 signal-quality'), isFalse);
    });

    test('an unknown id is still an error', () async {
      expect(await _tool('nope'), containsPair('error', contains('nope')));
    });
  });

  group('the Analyze now control (detail screen)', () {
    Future<void> pumpDetail(WidgetTester t, String id) async {
      final (r, n) = _cases[id]!;
      t.view.physicalSize = const Size(1170, 12000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: EcgDetailScreen(
          data: EcgDetailData(
            reading: r,
            packets: [for (var i = 0; i < n; i++) cardioPacket(i)],
          ),
        ),
      ));
      await t.pump();
    }

    String text(WidgetTester t) => t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .join('\n');

    for (final id in ['noisy', 'inconclusive', 'unreadable', 'partial', 'unknown_code', 'hr_mismatch']) {
      testWidgets('$id: the control is ABSENT and a status line says why',
          (t) async {
        await pumpDetail(t, id);
        expect(find.text('Analyze now'), findsNothing);
        expect(find.textContaining('No rhythm reading to analyze — '), findsOneWidget);
        final line = text(t)
            .split('\n')
            .firstWhere((l) => l.startsWith('No rhythm reading to analyze — '));
        expect(line.length, greaterThan('No rhythm reading to analyze — '.length),
            reason: 'a reason follows');
      });
    }

    testWidgets('a band result whose waveform was not kept: no control, '
        '"Waveform not kept"', (t) async {
      await pumpDetail(t, 'ok_nokeep');
      expect(find.text('Analyze now'), findsNothing);
      expect(find.textContaining('Waveform not kept'), findsOneWidget);
      expect(find.textContaining('No rhythm reading to analyze'), findsNothing);
    });

    testWidgets('a band result with its waveform kept: the control is there, '
        'no status line', (t) async {
      await pumpDetail(t, 'ok_kept');
      expect(find.text('Analyze now'), findsWidgets,
          reason: 'the action card carries it as title and button');
      expect(find.textContaining('No rhythm reading to analyze'), findsNothing);
      expect(find.textContaining('Waveform not kept'), findsNothing);
    });
  });

  group('the coach text', () {
    test('the get_ecg_reading tool description and the system prompt talk '
        'about the OUTCOME, not only the band category', () {
      final engine = File('lib/coach/coach_engine.dart').readAsStringSync();
      final i = engine.indexOf("_fn('get_ecg_reading'");
      expect(i, greaterThan(0));
      final desc = engine.substring(i, engine.indexOf('_fn(', i + 10));
      expect(desc.toLowerCase(), contains('outcome'));
      final prompt = File('lib/coach/coach_prompt.dart').readAsStringSync();
      final j = prompt.indexOf('7. ECG READINGS');
      final sec = prompt.substring(j, prompt.indexOf('# DON\'T RESTATE THE APP'));
      expect(sec.toLowerCase(), contains('outcome'));
      expect(sec.toLowerCase(), anyOf(contains('do not interpret'), contains("don't interpret")));
    });
  });
}
