// PRV diagnostics (design 04 R4 follow-up, item g): Nerd stats shows WHY the
// irregular-rhythm screen flagged or abstained - from the persisted day bundle,
// nothing recomputed:
//
//   * the beat counts (before cleaning, corrected, dropped, analysed) and the
//     artifact share, for the 24 h screen and the sleep screen;
//   * the sleep screen's pNN and beat count (stored since this change);
//   * the window counts - total, voting, flagged, the final OPEN window's beats
//     and what became of it - and observed vs required sustained share;
//   * an abstention names its reason in words WITH the counts that caused it;
//   * a count that was never stored shows as nothing (or an em-dash), NEVER as
//     0 / 0 %.
//
// Fed through InvestigateData exactly as the repository shapes it
// (getDayHeart / getDayHrv): the new data rides inside `heart['irregular']`
// (plain map) and `heart['irregular_24h']` (envelope) under `diagnostics`.
//
// Design question for the green phase (see report): MonoTable DROPS a row whose
// value is the em-dash, so "shows '—' when absent" and "an unpersisted value has
// no row" (prv_display_test.dart, Phase 1) are the same thing on this surface.
// These tests pin only what both conventions share: a known figure is on
// screen, an unknown one is never a zero.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/investigate.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Map<String, dynamic> _diag({
  String? abstain,
  int? rrRaw = 12345,
  int nnIn = 12124,
  int nnKept = 12100,
  int? corrected = 77,
  int? dropped = 221,
  double artifact = 0.0638,
  Map<String, dynamic>? windows = const {
    'total': 61,
    'valid': 55,
    'flagged': 17,
    'sustained_observed': 0.3091,
    'open_beats': 43,
    'open': 'thin',
  },
  int minBeats = 500,
  double maxArtifact = 0.3,
}) => {
  'version': 1,
  'abstain': abstain,
  'beats': {
    'rr_raw': rrRaw,
    'nn_in': nnIn,
    'nn_kept': nnKept,
    'corrected': corrected,
    'dropped': dropped,
    'artifact_fraction': artifact,
  },
  'windows': windows,
  'thresholds': {
    'min_beats': minBeats,
    'max_artifact': maxArtifact,
    'sd1sd2_flag': 0.7,
    'pnn_threshold_ms': 70.0,
    'pnn_flag_pct': 30.0,
    'window_minutes': 5.0,
    'min_window_beats': 40,
    'sustained_fraction': 0.5,
  },
};

Map<String, dynamic> _env24({Map<String, dynamic>? diagnostics, bool present = true}) => {
  'value': present
      ? {
          'sd1_ms': 41.2,
          'sd2_ms': 55.3,
          'sd1_sd2': 0.75,
          'pnn_pct': 33.1,
          'n_beats': 12100,
          'flag': false,
        }
      : '—',
  'confidence': present ? 0.62 : 0.0,
  'tier': 'ESTIMATE',
  'inputs_used': ['rr_cleaned'],
  'diagnostics': ?diagnostics,
};

Map<String, dynamic> _sleep({Map<String, dynamic>? diagnostics, bool present = true}) => {
  'sd1': present ? 30.0 : null,
  'sd2': present ? 60.0 : null,
  'flag': present ? true : null,
  'confidence': present ? 0.7 : 0.0,
  if (present) 'pnn_pct': 41.7,
  if (present) 'n_beats': 3456,
  if (present) 'sd1_sd2': 0.5,
  'diagnostics': ?diagnostics,
};

Future<String> _pump(
  WidgetTester t, {
  Map<String, dynamic> heart = const {},
  Map<String, dynamic> hrv = const {},
}) async {
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
      data: InvestigateData(day: '2026-10-07', heart: heart, hrv: hrv),
    ),
  ));
  await t.pumpAndSettle();
  return t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').join('\n');
}

/// [n] as its own number on screen (not a fragment of a longer one).
bool _has(String text, String n) =>
    RegExp('(^|[^\\d.,])${RegExp.escape(n)}(?![\\d,])').hasMatch(text);

bool _words(String text, String re) => RegExp(re, caseSensitive: false).hasMatch(text);

/// A line that is just a zero: what an unknown count must never render as.
final _bareZero = RegExp(r'(^|\n)0(\.0+)?( ?%)?($|\n)');

