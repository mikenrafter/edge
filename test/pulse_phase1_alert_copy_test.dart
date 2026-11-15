// The copy around a flagged day's alert: the summary notification and the
// small record text under the day, in every locale.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/compute/pulse_alert_record.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/app_localizations_en.dart';
import 'package:openstrap_edge/ui2/screens/findings_log.dart';

void main() {
  // why: the summary and the per-day record are new copy: every locale must
  // carry them, translated, with their numbers and dates in place.
  test('summary and alert-record strings exist in all seven locales', () {
    final en = AppLocalizationsEn();
    expect(en.pulseSummaryTitle(1), 'Irregular pulse flag found on 1 earlier day');
    expect(en.pulseSummaryTitle(3), 'Irregular pulse flags found on 3 earlier days');
    expect(en.pulseAlertOff, 'No alert: notifications were off');
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      final code = locale.languageCode;
      for (final n in [1, 2, 5, 21]) {
        expect(l.pulseSummaryTitle(n), contains('$n'), reason: '$code $n');
      }
      expect(l.pulseSummaryBody('DAYS'), contains('DAYS'), reason: code);
      expect(l.pulseSummaryDaysMore('DAYS', 7), allOf(contains('DAYS'), contains('7')));
      expect(l.pulseAlertSent('WHEN'), contains('WHEN'), reason: code);
      expect(l.pulseAlertInSummary('WHEN'), contains('WHEN'), reason: code);
      expect(l.pulseAlertOff, isNotEmpty);
      expect(l.pulseAlertNotPermitted, isNot(l.pulseAlertOff));
      if (code != 'en') {
        expect(l.pulseSummaryTitle(3), isNot(en.pulseSummaryTitle(3)), reason: code);
        expect(l.pulseSummaryBody('D'), isNot(en.pulseSummaryBody('D')), reason: code);
        expect(l.pulseAlertSent('W'), isNot(en.pulseAlertSent('W')), reason: code);
        expect(l.pulseAlertInSummary('W'), isNot(en.pulseAlertInSummary('W')), reason: code);
        expect(l.pulseAlertOff, isNot(en.pulseAlertOff), reason: code);
        expect(l.pulseAlertNotPermitted, isNot(en.pulseAlertNotPermitted), reason: code);
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
  });
}
