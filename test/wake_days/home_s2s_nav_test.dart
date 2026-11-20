import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/date_text.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/day_navigation.dart';
import 'package:openstrap_edge/ui2/personal_day.dart';
import 'package:openstrap_edge/ui2/personal_day_inputs.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import '../backup/backup_support.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import '../support/live_guide_harness.dart' show GuideFakeRepo;
import '../support/pilot_shots.dart';
import '../support/skeleton_fixture.dart' show skLoadAppFonts;

// Owner m301 (pilot-4 APK): in sleep-to-sleep Home "jumps back to your current
// day and sometimes skips days ... It should really just say day of or cycle of
// and then the date. When navigating backward, it should always grab a day. It
// should not jump back to the current day when a calculation finishes."

final DateTime _today = () {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}();
DateTime _at(int daysAgo, int hour) =>
    DateTime(_today.year, _today.month, _today.day - daysAgo, hour);

/// When the owner looks: the clock, and whether tonight's sleep has begun.
/// `shift` moves the whole record a day back once the clock is past midnight.
typedef _When = ({String name, int hour, int minute, int shift, bool open});
const _afternoon = (name: 'afternoon', hour: 14, minute: 0, shift: 0, open: false);
const _evening = (name: 'just after onset', hour: 23, minute: 30, shift: 0, open: true);
const _midnight = (name: 'just after midnight', hour: 0, minute: 30, shift: 1, open: true);
const _times = [_afternoon, _evening, _midnight];
DateTime _nowOf(_When w) => DateTime(_today.year, _today.month, _today.day, w.hour, w.minute);
DateTime _nowFor = _nowOf(_afternoon);
_When _whenFor = _afternoon;

// Nine closed nights: asleep 23:00, awake 07:00, and past 23:00 (or past
// midnight) tonight's open sleep. Real data has no gaps.
class _Repo extends GuideFakeRepo {
  _Repo({this.skipNights = const {}});
  final Set<int> skipNights;
  /// A calculation refines every sleep's onset and wake by this many minutes.
  int refinedMin = 0;
  @override
  Future<Map<String, dynamic>> getTodayStored() => getToday();
  @override
  Future<List<String>> availableDays() async =>
      [for (var k = 0; k < 10; k++) dayLabelOf(_at(k, 12))];
  @override
  Future<List<Map<String, dynamic>>> sleepWindows(
          {int days = 60, String? before}) async =>
      _nights(skipNights, refinedMin);
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => {
        'duration_min': {'value': 420, 'confidence': .9, 'tier': 'HIGH'}
      };
}

List<Map<String, dynamic>> _nights(Set<int> skip, [int refinedMin = 0]) {
  final shift = _whenFor.shift;
  return [
    for (var k = 1; k <= 9; k++)
      if (!skip.contains(k))
        {
          'date': dayLabelOf(_at(k + shift - 1, 12)),
          'onset_ts': _at(k + shift, 23).millisecondsSinceEpoch ~/ 1000 + refinedMin * 60,
          'wake_ts': _at(k + shift - 1, 7).millisecondsSinceEpoch ~/ 1000 + refinedMin * 60,
        },
    if (_whenFor.open)
      {'date': dayLabelOf(_at(shift, 12)),
       'onset_ts': _at(shift, 23).millisecondsSinceEpoch ~/ 1000 + refinedMin * 60,
       'wake_ts': null},
  ];
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await t.pump(const Duration(milliseconds: 20));
  }
}

String _label(WidgetTester t) => t.widget<DayStepBar>(find.byType(DayStepBar)).label;

Future<AppState> _mount(WidgetTester t, PersonalDayMode mode, {_Repo? repo}) async {
  SharedPreferences.setMockInitialValues({});
  await Prefs.reload();
  await t.runAsync(() async {
    await Prefs.setPersonalDayMode(mode);
    await Prefs.setPersonalDayTotals(PersonalDayTotals.last);
  });
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  app.repo = repo ?? _Repo();
  t.binding.platformDispatcher.alwaysUse24HourFormatTestValue = true;
  addTearDown(t.binding.platformDispatcher.clearAlwaysUse24HourTestValue);
  t.view.physicalSize = const Size(430, 1100);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(pilotShot(MaterialApp(theme: buildTheme(Brightness.light),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ChangeNotifierProvider<AppState>.value(value: app,
      child: Scaffold(body: HomeScreen(now: _nowFor, hour: _whenFor.hour))))));
  // A failing test must still unmount: a Home left running kept tearDownAll
  // waiting 12 minutes on the database it holds.
  addTearDown(() => t.pumpWidget(const SizedBox.shrink()));
  await _settle(t);
  return app;
}

