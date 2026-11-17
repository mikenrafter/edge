// The copy around a flagged day's alert: the summary notification and the
// small record text under the day, in every locale.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/compute/pulse_alert_record.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/app_localizations_en.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/screens/findings_log.dart';

void main() {
  // The app's own clock setting decides how the record's time reads.
  setUp(() => ClockFormatController.seed(ClockFormat.h24));
  tearDown(ClockFormatController.debugReset);

  // The singular and plural markers each locale's summary body must carry, and
  // the word for "earlier" it must not: today can be in the list.
  const singular = {
    'en': 'this day', 'de': 'diesem Tag', 'es': 'este día', 'fr': 'ce jour',
    'hi': 'इस दिन', 'ru': 'этот день', 'zh': '这一天', 'th': 'วันที่ระบุนี้',
  };
  const plural = {
    'en': 'these days', 'de': 'diesen Tagen', 'es': 'estos días', 'fr': 'ces jours',
    'hi': 'इन दिनों', 'ru': 'эти дни', 'zh': '这些天', 'th': 'วันเหล่านี้',
  };
  const earlier = {
    'en': 'earlier', 'de': 'früher', 'es': 'anterior', 'fr': 'antérieur',
    'hi': 'पिछले', 'ru': 'ранн', 'zh': '之前', 'th': 'ก่อนหน้า',
  };

  // why: R2-W1. Render every case in every locale: one day, two, five and
  // twenty-one, title and body, with today possibly in the list.
  // proves: CLAIM(pulse-summary-copy); catches: "earlier" for today, "these
  // days" for one day, an untranslated string, a lost count.
  test('the summary reads right for one day and for several, in all locales', () {
    final en = AppLocalizationsEn();
    expect(en.pulseSummaryTitle(1), 'Irregular pulse flag found on 1 day');
    expect(en.pulseSummaryTitle(3), 'Irregular pulse flags found on 3 days');
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      final code = locale.languageCode;
      for (final n in [1, 2, 5, 21]) {
        final title = l.pulseSummaryTitle(n);
        final body = l.pulseSummaryBody(n, 'DAYS');
        expect(title, contains('$n'), reason: '$code $n title');
        expect(body, startsWith('DAYS'), reason: '$code $n body');
        expect(title + body, isNot(contains(earlier[code]!)), reason: '$code $n');
        expect(
          body,
          contains(n == 1 || (code == 'ru' && n == 21) ? singular[code]! : plural[code]!),
          reason: '$code $n',
        );
        if (!(n == 1 || (code == 'ru' && n == 21))) {
          expect(body, isNot(contains(singular[code]!)), reason: '$code $n');
        }
      }
      expect(l.pulseSummaryDaysMore('DAYS', 7), allOf(contains('DAYS'), contains('7')));
      expect(l.pulseAlertSent('WHEN'), contains('WHEN'), reason: code);
      expect(l.pulseAlertInSummary('WHEN'), contains('WHEN'), reason: code);
      expect(l.pulseAlertUnknown('WHEN'), contains('WHEN'), reason: code);
      expect(l.pulseAlertEarlier('WHEN'), contains('WHEN'), reason: code);
      final notes = {
        l.pulseAlertOff, l.pulseAlertNotPermitted, l.pulseAlertQuiet,
        l.pulseAlertSent('W'), l.pulseAlertInSummary('W'),
        l.pulseAlertUnknown('W'), l.pulseAlertEarlier('W'),
      };
      expect(notes, hasLength(7), reason: '$code: every record note is distinct');
      if (code != 'en') {
        expect(l.pulseSummaryTitle(3), isNot(en.pulseSummaryTitle(3)), reason: code);
        expect(l.pulseSummaryBody(3, 'D'), isNot(en.pulseSummaryBody(3, 'D')), reason: code);
        for (final n in notes) {
          expect(n, isNot(isIn({
            en.pulseAlertOff, en.pulseAlertNotPermitted, en.pulseAlertQuiet,
            en.pulseAlertSent('W'), en.pulseAlertInSummary('W'),
            en.pulseAlertUnknown('W'), en.pulseAlertEarlier('W'),
          })), reason: '$code $n untranslated');
        }
      }
    }
  });

  // why: rule 4. The record shows on the Observations row, in small text.
  testWidgets('FindingRow shows what became of the alert', (t) async {
    final at = DateTime(2026, 11, 14, 8, 14).millisecondsSinceEpoch;
    Future<String> textOf(PulseAlertRecord? alert) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FindingRow(
            Finding(FindingKind.irregularRhythm, '2026-11-12', alert: alert),
          ),
        ),
      ));
      return t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').join('\n');
    }

    expect(await textOf(null), isNot(contains('lert')));
    expect(
      await textOf(PulseAlertRecord(PulseAlertState.sent, at)),
      contains('Alert sent Sat, Nov 14 08:14'),
    );
    expect(
      await textOf(PulseAlertRecord(PulseAlertState.summary, at)),
      contains('Included in a summary alert Sat, Nov 14 08:14'),
    );
    expect(
      await textOf(PulseAlertRecord(PulseAlertState.notSent, at, reason: PulseAlertReason.off)),
      contains('No alert: notifications were off'),
    );
    expect(
      await textOf(PulseAlertRecord(PulseAlertState.notSent, at, reason: PulseAlertReason.blocked)),
      contains('No alert: notifications were not permitted'),
    );
    expect(
      await textOf(PulseAlertRecord(PulseAlertState.notSent, at, reason: PulseAlertReason.quiet)),
      contains('No alert: held for quiet hours'),
    );
    expect(
      await textOf(PulseAlertRecord(PulseAlertState.unknown, at)),
      contains('Alert may have been sent Sat, Nov 14 08:14'),
    );
    expect(
      await textOf(PulseAlertRecord(PulseAlertState.earlier, at)),
      contains('Alerted by an earlier version of the app Sat, Nov 14 08:14'),
    );
    // A claim still in flight is not shown at all.
    expect(await textOf(PulseAlertRecord(PulseAlertState.pending, at)), isNot(contains('lert')));
  });

  // why: R2-W3. The time follows the app's 12/24 h setting, not the locale's.
  testWidgets('the record time follows the app clock setting', (t) async {
    final at = DateTime(2026, 11, 14, 20, 14).millisecondsSinceEpoch;
    Future<String> textOf() async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FindingRow(Finding(FindingKind.irregularRhythm, '2026-11-12',
              alert: PulseAlertRecord(PulseAlertState.sent, at))),
        ),
      ));
      return t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').join('\n');
    }
    ClockFormatController.seed(ClockFormat.h24);
    expect(await textOf(), contains('Alert sent Sat, Nov 14 20:14'));
    ClockFormatController.seed(ClockFormat.h12);
    expect(await textOf(), contains('Alert sent Sat, Nov 14 8:14 PM'));
    ClockFormatController.debugReset();
  });
}
