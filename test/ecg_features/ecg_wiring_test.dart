// ECG features (green): source guards for the wiring that has no seam to pump
// in a unit test, in the idiom of test/gestures_confirm_cue_test.dart's
// "wiring (source guards)": AppState hands the controller the replacing save,
// the Keep waveform preference and the cue player; the ECG home screen has the
// Keep waveform switch and the screener link; the Haptics screen opens the ECG
// home from its ECG group.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final app = File('lib/state/app_state.dart').readAsStringSync();
  final ecg = File('lib/ui2/screens/ecg.dart').readAsStringSync();
  final hapticsUi = File('lib/ui2/profile/haptics_settings.dart').readAsStringSync();

  test('AppState builds the ECG controller with the replacing save, the Keep '
      'waveform preference and the cue player', () {
    expect(app, contains('LocalDb.saveEcgResult('));
    expect(app, isNot(contains('LocalDb.insertEcgReading(')),
        reason: 'the plain insert would never replace an inconclusive reading');
    expect(app, contains('keepWaveform: () => ecgKeepWaveform'));
    expect(app, contains('onCue: (slot) => unawaited(_playEcgCue(slot))'));
  });

  test('the cue plays the slot through the gesture cues, one dispatcher '
      'delivery, after loading the wearer\'s assignments', () {
    final body = app.substring(app.indexOf('Future<void> _playEcgCue('));
    final fn = body.substring(0, body.indexOf('EcgController _buildEcg'));
    expect(fn, contains('_gestures.loadCues()'));
    expect(fn, contains('alertDispatcher.dispatch('));
    expect(fn, contains('gestureCues.slot(slot)'));
  });

  test('Keep waveform is off by default, persisted, and loaded at start', () {
    expect(app, contains('bool ecgKeepWaveform = false;'));
    expect(app, contains("'ecg_keep_waveform'"));
    expect(app, contains('.getBool(_kEcgKeepWaveform)'));
  });

  test('the ECG home has the Keep waveform switch and the screener link', () {
    expect(ecg, contains("'Keep waveform'"));
    expect(ecg, contains('app.setEcgKeepWaveform'));
    expect(ecg, contains("ValueKey('ecg-screener-link')"));
    expect(ecg, contains('EcgScreenerScreen()'));
  });

  test('the Haptics screen\'s ECG group opens the ECG home', () {
    expect(hapticsUi, contains("'ecg' => const EcgHomeScreen()"));
    expect(hapticsUi, contains("_slotGroup(c, 'ecg')"));
  });

  test('no user-facing ECG label uses AFib / atrial fibrillation wording', () {
    final en = File('lib/l10n/app_en.arb').readAsStringSync();
    final labels = RegExp(r'"ecgCategory\w+": "([^"]*)"')
        .allMatches(en)
        .map((m) => m[1]!.toLowerCase());
    expect(labels, isNotEmpty);
    // The fallback literals in ecgCategoryLabel too.
    final fallbacks = RegExp(r"\?\? '([^']*)'")
        .allMatches(ecg.substring(0, ecg.indexOf('List<String> ecgReasonLabels')))
        .map((m) => m[1]!.toLowerCase());
    for (final l in [...labels, ...fallbacks]) {
      expect(l, isNot(contains('afib')));
      expect(l, isNot(contains('fibrillation')));
    }
  });

  test('no diagnosis word in any ECG string of any language (the owner spec '
      'bans them user-facing; there is no disclaimer exemption)', () {
    const stems = {
      'en': ['diagnos'],
      'de': ['diagnos'],
      'es': ['diagnos', 'diagnós'],
      'fr': ['diagnos'],
      'hi': ['निदान'],
      'zh': ['诊断'],
    };
    for (final e in stems.entries) {
      final arb = File('lib/l10n/app_${e.key}.arb').readAsStringSync();
      final values = RegExp(r'"(ecg\w+)": "([^"]*)"')
          .allMatches(arb)
          .map((m) => (m[1]!, m[2]!.toLowerCase()));
      expect(values, isNotEmpty, reason: e.key);
      for (final (key, v) in values) {
        for (final stem in e.value) {
          expect(v, isNot(contains(stem)), reason: '${e.key} $key');
        }
      }
    }
    // The fallback literals in the screens and the screener copy.
    for (final f in [
      'lib/ui2/screens/ecg.dart',
      'lib/ui2/screens/ecg_screener.dart',
      'lib/ecg/ecg_screener.dart',
    ]) {
      final src = File(f)
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      final literals = RegExp(r"'([^'\n]*)'").allMatches(src).map((m) => m[1]!);
      for (final l in literals) {
        expect(l.toLowerCase(), isNot(contains('diagnos')), reason: '$f: $l');
      }
    }
  });

  test('the ECG screens say what the result is, in words: a screen, not a '
      'medical test', () {
    final en = File('lib/l10n/app_en.arb').readAsStringSync();
    expect(en, contains('This is a screen, not a medical test.'));
  });
}
