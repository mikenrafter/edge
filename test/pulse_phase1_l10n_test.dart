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
  // why: a legacy daily flag keeps its historical label; its detail names
  // the recorded day rather than implying an episode recording exists today.
  testWidgets('past-day row and detail name the recorded day', (t) async {
    const f = Finding(FindingKind.irregularRhythm, '2026-11-12');
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: FindingRow(f))));
    final text = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .join('\n');
    expect(find.text('Historical daily flag: episode recording unavailable'),
        findsOneWidget);
    expect(text, contains('On Thu, Nov 12, 2026'));
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

  // Thursday 2026-11-12 in each locale's own full-date pattern (CLDR yMMMEd),
  // written out by hand. The order and punctuation are the point: a fixed
  // English-order pattern put zh as "周四 12 11月 2026" and de without its dots.
  const dateOf = <String, String>{
    'en': 'Thu, Nov 12, 2026',
    'de': 'Do., 12. Nov. 2026',
    'es': 'jue, 12 nov 2026',
    'fr': 'jeu. 12 nov. 2026',
    'hi': 'गुरु, 12 नव॰ 2026',
    'ru': 'чт, 12 нояб. 2026 г.',
    'zh': '2026年11月12日周四',
  };

  // The Material delegates register their own date symbols, so a no-break space
  // (U+00A0 or U+202F) can differ between a bare lookup and a running app. The
  // order, abbreviations and punctuation are what this test pins.
  String norm(String s) => s.replaceAll(RegExp('[\u00A0\u202F]'), ' ');

  // why: W1/T4. The flagged day must read as a date in the reader's own
  // language and order, in the title, the detail and the notification body.
  // proves: CLAIM(pulse-dated); catches: a fixed pattern such as 'EEE d MMM y'.
  test('every locale renders the flagged day in its own date format', () {
    const f = Finding(FindingKind.irregularRhythm, '2026-11-12');
    expect(dateOf.keys.toSet(), {
      for (final l in AppLocalizations.supportedLocales) l.languageCode,
    });
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      final date = dateOf[locale.languageCode]!;
      expect(
        norm(findingTitle(l, f)),
        l.findingTitleIrregularRhythm(date),
        reason: '${locale.languageCode} title',
      );
      expect(
        norm(findingDetail(l, f)),
        l.findingDetailIrregularRhythm(date),
        reason: '${locale.languageCode} detail',
      );
      expect(
        norm(ExceptionNotice('2026-11-12', const [f]).body(l)),
        l.findingNotificationIrregularRhythm(date),
        reason: '${locale.languageCode} notification body',
      );
    }
    // The garble this replaces, spelled out for the one that broke worst.
    expect(
      norm(findingTitle(lookupAppLocalizations(const Locale('zh')), f)),
      contains('2026年11月12日'),
    );
  });

  // why: T4. FindingRow is the shared Health/Observations surface; it must
  // render the locale's date from the ambient locale, not only in English.
  testWidgets('FindingRow shows the date in the app locale', (t) async {
    const f = Finding(FindingKind.irregularRhythm, '2026-11-12');
    for (final locale in AppLocalizations.supportedLocales) {
      await t.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: FindingRow(f)),
        ),
      );
      await t.pumpAndSettle();
      final text = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .join('\n');
      expect(
        norm(text),
        contains(dateOf[locale.languageCode]!),
        reason: locale.languageCode,
      );
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
