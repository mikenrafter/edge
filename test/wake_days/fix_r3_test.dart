import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/personal_day.dart';
import 'package:openstrap_edge/ui2/personal_day_widgets.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

DateTime t(int day, [int hour = 0, int minute = 0]) =>
    DateTime(2026, 11, day, hour, minute);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.reload();
  });

  // WHY / CLAIM(personal-open-cycle): an explicit last can collide with the
  // open date in either half of a noon-to-noon day. S1's noon stays unchanged.
  // catches: giving the date to the earliest closed cycle before the open one.
  for (final hour in [10, 14]) {
    test('calendar last reserves the open date at $hour', () {
      final days = personalDays(from: t(1, 12), until: t(3, hour, 1),
          sleeps: const [], mode: PersonalDayMode.calendarOffset,
          totals: PersonalDayTotals.last);
      expect(days.map((d) => d.scoreDay), hour == 10
          ? [null, '2026-11-02'] : ['2026-11-02', null, '2026-11-03']);
    });
  }

  // WHY / CLAIM(personal-open-cycle): an onset without a wake can start a new
  // cycle on the same score date as the previous one. The open cycle keeps it.
  // catches: fixing explicit overrides while still blanking an in-bed Home.
  test('onset-only sleep cycle keeps its date before midnight', () {
    final days = personalDays(from: t(1, 23), until: t(3, 23, 31),
        sleeps: [MainSleep(t(1, 23), t(2, 8)),
          MainSleep(t(2, 23), t(3, 8)), MainSleep(t(3, 23), null)],
        mode: PersonalDayMode.sleepToSleep);
    expect(days.map((d) => d.scoreDay), ['2026-11-02', null, '2026-11-03']);
  });

  // WHY: reserving the open date must leave an unrelated explicit first intact.
  // catches: replacing all closed first/last choices with majority dates.
  test('explicit first remains effective for closed sleep cycles', () {
    final days = personalDays(from: t(1, 23), until: t(3, 10, 1),
        sleeps: [MainSleep(t(1, 23), t(2, 8)), MainSleep(t(2, 23), t(3, 8))],
        mode: PersonalDayMode.sleepToSleep, totals: PersonalDayTotals.first);
    expect(days.map((d) => d.scoreDay), ['2026-11-01', '2026-11-03']);
  });

  // WHY: the totals control needs a persistent route back to the mode default,
  // even where default and explicit first/last have the same effective value.
  // catches: the old two-state toggle or a reset that stores an explicit value.
  for (final mode in [PersonalDayMode.wakeToWake, PersonalDayMode.sleepToSleep]) {
    testWidgets('${mode.name} totals cycles default, first, last, default', (tester) async {
      await Prefs.setPersonalDayMode(mode);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: PersonalDaySettings())));
      final defaultText = mode == PersonalDayMode.wakeToWake
          ? 'First calendar day (default)' : 'Last calendar day (default)';
      expect(find.text(defaultText), findsOneWidget);
      for (final (text, stored) in <(String, String?)>[
        ('First calendar day', 'first'),
        ('Last calendar day', 'last'),
        (defaultText, null),
      ]) {
        await tester.tap(find.text('Daily scores and totals'));
        await tester.pumpAndSettle();
        expect(find.text(text), findsOneWidget);
        await Prefs.reload();
        final sp = await SharedPreferences.getInstance();
        expect(sp.getString(Prefs.personalDayTotalsKey), stored);
        expect(Prefs.personalDayTotalsIsDefault, stored == null);
      }
      await Prefs.setPersonalDayMode(mode == PersonalDayMode.wakeToWake
          ? PersonalDayMode.sleepToSleep : PersonalDayMode.wakeToWake);
      await tester.pumpAndSettle();
      expect(find.text(mode == PersonalDayMode.wakeToWake
          ? 'Last calendar day (default)' : 'First calendar day (default)'), findsOneWidget);
    });
  }
}