// The day sequence the Day screen steps for [mode]: one pass over the whole
// fixture, newest first, with the clipped query prefix dropped.
List<PersonalDay> _truth(PersonalDayMode mode, {Set<int> skip = const {}}) {
  final sleeps = mainSleepsOf(_nights(skip));
  final all = personalDays(from: _at(12, 0), until: _nowFor.add(const Duration(minutes: 1)),
    sleeps: sleeps, mode: mode, totals: PersonalDayTotals.last);
  return all.reversed.toList();
}

void main() {
  late BackupEnv env;
  setUpAll(() async {
    await skLoadAppFonts();
    env = await BackupEnv.create('wake_days_home_s2s_nav.db');
    await LocalDb.instance;
  });
  // The suite's own Home reloads leave a read pending when a test ends and
  // LocalDb.close() then waits on it for the 12-minute test cap. Bound the wait:
  // every test has passed by now, and the process exits right after.
  tearDownAll(() => env.dispose().timeout(const Duration(seconds: 15), onTimeout: () {}));

  String word(PersonalDayMode mode) =>
      mode == PersonalDayMode.sleepToSleep ? 'Cycle of' : 'Day of';

  Future<List<String>> stepBack(WidgetTester t, int most) async {
    final seen = <String>[_label(t)];
    for (var i = 0; i < most; i++) {
      if (t.widget<DayStepBar>(find.byType(DayStepBar)).onPrevious == null) break;
      await t.tap(find.byKey(const ValueKey('day-nav-previous')));
      await _settle(t);
      seen.add(_label(t));
    }
    return seen;
  }

  // WHY / CLAIM(home-steps-mode) [owner m301]: Home's bar steps the SAME day
  // sequence the Day screen shows for the selected mode (it forced wake-to-wake
  // cycles in e5bf75872, so a sleep-to-sleep user saw other cycles than the
  // timeline), and stepping back lands on the adjacent earlier day every time,
  // at any hour, including just after sleep onset and just after midnight.
  // CATCHES: `home: true` forcing wakeToWake, a window that re-centres on each
  // step and drops or merges a neighbour, an open cycle that is named for one
  // day and then another.
  for (final mode in [PersonalDayMode.sleepToSleep, PersonalDayMode.wakeToWake]) {
    for (final when in _times) {
      testWidgets('stepping back visits every ${mode.name} day once, in order: ${when.name}', (t) async {
        _whenFor = when;
        _nowFor = _nowOf(when);
        await withClock(Clock.fixed(_nowFor), () async {
          await _mount(t, mode);
          final expected = [for (final c in _truth(mode))
            '${word(mode)} ${displayDay(c.label, null)}'];
          final seen = await stepBack(t, 8);
          expect(seen.length, greaterThanOrEqualTo(7), reason: 'a week of nights is on file');
          // A start time is appended only where two cycles share a date name.
          String dated(String label) => label.split(' · ').first;
          expect([for (final l in seen) dated(l)], expected.take(seen.length).toList(),
              reason: 'the Day screen\'s sequence');
          expect(seen.toSet().length, seen.length, reason: 'every step reads differently: $seen');
          // Adjacent: each step lands on the same calendar day or the one before,
          // never two back. The same day twice only happens in the two hours
          // after a sleep onset, where the open cycle and the one it follows
          // are both named for the day the onset fell on (a known limit, see
          // pilot5/report.md); it is not a skip.
          final dates = [for (final c in _truth(mode).take(seen.length)) DateTime.parse(c.label)];
          for (var i = 1; i < dates.length; i++) {
            final back = DateTime(dates[i - 1].year, dates[i - 1].month, dates[i - 1].day)
                .difference(DateTime(dates[i].year, dates[i].month, dates[i].day)).inDays;
            expect(back, anyOf(0, 1), reason: 'step $i skipped a day: $seen');
          }
        });
      });
    }
  }

  // CATCHES: a gap in the sleeps (night 4 never recorded) turning a step back
  // into a jump over a day: every cycle between two anchors stays reachable.
  testWidgets('a missing night keeps the Day screen\'s sequence when stepping back', (t) async {
    _whenFor = _afternoon;
    _nowFor = _nowOf(_afternoon);
    await withClock(Clock.fixed(_nowFor), () async {
      await _mount(t, PersonalDayMode.sleepToSleep, repo: _Repo(skipNights: {4}));
      final seen = await stepBack(t, 6);
      final expected = [for (final c in _truth(PersonalDayMode.sleepToSleep, skip: {4}))
        'Cycle of ${displayDay(c.label, null)}'];
      expect(seen.length, greaterThanOrEqualTo(5));
      expect([for (final l in seen) l.split(' · ').first], expected.take(seen.length).toList());
    });
  });

  // WHY / CLAIM(home-keeps-day) [owner m301]: a finished calculation or a saved
  // preference never moves Home off the day the user picked; only "Back to
  // today" (or a different personal-day mode) does. CATCHES: the personalDay
  // revision listener (the totals choice is learned INSIDE a Home read and
  // bumps it) and the insights revision both resetting the selected day.
  for (final mode in [PersonalDayMode.sleepToSleep, PersonalDayMode.wakeToWake]) {
    testWidgets('a recalculation on a past ${mode.name} day leaves Home there', (t) async {
      _whenFor = _afternoon;
      _nowFor = _nowOf(_afternoon);
      await withClock(Clock.fixed(_nowFor), () async {
        final app = await _mount(t, mode);
        for (var i = 0; i < 3; i++) {
          await t.tap(find.byKey(const ValueKey('day-nav-previous')));
          await _settle(t);
        }
        final picked = _label(t);
        expect(find.byKey(const ValueKey('home-back-to-today')), findsOneWidget);

        app.insightsRevision.value++; // a derive landed
        await _settle(t);
        expect(_label(t), picked, reason: 'derive finished');
        expect(find.byKey(const ValueKey('home-back-to-today')), findsOneWidget);

        Prefs.personalDayRevision.value++; // the totals choice learned in a read
        await _settle(t);
        expect(_label(t), picked, reason: 'totals learned');
        expect(find.byKey(const ValueKey('home-back-to-today')), findsOneWidget);

        await t.tap(find.byKey(const ValueKey('home-back-to-today')));
        await _settle(t);
        expect(find.byKey(const ValueKey('home-back-to-today')), findsNothing);
        });
    });
  }

  // WHY / CLAIM(home-keeps-day) [owner m301]: a calculation that refines a
  // sleep by minutes moves the cycle's id (its start). Home stays on that day
  // instead of dropping to an empty read. CATCHES: matching the old id exactly.
  for (final mode in [PersonalDayMode.sleepToSleep, PersonalDayMode.wakeToWake]) {
    testWidgets('a refined ${mode.name} start keeps Home on the picked day', (t) async {
      _whenFor = _afternoon;
      _nowFor = _nowOf(_afternoon);
      await withClock(Clock.fixed(_nowFor), () async {
        final repo = _Repo();
        final app = await _mount(t, mode, repo: repo);
        for (var i = 0; i < 3; i++) {
          await t.tap(find.byKey(const ValueKey('day-nav-previous')));
          await _settle(t);
        }
        final picked = _label(t);
        repo.refinedMin = 20;
        app.insightsRevision.value++;
        await _settle(t);
        expect(_label(t), picked);
        expect(find.byKey(const ValueKey('home-back-to-today')), findsOneWidget);
        });
    });
  }

  // WHY: the bar reads "Day of <date>" / "Cycle of <date>" (owner m301), not
  // the ISO label with a clock time. CATCHES: the old "date · time" label.
  for (final (mode, prefix) in [
    (PersonalDayMode.sleepToSleep, 'Cycle of'),
    (PersonalDayMode.wakeToWake, 'Day of'),
    (PersonalDayMode.calendarOffset, 'Day of'),
  ]) {
    testWidgets('bar wording: ${mode.name}', (t) async {
      _whenFor = _afternoon;
      _nowFor = _nowOf(_afternoon);
      await withClock(Clock.fixed(_nowFor), () async {
        await _mount(t, mode);
        expect(_label(t), startsWith('$prefix '));
        expect(_label(t), isNot(contains('·')));
        expect(t.widget<DayStepBar>(find.byType(DayStepBar)).chooseLabel, contains(_label(t)));
        await t.tap(find.byKey(const ValueKey('day-nav-choose')));
        await _settle(t);
        expect(find.textContaining(prefix), findsAtLeastNWidgets(2), reason: 'picker rows');
        expect(_label(t), isNot(matches(RegExp(r'\d{4}-\d{2}'))));
      });
    });
  }

  // Review artifact (CLS_SHOTS_DIR set): Home in sleep to sleep two days back,
  // for the before/after pair in pilot5/shots. Asserts nothing about pixels.
  testWidgets('shot: Home, sleep to sleep, two days back', (t) async {
    _whenFor = _afternoon;
    _nowFor = _nowOf(_afternoon);
    await withClock(Clock.fixed(_nowFor), () async {
      await _mount(t, PersonalDayMode.sleepToSleep);
      await stepBack(t, 2);
      await takePilotShot(t, 'home-s2s-two-days-back');
    });
  });
}
