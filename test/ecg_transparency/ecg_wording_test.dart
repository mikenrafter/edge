// Design 04 phase 1 (RED) - item 6 (R5 / R5'): what the recording supports,
// never what the person is.
//
//   * the hardcoded English of the ECG screener (lib/ecg/ecg_screener.dart) and
//     of the finding titles (lib/compute/findings.dart) moves to ARB keys;
//     `ecgScreenerEntries(l)` / `ecgScreenerIntro(l)` / `findingTitle(l, f)` /
//     `findingDetail(l, f)` read them;
//   * canonical PRV wording: title "Irregular pulse pattern flagged"; body
//     begins "Your beat-to-beat pulse timing looked irregular today. This screen
//     uses the wrist pulse, which can't show the heart's electrical activity,
//     and is not a diagnosis."; flag values flagged / not flagged / not screened
//     (never "clear" / "raised");
//   * the reverse-engineered rate mapping is stated as such, in every locale;
//   * every new string exists in en/de/es/fr/hi/zh (parity against the key list
//     at the start of this phase: support/arb_baseline_keys.txt);
//   * BANNED CLAIMS (R5' scope, exactly): ECG category / outcome / reason
//     strings, ECG screener content, ECG/PRV finding and notification strings,
//     the Rhythm strip and Nerd-stats flag strings, and coach ECG tool / prompt
//     text - normal, healthy, clean, good recording, clear (as a verdict), too
//     much movement - across all six locales. "does not mean you were cleared"
//     stays.
//   * outdated "nothing is saved" / "replaces this one" wording is gone (every
//     attempt is kept now).
// Strings in tests use straight apostrophes, as the design text does.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/ecg/ecg_screener.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/app_localizations_en.dart';

import 'support/cardio_fixtures.dart' show codeOf;

const _locales = ['en', 'de', 'es', 'fr', 'hi', 'zh'];

Map<String, dynamic> _arb(String loc) =>
    jsonDecode(File('lib/l10n/app_$loc.arb').readAsStringSync()) as Map<String, dynamic>;

final Set<String> _baseline = File('test/ecg_transparency/support/arb_baseline_keys.txt')
    .readAsLinesSync()
    .where((l) => l.isNotEmpty)
    .toSet();

/// Keys Phase 1 added to the English template.
List<String> _newKeys() => [
  for (final k in _arb('en').keys)
    if (!k.startsWith('@') && !_baseline.contains(k)) k,
]..sort();

AppLocalizations _l(String loc) => lookupAppLocalizations(Locale(loc));

/// Banned claims, per locale (best-effort translations of the English six; the
/// English set is also applied to every locale to catch untranslated copies).
const Map<String, List<String>> _bannedLocal = {
  'de': ['normal', 'gesund', 'sauber', 'gute aufnahme', 'zu viel bewegung'],
  'es': ['normal', 'saludable', 'limpi', 'buena grabaci', 'demasiado movimiento'],
  'fr': ['normal', 'en bonne sant', 'propre', 'bon enregistrement', 'trop de mouvement'],
  'hi': ['सामान्य', 'स्वस्थ', 'साफ', 'अच्छी रिकॉर्डिंग'],
  'zh': ['正常', '健康', '干净', '清晰', '良好', '过多运动', '动作过多'],
};

final _bannedEn = RegExp(
  r'\bnormal\b|\bhealthy\b|\bclean\b|good recording|\bclear\b|too much movement',
  caseSensitive: false,
);

List<String> _banned(String loc, String text) {
  final t = text.toLowerCase();
  return [
    for (final m in _bannedEn.allMatches(t)) m.group(0)!,
    for (final w in _bannedLocal[loc] ?? const <String>[])
      if (t.contains(w)) w,
  ];
}

/// The string literals of a Dart source (code lines only).
List<String> _literals(String code) => [
  for (final m in RegExp(r"'((?:[^'\\\n]|\\.)*)'").allMatches(code)) m.group(1)!,
  for (final m in RegExp(r'"((?:[^"\\\n]|\\.)*)"').allMatches(code)) m.group(1)!,
];

