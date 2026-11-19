import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/personal_day.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/ui2/personal_day_widgets.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart' show DayNav;
import 'package:openstrap_edge/state/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // WHY: the owner's named bug, after alarm + I'm up, may never show another
  // estimate while the last night is processing. catches: ignoring wakeObserved.
  testWidgets('I am up ends both sleeping and on-track Home captions', (t) async {
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: RingTrio(now: DateTime(2026, 11, 3, 8),
        d: HomeData(dayId: '2026-11-03', wakeObserved: true,
          personalMode: PersonalDayMode.wakeToWake,
          recoveryState: 'night_in_progress',
          learnedOnsetMin: 23*60, learnedWakeMin: 8*60,
          nextAlarm: DateTime(2026, 11, 4, 7))))));
    expect(find.textContaining('on track'), findsNothing);
    expect(find.textContaining('Sleeping'), findsNothing);
    expect(find.byWidgetPredicate((w) => w is Text &&
      (w.data?.contains("isn't scored yet") ?? false)), findsWidgets);
  });
  // WHY: two cycles can share a date; the shared navigation must select by
  // cycle identity rather than silently collapsing their labels.
  testWidgets('shared day picker distinguishes cycles sharing a date', (t) async {
    String? selected;
    final first = DateTime(2026,11,2).toIso8601String();
    final second = DateTime(2026,11,2,12).toIso8601String();
    await t.pumpWidget(MaterialApp(home: Scaffold(body: DayNav(day: second,
      days: [second, first], labels: {second:'Nov 2 at noon', first:'Nov 2 at midnight'},
      onDay: (day) => selected = day))));
    await t.tap(find.byKey(const ValueKey('day-nav-choose')));
    await t.pumpAndSettle();
    await t.tap(find.text('Nov 2 at midnight'));
    await t.pumpAndSettle();
    expect(selected, first);
  });
  testWidgets('settings separates unset behaviour from an explicit noon mode', (t) async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.reload();
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: PersonalDaySettings())));
    expect(find.text('Current behaviour'), findsOneWidget);
    await t.tap(find.text('Your day'));
    await t.pumpAndSettle();
    await t.tap(find.text('Calendar days (12 h offset)'));
    await t.pumpAndSettle();
    expect(Prefs.personalDayEnabled, isTrue);
    expect(Prefs.personalDayMode, PersonalDayMode.calendarOffset);
    SharedPreferences.setMockInitialValues({'ui.personal_day_mode':'wakeToWake'});
    await Prefs.reload();
    await t.pump();
    expect(find.text('Your day (wake to wake)'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });

}
