// The Symptom describer's vocabulary and wording (RED).
//
// Answering Symptom on a marked moment describes it: severity, an optional
// side, a kind and a body area. Rendered "<severity> <kind> in my <area>
// (<side>)": the side goes in parentheses after the area so it never has to
// agree with the area's number ("mild pain in my knees (left)"), and is omitted
// when unset. Ids are persisted, so they are pinned
// exactly; the wording lives in ARB keys (English required here; de, es, fr,
// hi and zh follow, falling back to English until then).
//
// Nothing is derived from a symptom: there is no score, metric or correlation
// input in this model, and the tests below pin that by what the type does NOT
// carry.

import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/gestures/symptom_description.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';

List<String> _ids(Iterable<dynamic> v) => [for (final e in v) e.id as String];

SymptomDescription _d({
  SymptomSeverity severity = SymptomSeverity.moderate,
  SymptomSide? side,
  SymptomKind kind = SymptomKind.pain,
  String? kindOther,
  SymptomArea area = SymptomArea.knees,
  String? areaOther,
  String? note,
}) =>
    SymptomDescription(
        severity: severity,
        side: side,
        kind: kind,
        kindOther: kindOther,
        area: area,
        areaOther: areaOther,
        note: note);

void main() {
  group('persisted ids, in the order the describer offers them', () {
    test('severity: severe, moderate, mild, faint', () {
      expect(_ids(SymptomSeverity.values),
          ['severe', 'moderate', 'mild', 'faint']);
    });

    test('side: left, right, both, center, all', () {
      expect(_ids(SymptomSide.values),
          ['left', 'right', 'both', 'center', 'all']);
    });

    test('kind: pain .. tingling, then other', () {
      expect(_ids(SymptomKind.values), [
        'pain',
        'swelling',
        'itchiness',
        'irritation',
        'numbness',
        'soreness',
        'tingling',
        'other',
      ]);
    });

    test('area: body order low to high, then other', () {
      expect(_ids(SymptomArea.values), [
        'feet',
        'ankles',
        'calves',
        'knees',
        'thighs',
        'hips',
        'glutes',
        'lower_abdomen',
        'lower_back',
        'upper_abdomen',
        'mid_back',
        'chest',
        'upper_back',
        'shoulders',
        'arms',
        'elbows',
        'wrists',
        'hands',
        'neck',
        'jaw',
        'face',
        'forehead',
        'skull',
        'other',
      ]);
    });
  });

  group('the sentence', () {
    test('with a side', () {
      expect(_d(side: SymptomSide.left).describe(null),
          'moderate pain in my knees (left)');
      expect(
          _d(
                  severity: SymptomSeverity.severe,
                  side: SymptomSide.right,
                  kind: SymptomKind.numbness,
                  area: SymptomArea.hands)
              .describe(null),
          'severe numbness in my hands (right)');
      expect(
          _d(
                  severity: SymptomSeverity.faint,
                  side: SymptomSide.center,
                  kind: SymptomKind.tingling,
                  area: SymptomArea.chest)
              .describe(null),
          'faint tingling in my chest (center)');
    });

    test('side unset: the side is omitted, with no double space', () {
      expect(
          _d(
                  severity: SymptomSeverity.mild,
                  kind: SymptomKind.itchiness,
                  area: SymptomArea.neck)
              .describe(null),
          'mild itchiness in my neck');
    });

    test('both and all read naturally in the parenthesis', () {
      expect(_d(side: SymptomSide.both).describe(null),
          'moderate pain in my knees (both)');
      expect(_d(side: SymptomSide.all).describe(null),
          'moderate pain in my knees (all)');
    });

    test('multi-word areas read as words, never ids', () {
      final s = _d(area: SymptomArea.lowerBack).describe(null);
      expect(s, 'moderate pain in my lower back');
      expect(s.contains('_'), isFalse);
      expect(_d(area: SymptomArea.upperAbdomen).describe(null),
          'moderate pain in my upper abdomen');
    });

    test('other kind and other area use the typed text, trimmed', () {
      expect(
          _d(
                  severity: SymptomSeverity.severe,
                  side: SymptomSide.right,
                  kind: SymptomKind.other,
                  kindOther: '  burning ',
                  area: SymptomArea.other,
                  areaOther: ' big toe')
              .describe(null),
          'severe burning in my big toe (right)');
    });

    test('the optional note is not part of the sentence', () {
      expect(_d(note: 'after the run').describe(null),
          'moderate pain in my knees');
    });

    test('every kind and area renders something non-empty, in order, with no '
        'placeholder text', () {
      for (final k in SymptomKind.values.where((k) => k != SymptomKind.other)) {
        final s = _d(kind: k).describe(null);
        expect(s, contains(k.id));
      }
      for (final a in SymptomArea.values.where((a) => a != SymptomArea.other)) {
        expect(_d(area: a).describe(null).trim(), isNotEmpty);
        expect(_d(area: a).describe(null).contains('{'), isFalse);
      }
    });
  });

  group('localization', () {
    test('English comes from the generated localizations and matches the '
        'fallback', () {
      final l = lookupAppLocalizations(const Locale('en'));
      final d = _d(side: SymptomSide.left);
      expect(d.describe(l), 'moderate pain in my knees (left)');
      expect(d.describe(l), d.describe(null));
      expect(SymptomSeverity.faint.localized(l), 'faint');
      expect(SymptomSide.center.localized(l), 'center');
      expect(SymptomKind.itchiness.localized(l), 'itchiness');
      expect(SymptomArea.lowerBack.localized(l), 'lower back');
    });

    test('app_en.arb declares every preset and both sentence templates, each '
        'with a description', () {
      final arb = File('lib/l10n/app_en.arb').readAsStringSync();
      const keys = [
        'symptomSeveritySevere', 'symptomSeverityModerate',
        'symptomSeverityMild', 'symptomSeverityFaint',
        'symptomSideLeft', 'symptomSideRight', 'symptomSideBoth',
        'symptomSideCenter', 'symptomSideAll',
        'symptomKindPain', 'symptomKindSwelling', 'symptomKindItchiness',
        'symptomKindIrritation', 'symptomKindNumbness', 'symptomKindSoreness',
        'symptomKindTingling', 'symptomKindOther',
        'symptomAreaFeet', 'symptomAreaAnkles', 'symptomAreaCalves',
        'symptomAreaKnees', 'symptomAreaThighs', 'symptomAreaHips',
        'symptomAreaGlutes', 'symptomAreaLowerAbdomen', 'symptomAreaLowerBack',
        'symptomAreaUpperAbdomen', 'symptomAreaMidBack', 'symptomAreaChest',
        'symptomAreaUpperBack', 'symptomAreaShoulders', 'symptomAreaArms',
        'symptomAreaElbows', 'symptomAreaWrists', 'symptomAreaHands',
        'symptomAreaNeck', 'symptomAreaJaw', 'symptomAreaFace',
        'symptomAreaForehead', 'symptomAreaSkull', 'symptomAreaOther',
        'symptomDescription', 'symptomDescriptionSided',
      ];
      for (final k in keys) {
        expect(arb.contains('"$k":'), isTrue, reason: 'missing $k');
        expect(arb.contains('"@$k"'), isTrue, reason: 'missing @$k');
      }
    });

    test('the templates are the sentence with the side in parentheses', () {
      final arb = File('lib/l10n/app_en.arb').readAsStringSync();
      expect(arb.contains('"symptomDescription": "{severity} {kind} in my {area}"'),
          isTrue);
      expect(
          arb.contains(
              '"symptomDescriptionSided": "{severity} {kind} in my {area} ({side})"'),
          isTrue);
    });
  });

  group('every locale carries every new key (translated, not left to fall back)',
      () {
    test('de, es, fr, hi and zh declare the symptom keys, the assumed-water '
        'keys and the neutral Home card text', () {
      final en = File('lib/l10n/app_en.arb').readAsStringSync();
      final keys = RegExp(r'^  "((?:symptom|assumedWater|settingsWaterAssume|'
              r'waterIncludesAssumed|journalComposeSymptoms)[A-Za-z]*)":',
              multiLine: true)
          .allMatches(en)
          .map((m) => m[1]!)
          .toList();
      expect(keys.length, greaterThan(50));
      for (final loc in ['de', 'es', 'fr', 'hi', 'zh']) {
        final arb = File('lib/l10n/app_$loc.arb').readAsStringSync();
        for (final k in keys) {
          expect(arb.contains('"$k":'), isTrue, reason: '$loc is missing $k');
        }
        // Not the English text copied across.
        expect(arb.contains('"momentFollowUpCardTitle": "{n, plural, one{{n} thing to review'),
            isFalse,
            reason: '$loc card title is still English');
      }
    });
  });

  group('nothing is derived', () {
    test('the model carries what was said and nothing else (no score, '
        'no value, no weight)', () {
      // A description is constructible from the five things the wearer picks
      // or types and nothing else; there is no numeric field to feed a metric.
      const d = SymptomDescription(
          severity: SymptomSeverity.mild,
          kind: SymptomKind.pain,
          area: SymptomArea.knees);
      expect(d.side, isNull);
      expect(d.kindOther, isNull);
      expect(d.areaOther, isNull);
      expect(d.note, isNull);
    });
  });
}
