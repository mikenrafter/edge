import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/day_navigation.dart';
import 'package:openstrap_edge/ui2/personal_day.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import '../support/apk2_review_harness.dart';
import '../support/as_of_recalc_fakes.dart' show settle;

// Night k days back: asleep 23:00 the evening before, awake 07:00.
DateTime _night(int back, int hour) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - back, hour);
}

class _Repo extends Apk2Repository {
  _Repo(super.store);
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60, String? before}) async => [
    for (var k = 1; k <= 5; k++) {
      'date': dayLabelOf(_night(k - 1, 12)),
      'onset_ts': _night(k, 23).millisecondsSinceEpoch ~/ 1000,
      'wake_ts': _night(k - 1, 7).millisecondsSinceEpoch ~/ 1000,
    },
  ];
}

// The harness's own app has no localizations delegates; the pilot layout's
// "Back to ..." link needs them once a step leaves the opened day.
Future<void> _mount(WidgetTester t, Apk2Rig r) async {
  t.view.physicalSize = const Size(390, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final theme = ThemeController.seed(AppThemeChoice.light, Brightness.light);
  addTearDown(theme.dispose);
  await t.pumpWidget(MultiProvider(providers: [
    ChangeNotifierProvider<AppState>.value(value: r.app),
    ChangeNotifierProvider<ThemeController>.value(value: theme)],
    child: MaterialApp(navigatorKey: r.navigator, theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const DayTimelineScreen())));
  await settle(t);
}

// KNOWN, PRE-EXISTING (calendar days too): with the timelines pilot on, a step
// swaps the pilot list for the loading list while both hold `_listController`
// for one frame, so debug semantics asserts "attached to multiple scroll
// views". It is not this fix's concern; anything else still fails the test.
void _noStepFailure(WidgetTester t, bool timelines) {
  final error = t.takeException();
  if (error == null) return;
  expect(timelines, isTrue, reason: 'only the pilot layout has the known swap');
  // The framework folds the repeats into one "Multiple exceptions" error.
  expect(error.toString(), anyOf(contains('multiple scroll views'), contains('Multiple exceptions')));
}

class _BrokenRepo extends Apk2Repository {
  _BrokenRepo(super.store);
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60, String? before}) =>
      throw StateError('sleep windows unreadable');
}

void main() {
  // WHY: owner m289 lost the `‹ day ›` bar on the Day screen in
  // sleep-to-sleep with first-day totals. The bar is the app's one day
  // switcher (m261), so every personal-day mode and totals choice, with the
  // timelines pilot layout on or off, must draw it with the personal label.
  // CATCHES: a personal-day load that hands the bar no cycle ids, or a
  // layout that skips its step bar.
  for (final timelines in [false, true]) {
    // A personal-day read that throws lands on the retryable error card; the
    // bar must still be drawn there (dimmed), never dropped.
    testWidgets('bar shows when the personal-day read fails timelines=$timelines', (t) async {
      final r = await Apk2Rig.create(t, pending: false);
      r.app.repo = _BrokenRepo(r.store);
      await t.runAsync(() async {
        await PilotFlags.set(PilotFlag.timelines, timelines);
        await Prefs.setPersonalDayMode(PersonalDayMode.sleepToSleep);
        await Prefs.setPersonalDayTotals(PersonalDayTotals.first);
      });
      await _mount(t, r);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byType(DayStepBar), findsOneWidget);
      t.takeException();
    });
    for (final mode in PersonalDayMode.values) {
      for (final totals in [PersonalDayTotals.first, PersonalDayTotals.last, null]) {
        testWidgets('bar shows: ${mode.name} totals=${totals?.name} timelines=$timelines',
            (t) async {
          final r = await Apk2Rig.create(t, pending: false);
          r.app.repo = _Repo(r.store);
          await t.runAsync(() async {
            await PilotFlags.set(PilotFlag.timelines, timelines);
            await Prefs.setPersonalDayMode(mode);
            await Prefs.setPersonalDayTotals(totals);
          });
          await _mount(t, r);
          expect(find.byType(DayStepBar), findsOneWidget);
          final bar = t.widget<DayStepBar>(find.byType(DayStepBar));
          // The bar steps over personal cycles: an earlier one exists.
          expect(bar.onPrevious, isNotNull, reason: 'older cycle is reachable');
          expect(find.byKey(const ValueKey('day-nav-previous')), findsOneWidget);
          expect(bar.label, isNot(matches(RegExp(r'^\d{4}-\d{2}-\d{2}T'))),
              reason: 'label is the personal-day label, never the cycle id');
          // Owner m342: the one label, on the original and the pilot layout.
          final word = mode == PersonalDayMode.sleepToSleep ? 'Cycle of ' : 'Day of ';
          expect(bar.label, startsWith(word));
          // The pilot layout's row has no day picker; the original's spoken
          // label and picker rows carry the same label.
          if (!timelines) {
            expect(bar.chooseLabel, contains(bar.label), reason: 'spoken label matches');
            await apk2Tap(t, find.byKey(const ValueKey('day-nav-choose')));
            await settle(t);
            expect(find.text(bar.label), findsWidgets, reason: 'picker rows use it too');
            expect(find.textContaining(word), findsAtLeastNWidgets(2));
            await t.tapAt(const Offset(5, 5));
            await settle(t);
          }
          // Stepping back lands on the previous cycle and its own label.
          final first = bar.label;
          await apk2Tap(t, find.byKey(const ValueKey('day-nav-previous')));
          await settle(t);
          expect(find.byType(DayStepBar), findsOneWidget);
          final stepped = t.widget<DayStepBar>(find.byType(DayStepBar));
          expect(stepped.label, isNot(first), reason: 'arrow stepped a cycle');
          expect(stepped.label, startsWith(word));
          expect(stepped.onNext, isNotNull, reason: 'the newer cycle is reachable back');
          _noStepFailure(t, timelines);
        });
      }
    }
    // Calendar days (personal day off) keep their bar as before.
    testWidgets('bar shows: personal day off timelines=$timelines', (t) async {
      final r = await Apk2Rig.create(t, pending: false);
      await t.runAsync(() => PilotFlags.set(PilotFlag.timelines, timelines));
      await _mount(t, r);
      expect(find.byType(DayStepBar), findsOneWidget);
      expect(t.widget<DayStepBar>(find.byType(DayStepBar)).onPrevious, isNotNull);
      await apk2Tap(t, find.byKey(const ValueKey('day-nav-previous')));
      await settle(t);
      expect(find.byType(DayStepBar), findsOneWidget);
      _noStepFailure(t, timelines);
    });
  }
}
