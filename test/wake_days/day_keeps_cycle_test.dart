import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/pilot/timeline_policy.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/day_navigation.dart';
import 'package:openstrap_edge/ui2/personal_day.dart';
import 'package:openstrap_edge/ui2/personal_day_inputs.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import '../backup/backup_support.dart';
import '../support/live_guide_harness.dart' show GuideFakeRepo;
import '../support/skeleton_fixture.dart' show skLoadAppFonts;

// Owner m348/m351 (the recording): the Day screen was on "2026-11-17 · 00:00",
// Saved tab, and the day changed to the next cycle (and the tab reset) while the
// list was being flung. The scroll was a coincidence: a background reload moved
// the open cycle's start, so its id (the start instant) no longer existed.
// WHY / CLAIM(day-keeps-cycle): a calculation that moves a past cycle's start by
// minutes leaves the Day screen on that day, on the same tab, with no
// "Back to ..." link. CATCHES: matching the old id exactly, a tab reset keyed by
// the cycle id, an "opened" anchor that is not carried to the renamed cycle.

final DateTime _today = () {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}();
DateTime _at(int daysAgo, int hour) =>
    DateTime(_today.year, _today.month, _today.day - daysAgo, hour);
final DateTime _now = DateTime(_today.year, _today.month, _today.day, 14);

class _Repo extends GuideFakeRepo {
  int refinedMin = 0;
  @override
  Future<Map<String, dynamic>> getTodayStored() => getToday();
  @override
  Future<List<String>> availableDays() async =>
      [for (var k = 0; k < 10; k++) dayLabelOf(_at(k, 12))];
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60, String? before}) async =>
      _nights(refinedMin);
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => {
        'duration_min': {'value': 420, 'confidence': .9, 'tier': 'HIGH'}
      };
}

List<Map<String, dynamic>> _nights(int refinedMin) => [
      for (var k = 1; k <= 9; k++)
        {
          'date': dayLabelOf(_at(k - 1, 12)),
          'onset_ts': _at(k, 23).millisecondsSinceEpoch ~/ 1000 + refinedMin * 60,
          'wake_ts': _at(k - 1, 7).millisecondsSinceEpoch ~/ 1000 + refinedMin * 60,
        },
    ];

List<PersonalDay> _cycles(PersonalDayMode mode) => personalDays(
        from: _at(12, 0), until: _now.add(const Duration(minutes: 1)),
        sleeps: mainSleepsOf(_nights(0)), mode: mode, totals: PersonalDayTotals.last)
    .reversed.toList();

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await t.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  late BackupEnv env;
  setUpAll(() async {
    await skLoadAppFonts();
    env = await BackupEnv.create('wake_days_day_keeps_cycle.db');
    await LocalDb.instance;
  });
  tearDownAll(() => env.dispose().timeout(const Duration(seconds: 15), onTimeout: () {}));

  for (final mode in [PersonalDayMode.sleepToSleep, PersonalDayMode.wakeToWake]) {
    for (final pilot in [false, true]) {
      testWidgets('a refined ${mode.name} start keeps the Day screen on the picked day (pilot layout: $pilot)', (t) async {
        await withClock(Clock.fixed(_now), () async {
          SharedPreferences.setMockInitialValues({});
          await Prefs.reload();
          await t.runAsync(() async {
            await Prefs.setPersonalDayMode(mode);
            await Prefs.setPersonalDayTotals(PersonalDayTotals.last);
          });
          await PilotFlags.set(PilotFlag.timelines, pilot);
          final repo = _Repo();
          final app = AppState.forTesting()..repo = repo;
          addTearDown(app.dispose);
          t.view.physicalSize = const Size(430, 1100);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.reset);
          t.binding.platformDispatcher.alwaysUse24HourFormatTestValue = true;
          addTearDown(t.binding.platformDispatcher.clearAlwaysUse24HourTestValue);
          final picked = _cycles(mode)[3].id.value;
          await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ChangeNotifierProvider<AppState>.value(value: app,
              child: DayTimelineScreen(day: picked))));
          addTearDown(() => t.pumpWidget(const SizedBox.shrink()));
          await _settle(t);
          String label() => t.widget<DayStepBar>(find.byType(DayStepBar).first).label;
          int? tab() => pilot ? t.widget<SubTabs>(find.byType(SubTabs).first).index : null;
          final before = label();
          int backLinks() => find.textContaining('Back to').evaluate().length;
          final links = backLinks(); // "Back to today" is there on any past day
          // Pick the tab that is not the default one.
          if (pilot) {
            final other = PilotTimelineTab.values.firstWhere(
                (v) => v.index != tab());
            await t.tap(find.byKey(ValueKey('pilot-tab:${other.name}')));
            await _settle(t);
          }
          final tabBefore = tab();

          repo.refinedMin = 20; // a calculation moved every start by 20 minutes
          Prefs.personalDayRevision.value++;
          await _settle(t);
          expect(label(), before, reason: 'the same day');
          expect(tab(), tabBefore, reason: 'the same tab');
          expect(backLinks(), links, reason: 'no new "Back to ..." link');
          // A second reload moves the start again: still the same day.
          repo.refinedMin = 35;
          Prefs.personalDayRevision.value++;
          await _settle(t);
          expect(label(), before);
          expect(tab(), tabBefore);
          expect(backLinks(), links, reason: 'no new "Back to ..." link');
        });
      });
    }
  }
}
