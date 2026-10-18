// ECG features, phase 1 (RED): the content of the screener page and its link
// list. Pure Dart (lib/ecg/ecg_screener.dart, lib/ecg/ecg_links.dart).
//
// The rules are the ones in lib/ui2/screens/beats.dart's header: a SCREEN,
// never a diagnosis and never AF detection; no arrhythmia vocabulary; "not
// screened" distinct from "nothing flagged"; a result with nothing flagged
// never reads as being cleared. The owner spec bans diagnosis words
// user-facing, so there is NO exemption: the stem "diagnos" appears nowhere,
// the disclaimer included ("This is a screen, not a medical test").
//
// The links: every URL lives in ONE constant (kEcgLinks) that
// scripts/check_ecg_links.sh reads. Run the script to see they resolve (a unit
// test cannot: no network). This file pins the SHAPE: https only, unique,
// DOIs well formed, reputable hosts, every state has what it should.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_links.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_screener.dart';

/// Words that may not appear anywhere on the screener (lowercased matching).
const kBannedScreenerWords = [
  'afib',
  'a-fib',
  'atrial fibrillation',
  'fibrillation',
  'arrhythmia',
  'arrhythmic',
  'ectopy',
  'ectopic',
  'pvc',
  'you have',
  'normal rhythm',
  'no issues',
  'looks healthy',
  'abnormal',
  '% of beats',
  'low risk',
  'high risk',
  'mild',
  'moderate',
  'severe',
];

/// [text] lowercased. No phrase is exempt.
String forBanCheck(String text) => text.toLowerCase();

/// The banned things found in [text] (empty when clean), including the
/// stand-alone word "af" and any other use of "diagnos".
List<String> bannedIn(String text) {
  final t = forBanCheck(text);
  return [
    for (final w in kBannedScreenerWords)
      if (t.contains(w)) w,
    if (RegExp(r'\baf\b').hasMatch(t)) 'af',
    if (t.contains('diagnos')) 'diagnos',
  ];
}

final _allIds = {
  for (final c in EcgCategory.values) c.name,
  'partial',
  'failed',
};

