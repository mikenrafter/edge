// The recorded day and limits must survive localization and the shared row.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/app_localizations_en.dart';
import 'package:openstrap_edge/ui2/screens/findings_log.dart';

void main() {
  // why: Observations and Health both render FindingRow; past dates cannot say today.
  testWidgets('past-day row and detail name the recorded day', (t) async {
    const f = Finding(FindingKind.irregularRhythm, '2026-11-12');
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: FindingRow(f))));
    final text = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .join('\n');
    expect(text, contains('on Thu 12 Nov 2026'));
    expect(text, contains('On Thu 12 Nov 2026'));
    expect(text.toLowerCase(), isNot(contains('today')));
    final detail = findingDetail(AppLocalizationsEn(), f);
    for (final phrase in [
      'have not measured how often',
      'how often it misses',
      'Movement, sensor fit, and extra beats',
      'cannot identify atrial fibrillation',
      'cannot rule out a rhythm problem',
      'clinician can use an ECG',
      'even without symptoms',
    ]) {
      expect(detail, contains(phrase));
    }
  });

  // why: generated localizations must retain the day argument and honest quality labels.
  test('all seven locales carry dates and translated limits', () {
    const todayWords = [
      'today',
      'heute',
      'hoy',
      'aujourd’hui',
      'сегодня',
      'आज',
      '今天',
    ];
    expect(AppLocalizations.supportedLocales, hasLength(7));
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      const f = Finding(FindingKind.irregularRhythm, '2026-11-12');
      for (final text in [
        l.findingTitleIrregularRhythm('DAY'),
        l.findingDetailIrregularRhythm('DAY'),
        l.findingNotificationIrregularRhythm('DAY'),
      ]) {
        expect(text, contains('DAY'), reason: locale.toString());
        for (final word in todayWords) {
          expect(
            text.toLowerCase(),
            isNot(contains(word)),
            reason: locale.toString(),
          );
        }
      }
      expect(findingTitle(l, f), isNotEmpty);
      final arb =
          jsonDecode(
                File(
                  'lib/l10n/app_${locale.languageCode}.arb',
                ).readAsStringSync(),
              )
              as Map;
      for (final key in [
        'findingTitleIrregularRhythm',
        'findingDetailIrregularRhythm',
        'findingNotificationIrregularRhythm',
        'investigatePrvArtifactShare',
        'investigateConfidence24h',
        'investigateConfidenceSleep',
      ]) {
        expect(arb[key], isA<String>(), reason: '$locale $key');
        if (locale.languageCode != 'en') {
          final en =
              jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map;
          expect(
            arb[key],
            isNot(en[key]),
            reason: '$locale $key must be translated',
          );
        }
      }
      expect(
        l.investigateConfidence24h.toLowerCase(),
        isNot(contains('confidence')),
      );
    }
  });
}