void main() {
  group('ARBs: every new string in all six locales', () {
    test('Phase 1 added strings at all', () {
      expect(_newKeys(), isNotEmpty);
    });

    for (final loc in _locales.where((l) => l != 'en')) {
      test('$loc has every new key, non-empty, with the same placeholders', () {
        expect(_newKeys(), isNotEmpty);
        final en = _arb('en');
        final other = _arb(loc);
        for (final k in _newKeys()) {
          expect(other[k], isA<String>(), reason: '$k missing in app_$loc.arb');
          expect((other[k] as String).trim(), isNotEmpty, reason: '$loc $k');
          final ph = RegExp(r'\{(\w+)[,}]');
          Set<String> names(String s) => {for (final m in ph.allMatches(s)) m[1]!};
          expect(names(other[k] as String), names(en[k] as String),
              reason: '$loc $k placeholders');
        }
      });

      test('$loc is translated, not a copy of the English (strings of 3+ words)',
          () {
        expect(_newKeys(), isNotEmpty);
        final en = _arb('en');
        final other = _arb(loc);
        final copied = [
          for (final k in _newKeys())
            if ((en[k] as String).trim().split(RegExp(r'\s+')).length >= 3 &&
                other[k] == en[k])
              k,
        ];
        expect(copied, isEmpty);
      });
    }
  });

  group('the strings the new screens show come from the ARBs, not from '
      'fallback literals', () {
    // Each phrase must be (the start of) the value of a key Phase 1 added, with
    // placeholders written as {name}. The widget tests read them rendered.
    final phrases = <String, RegExp>{
      'Export ECG logs': RegExp(r'^Export ECG logs$'),
      'Not readable': RegExp(r'^Not readable'),
      "Couldn't save the ECG log: <reason>":
          RegExp(r"^Couldn't save the ECG log: \{\w+\}$"),
      'Delete this reading?': RegExp(r'^Delete this reading\?$'),
      'Delete this reading and all N attempts?':
          RegExp(r'^Delete this reading and all \{\w+\} attempts\?$|^Delete this reading and all \{\w+, plural'),
      'Waveform not kept': RegExp(r'^Waveform not kept$'),
      'No rhythm reading to analyze — <reason>':
          RegExp(r'^No rhythm reading to analyze — \{\w+\}$'),
      'Details': RegExp(r'^Details$'),
      'not recorded': RegExp(r'^not recorded$'),
      'Irregular pulse pattern flagged': RegExp(r'^Irregular pulse pattern flagged$'),
    };
    for (final e in phrases.entries) {
      test(e.key, () {
        final en = _arb('en');
        final hit = [
          for (final k in _newKeys())
            if (en[k] is String && e.value.hasMatch(en[k] as String)) k,
        ];
        expect(hit, isNotEmpty);
      });
    }
  });

  group('banned claims, R5\' scope, all six locales', () {
    for (final loc in _locales) {
      test('$loc: new strings and every ecg*/rhythm-strip/flag string are free '
          'of them', () {
        final arb = _arb(loc);
        final scope = {
          ..._newKeys(),
          for (final k in arb.keys)
            if (!k.startsWith('@') &&
                (k.startsWith('ecg') ||
                    k.startsWith('investigateFlag') ||
                    k == 'investigateRhythmStripFootnote' ||
                    k.startsWith('investigateIrregularRhythm')))
              k,
        };
        final hits = <String>[];
        for (final k in scope) {
          final v = arb[k];
          if (v is! String) continue;
          final b = _banned(loc, v);
          if (b.isNotEmpty) hits.add('$k: $b');
        }
        expect(hits, isEmpty);
      });
    }

    test('the sources behind the same scope (literals and fallbacks), English',
        () {
      String between(String code, String from, String to) {
        final i = code.indexOf(from);
        final j = code.indexOf(to, i + from.length);
        expect(i, greaterThanOrEqualTo(0), reason: from);
        return code.substring(i, j < 0 ? code.length : j);
      }

      final investigate = codeOf('lib/ui2/screens/investigate.dart');
      final coachActions = codeOf('lib/coach/coach_actions.dart');
      final prompt = codeOf('lib/coach/coach_prompt.dart');
      final engine = codeOf('lib/coach/coach_engine.dart');
      final sources = <String, String>{
        'lib/ui2/screens/ecg.dart': codeOf('lib/ui2/screens/ecg.dart'),
        'lib/ui2/screens/ecg_screener.dart': codeOf('lib/ui2/screens/ecg_screener.dart'),
        'lib/ecg/ecg_screener.dart': codeOf('lib/ecg/ecg_screener.dart'),
        'lib/compute/findings.dart': codeOf('lib/compute/findings.dart'),
        'investigate.dart flags': between(
          investigate,
          'investigateIrregularRhythmFlagSleep',
          'investigateDecelerationCapacity',
        ),
        'investigate.dart strip footnote': between(
          investigate,
          'investigateRhythmStripFootnote(',
          'ChartScrub(',
        ),
        'coach_actions.dart ECG': between(coachActions, 'ecgReading(Database', '// ── nutrition'),
        'coach_prompt.dart ECG': between(prompt, '7. ECG READINGS', "# DON'T RESTATE THE APP"),
        'coach_engine.dart get_ecg_reading': between(engine, "_fn('get_ecg_reading'", "_fn('log_food'"),
      };
      final hits = <String>[];
      for (final e in sources.entries) {
        final text = e.key.startsWith('coach_prompt') ? e.value : _literals(e.value).join('\n');
        for (final b in _banned('en', text)) {
          hits.add('${e.key}: $b');
        }
      }
      expect(hits, isEmpty);
    });
  });

  group('the screener content moves to the ARBs', () {
    test('lib/ecg/ecg_screener.dart holds no English prose any more', () {
      final prose = [
        for (final s in _literals(codeOf('lib/ecg/ecg_screener.dart')))
          if (s.trim().split(RegExp(r'\s+')).length >= 4) s,
      ];
      expect(prose, isEmpty);
    });

    for (final loc in ['de', 'es', 'fr', 'hi', 'zh']) {
      test('$loc: every entry and the intro are read in that language', () {
        final en = ecgScreenerEntries(AppLocalizationsEn());
        final other = ecgScreenerEntries(_l(loc));
        expect([for (final e in other) e.id], [for (final e in en) e.id]);
        for (var i = 0; i < en.length; i++) {
          expect(other[i].title, isNot(en[i].title), reason: '$loc ${en[i].id} title');
          expect(other[i].meaning, isNot(en[i].meaning), reason: '$loc ${en[i].id} meaning');
          expect(other[i].screened, en[i].screened);
        }
        expect(ecgScreenerIntro(_l(loc)), isNot(ecgScreenerIntro(AppLocalizationsEn())));
      });
    }

    test('English: the states still say "not screened" for the three that '
        'were not, and "does not mean you were cleared" where nothing was '
        'flagged', () {
      final es = ecgScreenerEntries(AppLocalizationsEn());
      for (final id in ['unreadable', 'partial', 'failed']) {
        final e = es.singleWhere((e) => e.id == id);
        expect('${e.title} ${e.meaning}'.toLowerCase(), contains('not screened'), reason: id);
      }
      for (final id in ['sinusRhythm', 'highHeartRateNoAfib']) {
        final e = es.singleWhere((e) => e.id == id);
        expect(e.meaning.toLowerCase(), contains('does not mean you were cleared'), reason: id);
        expect(e.meaning.toLowerCase(), contains('cannot rule anything out'), reason: id);
      }
    });

    test('English: no outdated "nothing is saved" (unreadable and inconclusive '
        'attempts ARE kept now) and no "replaces this one"', () {
      final es = ecgScreenerEntries(AppLocalizationsEn());
      for (final id in ['unreadable', 'inconclusive']) {
        final e = es.singleWhere((e) => e.id == id);
        expect(e.meaning.toLowerCase(), isNot(contains('nothing is saved')), reason: id);
      }
      for (final e in es) {
        expect(e.meaning.toLowerCase(), isNot(contains('replaces this one')), reason: e.id);
      }
      expect(AppLocalizationsEn().ecgInconclusiveRetryHint.toLowerCase(),
          isNot(contains('replaces')));
    });

    test('English: no screened state calls the recording good or clean', () {
      for (final e in ecgScreenerEntries(AppLocalizationsEn())) {
        expect(e.meaning.toLowerCase(), isNot(contains('good recording')), reason: e.id);
        expect(e.meaning.toLowerCase(), isNot(contains('was clean')), reason: e.id);
      }
    });
  });

  group('the rate mapping is the app\'s reverse-engineered reading', () {
    test('a new string states 51-99 / 100-150 / 151-200 and "not from a '
        'validation of this device"; every locale keeps the numbers', () {
      final en = _arb('en');
      final key = _newKeys().where((k) {
        final v = (en[k] as String).toLowerCase();
        return v.contains('validation of this device');
      }).toList();
      expect(key, hasLength(1));
      final v = (en[key.single] as String).toLowerCase();
      expect(v, contains('51–99 bpm'));
      expect(v, contains('100–150 bpm'));
      expect(v, contains('151–200 bpm'));
      expect(v, contains("the band's codes"));
      for (final loc in _locales) {
        final t = _arb(loc)[key.single] as String;
        for (final n in ['51', '99', '100', '150', '151', '200']) {
          expect(t, contains(n), reason: '$loc $n');
        }
      }
    });
  });

  group('PRV wording (canonical)', () {
    final irregular = const Finding(FindingKind.irregularRhythm, '2026-10-07');
    final en = AppLocalizationsEn();

    test('English title and body', () {
      expect(findingTitle(en, irregular), 'Irregular pulse pattern flagged');
      expect(
        findingDetail(en, irregular),
        startsWith(
          "Your beat-to-beat pulse timing looked irregular today. This screen "
          "uses the wrist pulse, which can't show the heart's electrical "
          "activity, and is not a diagnosis.",
        ),
      );
    });

    test('the other five titles are unchanged, now read from the ARBs', () {
      expect(findingTitle(en, const Finding(FindingKind.illness, 'd')), 'Possible illness onset');
      expect(findingTitle(en, const Finding(FindingKind.anomaly, 'd')), 'Unusual overnight readings');
      expect(findingTitle(en, const Finding(FindingKind.tempElevated, 'd')), 'Skin temperature elevated');
      expect(findingTitle(en, const Finding(FindingKind.lowReadiness, 'd')), 'Low readiness today');
      expect(findingTitle(en, const Finding(FindingKind.rhrShift, 'd')),
          'Your resting heart-rate trend shifted');
    });

    for (final loc in ['de', 'es', 'fr', 'hi', 'zh']) {
      test('$loc: every finding title is translated', () {
        final l = _l(loc);
        for (final k in FindingKind.values) {
          final f = Finding(k, 'd');
          expect(findingTitle(l, f), isNot(findingTitle(en, f)), reason: '$loc $k');
          expect(findingTitle(l, f).trim(), isNotEmpty);
        }
        expect(findingDetail(l, irregular), isNot(findingDetail(en, irregular)));
      });
    }

    test('no surface still says "Irregular heart rhythm flagged"', () {
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !(e.path.endsWith('.dart') || e.path.endsWith('.arb'))) continue;
        if (e.path.contains('app_localizations')) continue;
        expect(e.readAsStringSync().contains('Irregular heart rhythm flagged'), isFalse,
            reason: e.path);
      }
    });

    test('titles come from findingTitle everywhere: the Finding type holds no '
        'English, the log and the notification call the function', () {
      final f = codeOf('lib/compute/findings.dart');
      expect(f.contains('String get title'), isFalse);
      expect(f.contains('String get detail'), isFalse);
      for (final t in ['Possible illness onset', 'Unusual overnight readings',
          'Skin temperature elevated', 'Low readiness today',
          'Your resting heart-rate trend shifted']) {
        expect(f.contains(t), isFalse, reason: t);
      }
      final log = codeOf('lib/ui2/screens/findings_log.dart');
      expect(log.contains('findingTitle('), isTrue);
      expect(log.contains('findingDetail('), isTrue);
      expect(log.contains('f.title'), isFalse);
      final eng = codeOf('lib/compute/derivation_engine.dart');
      expect(eng.contains('findings.first.title'), isFalse);
      expect(eng.contains('findingTitle('), isTrue);
    });
  });

  group('the flag values (Nerd stats, Rhythm strip)', () {
    // The three words, found by their English value so a renamed key still
    // counts; every locale must carry three different, non-empty ones.
    List<String> keysFor(String word) {
      final en = _arb('en');
      return [
        for (final k in {..._newKeys(), ...en.keys.where((k) => k.startsWith('investigateFlag'))})
          if (en[k] == word) k,
      ];
    }

    test('English: the words are flagged / not flagged / not screened, and '
        '"raised" / "clear" are no flag value any more', () {
      for (final w in ['flagged', 'not flagged', 'not screened']) {
        expect(keysFor(w), isNotEmpty, reason: w);
      }
      final en = _arb('en');
      for (final k in en.keys.where((k) => k.startsWith('investigateFlag'))) {
        expect(en[k], isNot('raised'), reason: k);
        expect(en[k], isNot('clear'), reason: k);
      }
    });

    test('the source has no fallback that says "clear" or "raised"', () {
      final inv = codeOf('lib/ui2/screens/investigate.dart');
      expect(inv.contains("?? 'clear'"), isFalse);
      expect(inv.contains("?? 'raised'"), isFalse);
      expect(inv.contains('A clear strip'), isFalse);
    });

    for (final loc in ['de', 'es', 'fr', 'hi', 'zh']) {
      test('$loc: three different flag words, not the English ones', () {
        final arb = _arb(loc);
        final words = <String>[];
        for (final w in ['flagged', 'not flagged', 'not screened']) {
          final ks = keysFor(w);
          expect(ks, isNotEmpty, reason: w);
          final v = arb[ks.first];
          expect(v, isA<String>(), reason: '$loc ${ks.first}');
          expect((v as String).trim(), isNotEmpty);
          expect(v, isNot(w), reason: '$loc $w is translated');
          words.add(v);
        }
        expect(words.toSet().length, 3, reason: '$loc: $words');
      });
    }
  });

  group('the lexicon (AGENTS 6: a new term lands with the change)', () {
    test('Attempt, Attempt group, Superseded and ECG outcome are defined', () {
      final lex = File('docs/lexicon.md').readAsStringSync();
      for (final term in ['Attempt', 'Attempt group', 'Superseded', 'ECG outcome']) {
        expect(lex.contains('**$term**'), isTrue, reason: term);
      }
    });
  });
}