void main() {
  group('the states', () {
    test('there is one entry for every band category plus partial and failed',
        () {
      final ids = [for (final e in ecgScreenerEntries()) e.id];
      expect(ids.toSet(), _allIds);
      expect(ids.toSet().length, ids.length, reason: 'no state twice');
    });

    test('every entry has a title and a plain-language meaning, titles unique',
        () {
      final es = ecgScreenerEntries();
      for (final e in es) {
        expect(e.title.trim(), isNotEmpty, reason: e.id);
        expect(e.meaning.trim().length, greaterThan(40), reason: e.id);
      }
      expect({for (final e in es) e.title}.length, es.length);
    });

    test('no title or meaning uses banned vocabulary (afib, atrial '
        'fibrillation, arrhythmia, diagnosis, "you have" ...)', () {
      for (final e in ecgScreenerEntries()) {
        expect(bannedIn(e.title), isEmpty, reason: '${e.id} title');
        expect(bannedIn(e.meaning), isEmpty, reason: '${e.id} meaning');
      }
    });

    test('the banned-word checker itself catches what it should', () {
      for (final bad in [
        'Possible AFib',
        'atrial fibrillation',
        'an arrhythmia',
        'AF detected',
        'This is a diagnosis',
        'you have a problem',
        'Normal rhythm',
      ]) {
        expect(bannedIn(bad), isNotEmpty, reason: bad);
      }
      // No exemption for the old disclaimer wording either.
      expect(bannedIn('This is a screen. It cannot diagnose a condition.'),
          contains('diagnos'));
      expect(bannedIn('The result is not a diagnosis.'), contains('diagnos'));
      expect(bannedIn('This is a screen, not a medical test.'), isEmpty);
    });

    test('"not screened" is its own thing: the states where nothing was '
        'screened say so, and no screened state says it', () {
      final notScreened = {'unreadable', 'partial', 'failed'};
      for (final e in ecgScreenerEntries()) {
        final text = '${e.title} ${e.meaning}'.toLowerCase();
        if (notScreened.contains(e.id)) {
          expect(e.screened, isFalse, reason: e.id);
          expect(text, contains('not screened'), reason: e.id);
        } else {
          expect(e.screened, isTrue, reason: e.id);
          expect(text, isNot(contains('not screened')), reason: e.id);
        }
      }
    });

    test('a state with nothing flagged never reads as cleared: it says it '
        'does not mean you were cleared', () {
      for (final id in ['sinusRhythm', 'highHeartRateNoAfib']) {
        final e = ecgScreenerEntries().singleWhere((e) => e.id == id);
        final text = e.meaning.toLowerCase();
        expect(text, contains('does not mean you were cleared'), reason: id);
        expect(text, contains('cannot rule anything out'), reason: id);
      }
    });

    test('a flagged state ends in a person, not a number', () {
      for (final id in ['possibleAfib', 'afibHighHeartRate']) {
        final e = ecgScreenerEntries().singleWhere((e) => e.id == id);
        expect(e.meaning.toLowerCase(), contains('clinician'), reason: id);
      }
    });

    test('no title copies the band\'s own category wording', () {
      const bandWords = [
        'possible afib',
        'afib with high heart rate',
        'no afib detected',
        'sinus rhythm', // the band's label; the screener says what it means
      ];
      for (final e in ecgScreenerEntries()) {
        for (final w in bandWords) {
          expect(e.title.toLowerCase(), isNot(contains(w)), reason: e.id);
        }
      }
    });
  });

  group('the links', () {
    test('every link is https, well formed, and listed once', () {
      final seen = <String>{};
      for (final l in kEcgLinks) {
        expect(l.url, startsWith('https://'), reason: l.ref);
        expect(Uri.tryParse(l.url)?.hasAuthority, isTrue, reason: l.ref);
        expect(seen.add('${l.stateId}|${l.ref}'), isTrue,
            reason: 'duplicate ${l.stateId} ${l.ref}');
        if (l.isDoi) {
          expect(l.ref, matches(RegExp(r'^10\.\d{4,9}/\S+$')));
          expect(l.url, 'https://doi.org/${l.ref}');
        } else {
          expect(l.kind, 'layman');
          expect(l.url, l.ref);
        }
      }
    });

    test('layman links come only from reputable health sources', () {
      const hosts = {'medlineplus.gov', 'www.nhs.uk'};
      for (final l in kEcgLinks.where((l) => !l.isDoi)) {
        expect(hosts, contains(Uri.parse(l.url).host), reason: l.ref);
      }
    });

    test('every link belongs to a known state', () {
      for (final l in kEcgLinks) {
        expect(_allIds, contains(l.stateId), reason: l.ref);
      }
    });

    test('every band category has a DOI; every clinical one and inconclusive '
        'also has a plain-language page; partial and failed have none (no '
        'literature applies)', () {
      Set<String> statesOf(bool doi) => {
        for (final l in kEcgLinks)
          if (l.isDoi == doi) l.stateId,
      };
      expect(statesOf(true), {for (final c in EcgCategory.values) c.name});
      expect(statesOf(false), {
        'sinusRhythm',
        'lowHeartRate',
        'possibleAfib',
        'afibHighHeartRate',
        'highHeartRate',
        'highHeartRateNoAfib',
        'inconclusive',
      });
    });

    test('the screener entries and the link list agree on state ids', () {
      final entryIds = {for (final e in ecgScreenerEntries()) e.id};
      for (final l in kEcgLinks) {
        expect(entryIds, contains(l.stateId), reason: l.ref);
      }
    });
  });

  group('scripts/check_ecg_links.sh', () {
    final script = File('scripts/check_ecg_links.sh');

    test('exists, is executable and reads the one constant', () {
      expect(script.existsSync(), isTrue);
      expect(script.statSync().mode & 0x49, isNot(0), reason: 'executable');
      final text = script.readAsStringSync();
      expect(text, startsWith('#!'));
      expect(text, contains('lib/ecg/ecg_links.dart'));
      expect(text, contains('api.crossref.org/works'));
      expect(text, contains('curl'));
    });

    test('every EcgLink entry in the constant is on its own line in the shape '
        'the script greps, and the count matches kEcgLinks', () {
      final src = File('lib/ecg/ecg_links.dart').readAsLinesSync();
      final entry = RegExp(r"^\s*EcgLink\.(doi|layman)\('([^']+)', *'([^']+)'\),");
      final found = [for (final l in src) ?entry.firstMatch(l)];
      expect(found.length, kEcgLinks.length,
          reason: 'a link written in another shape would escape the check');
      expect({for (final m in found) '${m[2]}|${m[3]}'},
          {for (final l in kEcgLinks) '${l.stateId}|${l.ref}'});
    });
  });
}