void main() {
  group('a screen that ran: the evidence behind the verdict', () {
    testWidgets('24 h: beats, cleaning, windows, the open window, sustained '
        'share vs the share required', (t) async {
      final text = await _pump(t, heart: {
        'irregular_24h': _env24(diagnostics: _diag()),
      });
      expect(_has(text, '12,345'), isTrue, reason: 'beats before cleaning');
      expect(_has(text, '77'), isTrue, reason: 'spline-corrected');
      expect(_has(text, '221'), isTrue, reason: 'dropped');
      expect(_has(text, '12,100'), isTrue, reason: 'beats analysed');
      expect(_words(text, r'6\.4 ?%'), isTrue, reason: 'artifact share 0.0638');
      expect(_has(text, '61'), isTrue, reason: 'windows in all');
      expect(_has(text, '55'), isTrue, reason: 'windows that vote');
      expect(_has(text, '17'), isTrue, reason: 'windows flagged');
      expect(_words(text, r'30\.9 ?%'), isTrue, reason: 'observed 17/55');
      expect(_words(text, r'(^|[^\d.])50(\.0)? ?%'), isTrue,
          reason: 'the share the rule requires');
      expect(_has(text, '43'), isTrue, reason: 'beats in the final, open window');
      expect(_words(text, r'open|final window|last window|partial'), isTrue,
          reason: 'the open window is labelled, not folded into the others');
      expect(_words(text, r'too few|not enough|thin|excluded|short'), isTrue,
          reason: 'and says it did not vote (43 of 40 needed... here: thin)');
    });

    testWidgets('a valid open window is not described as excluded', (t) async {
      final d = _diag(windows: const {
        'total': 9,
        'valid': 9,
        'flagged': 4,
        'sustained_observed': 0.4444,
        'open_beats': 181,
        'open': 'flagged',
      });
      final text = await _pump(t, heart: {'irregular_24h': _env24(diagnostics: d)});
      expect(_has(text, '181'), isTrue);
      expect(_words(text, r'too few|not enough|excluded'), isFalse,
          reason: 'a window of 181 beats voted');
    });

    testWidgets('sleep: pNN and beat count (stored now), cleaning counts, '
        'windows', (t) async {
      final text = await _pump(t, heart: {
        'irregular': _sleep(
          diagnostics: _diag(
            rrRaw: 4100,
            nnIn: 4067,
            nnKept: 3456,
            corrected: 33,
            dropped: 33,
            windows: const {
              'total': 9,
              'valid': 8,
              'flagged': 1,
              'sustained_observed': 0.125,
              'open_beats': 12,
              'open': 'thin',
            },
          ),
        ),
      });
      expect(_has(text, '41.7'), isTrue, reason: 'sleep pNN');
      expect(_has(text, '3,456'), isTrue, reason: 'sleep beats analysed');
      expect(_has(text, '4,100'), isTrue, reason: 'beats before cleaning');
      expect(_has(text, '33'), isTrue, reason: 'corrected / dropped');
      expect(_has(text, '12'), isTrue, reason: 'open window beats');
      expect(_words(text, r'12\.5 ?%'), isTrue, reason: 'observed 1/8');
    });

    testWidgets('both screens at once do not blur into one another', (t) async {
      final text = await _pump(t, heart: {
        'irregular': _sleep(diagnostics: _diag(rrRaw: 4100, nnIn: 4067, nnKept: 3456)),
        'irregular_24h': _env24(diagnostics: _diag()),
      });
      expect(_has(text, '4,100'), isTrue);
      expect(_has(text, '12,345'), isTrue);
      expect(_words(text, r'sleep'), isTrue);
      expect(_words(text, r'24 ?h'), isTrue);
    });
  });

  group('a screen that abstained says why, with the counts that caused it', () {
    testWidgets('too few beats: how many it had and how many it needs',
        (t) async {
      final text = await _pump(t, heart: {
        'irregular_24h': _env24(
          present: false,
          diagnostics: _diag(
              abstain: 'too_few_beats',
              rrRaw: 230,
              nnIn: 218,
              nnKept: 212,
              corrected: 6,
              dropped: 12,
              windows: const {
                'total': 1,
                'valid': 1,
                'flagged': 0,
                'sustained_observed': 0.0,
                'open_beats': 212,
                'open': 'unflagged',
              }),
        ),
      });
      expect(_words(text, r'too few|not enough|fewer'), isTrue);
      expect(_has(text, '212'), isTrue, reason: 'beats it had');
      expect(_has(text, '500'), isTrue, reason: 'beats it needs');
      expect(text.contains('too_few_beats'), isFalse,
          reason: 'a reason is words, not a wire name');
      expect(_has(text, '230'), isTrue, reason: 'raw beats still shown');
    });

    testWidgets('over the artifact line: the share it saw and the share allowed',
        (t) async {
      final text = await _pump(t, heart: {
        'irregular': _sleep(
          present: false,
          diagnostics: _diag(
              abstain: 'artifact', artifact: 0.45, nnKept: 1900, nnIn: 1900),
        ),
      });
      expect(_words(text, r'artifact|noisy|noise'), isTrue);
      expect(_words(text, r'45(\.0)? ?%'), isTrue, reason: 'the share seen');
      expect(_words(text, r'30(\.0)? ?%'), isTrue, reason: 'the share allowed');
      expect(text.contains('artifact_fraction'), isFalse);
    });

    testWidgets('no variability / no adjacent pairs have their own wording',
        (t) async {
      final a = await _pump(t, heart: {
        'irregular_24h': _env24(
            present: false, diagnostics: _diag(abstain: 'no_long_term_variability')),
      });
      expect(
          _words(a,
              r'no (long-term )?variability|variability (is )?(zero|absent|missing)|SD2 (is )?(zero|0)|undefined'),
          isTrue);
      expect(a.contains('no_long_term_variability'), isFalse);
      final b = await _pump(t, heart: {
        'irregular_24h': _env24(
            present: false, diagnostics: _diag(abstain: 'no_successive_pairs')),
      });
      expect(
          _words(b,
              r'no (successive|adjacent|consecutive)|(successive|adjacent|consecutive) (clean )?(beats|pairs)|no pairs'),
          isTrue);
      expect(b.contains('no_successive_pairs'), isFalse);
    });

    testWidgets('an abstained screen is never rendered as "not flagged"',
        (t) async {
      await _pump(t, heart: {
        'irregular_24h': _env24(
            present: false, diagnostics: _diag(abstain: 'too_few_beats')),
        'irregular': _sleep(present: false, diagnostics: _diag(abstain: 'artifact')),
      });
      expect(find.text('not flagged'), findsNothing);
      expect(find.text('not screened'), findsWidgets);
    });
  });

  group('absent stays absent (never 0)', () {
    testWidgets('a day stored before diagnostics existed shows no invented '
        'counts', (t) async {
      final text = await _pump(t, heart: {
        'irregular_24h': _env24(),
        'irregular': {'sd1': 30.0, 'sd2': 60.0, 'flag': true, 'confidence': 0.7},
      });
      expect(_bareZero.hasMatch(text), isFalse);
      expect(_words(text, r'0 windows|0 beats|0 corrected|0 dropped'), isFalse);
    });

    testWidgets('counts the corrector never reported are not zeros', (t) async {
      final text = await _pump(t, heart: {
        'irregular_24h': _env24(
            diagnostics: _diag(rrRaw: null, corrected: null, dropped: null)),
      });
      expect(_bareZero.hasMatch(text), isFalse,
          reason: 'null corrected / dropped / raw render as nothing or a dash');
      expect(_has(text, '12,100'), isTrue, reason: 'what is known is still shown');
      expect(_has(text, '61'), isTrue);
    });

    testWidgets('windows never evaluated (no beat times) are not "0 windows"',
        (t) async {
      final text = await _pump(t, heart: {
        'irregular_24h': _env24(diagnostics: _diag(windows: null)),
      });
      expect(_bareZero.hasMatch(text), isFalse);
      expect(_has(text, '12,100'), isTrue);
    });

    testWidgets('a valid-window count of zero is a real zero when stored, and '
        'the share is not made up', (t) async {
      final text = await _pump(t, heart: {
        'irregular_24h': _env24(
            diagnostics: _diag(windows: const {
          'total': 38,
          'valid': 0,
          'flagged': 0,
          'sustained_observed': null,
          'open_beats': 27,
          'open': 'thin',
        })),
      });
      expect(_words(text, r'(^|[^\d.])0(\.0)? ?%'), isFalse,
          reason: 'no voting window: the share observed is unknown, not 0 %');
      expect(_has(text, '38'), isTrue, reason: 'windows in all');
      expect(_has(text, '27'), isTrue, reason: 'beats in the open window');
    });
  });
}
