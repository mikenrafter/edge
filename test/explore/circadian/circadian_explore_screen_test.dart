// The explore screen and its gated entry (circadian explore).
//
// API under test (lib/explore/circadian/circadian_explore_screen.dart):
//   CircadianExploreScreen(summary:, rhythm:, plan:)
//     section titles: 'Your recorded daily rhythm' always;
//     'Travel schedule based on your usual sleep times' only when plan != null
//     clock values render as HH:MM (24 h); nulls render as the em dash '—'
//     admitted rhythm shows acrophase, bathyphase, amplitude ('6.0'), days
//       ('14 days') and coverage ('95%')
//     rejected rhythm shows words, no number and no clock time:
//       tooFewDays -> mentions '7 days'; lowCoverage -> '18 hours';
//       flat -> 'flat'; unstable -> 'stable'
//     always carries 'Experimental — fit quality is not accuracy'
//     never says melatonin, a dose, "internal clock", "jet lag cure"
//     travel section shows each day's hint, the suppression reason and every
//       assumption string
//   CircadianExploreEntry: key 'circadian-explore-entry', present only with
//     Feature.developerMode (Capabilities.devMode) AND Prefs.exploreCircadian
//     (default off); tapping opens CircadianExploreScreen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/explore/circadian/circadian_explore_screen.dart';
import 'package:openstrap_edge/explore/circadian/hr_rhythm_fit.dart';
import 'package:openstrap_edge/explore/circadian/sleep_timing_summary.dart';
import 'package:openstrap_edge/explore/circadian/travel_schedule_planner.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _rhythmTitle = 'Your recorded daily rhythm';
const _travelTitle = 'Travel schedule based on your usual sleep times';
const _note = 'Experimental — fit quality is not accuracy';

final _clockText = RegExp(r'\b\d{1,2}:\d{2}\b');
final _banned = RegExp(
  r'melatonin|\bmg\b|dose|dosing|medication|internal clock|jet lag cure',
  caseSensitive: false,
);

const _summary = SleepTimingSummary(
  meanOnsetClock: Duration(hours: 23, minutes: 30),
  meanWakeClock: Duration(hours: 7, minutes: 15),
  onsetSpread: Duration(minutes: 25),
  midSleepClock: Duration(hours: 3, minutes: 22),
  nights: 9,
);
const _noSummary = SleepTimingSummary(nights: 2);

const _admitted = HrRhythm(
  acrophaseClock: Duration(hours: 16),
  bathyphaseClock: Duration(hours: 4),
  amplitudeBpm: 6.0,
  mesorBpm: 60.0,
  daysUsed: 14,
  coverage: 0.95,
);

HrRhythm _rejected(RhythmRejection r) =>
    HrRhythm(daysUsed: 3, coverage: 0.4, rejection: r);

final _plan = TravelPlan(
  shiftHours: 5,
  lightSuppressedReason: null,
  assumptions: [
    'Assumes up to 1 h earlier per day (Eastman & Burgess 2009).',
    'Assumes up to 1.5 h later per day when delaying.',
  ],
  days: [
    TravelDay(
      date: DateTime(2026, 6, 12),
      tz: 'America/New_York',
      targetOnset: Duration(hours: 22),
      targetWake: Duration(hours: 6),
      lightHint: 'seek morning light',
    ),
    TravelDay(
      date: DateTime(2026, 6, 15),
      tz: 'Europe/London',
      targetOnset: Duration(hours: 23),
      targetWake: Duration(hours: 7),
    ),
  ],
);

final _suppressedPlan = TravelPlan(
  shiftHours: 12,
  lightSuppressedReason: 'Shift direction is ambiguous at 10 h or more.',
  assumptions: ['Assumes up to 1 h earlier per day (Eastman & Burgess 2009).'],
  days: [
    TravelDay(
      date: DateTime(2026, 6, 14),
      tz: 'Etc/UTC',
      targetOnset: Duration(hours: 22),
      targetWake: Duration(hours: 6),
    ),
  ],
);

Future<void> _pumpScreen(
  WidgetTester t, {
  SleepTimingSummary summary = _summary,
  HrRhythm rhythm = _admitted,
  TravelPlan? plan,
}) async {
  t.view.physicalSize = const Size(1200, 6000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: SingleChildScrollView(
        child: CircadianExploreScreen(
            summary: summary, rhythm: rhythm, plan: plan),
      ),
    ),
  ));
}

List<String> _texts(WidgetTester t) => [
      for (final w in t.widgetList<Text>(find.byType(Text)))
        w.data ?? w.textSpan?.toPlainText() ?? '',
      for (final w in t.widgetList<RichText>(find.byType(RichText)))
        w.text.toPlainText(),
    ];

void main() {
  group('CircadianExploreScreen', () {
    testWidgets('titles: the rhythm section, and the travel section with a plan',
        (t) async {
      await _pumpScreen(t, plan: _plan);
      expect(find.text(_rhythmTitle), findsOneWidget);
      expect(find.text(_travelTitle), findsOneWidget);
    });

    testWidgets('no plan: no travel section', (t) async {
      await _pumpScreen(t);
      expect(find.text(_rhythmTitle), findsOneWidget);
      expect(find.text(_travelTitle), findsNothing);
    });

    testWidgets('an admitted rhythm shows phase, amplitude, days and coverage',
        (t) async {
      await _pumpScreen(t);
      expect(find.textContaining('16:00'), findsWidgets);
      expect(find.textContaining('04:00'), findsWidgets);
      expect(find.textContaining('6.0'), findsWidgets);
      expect(find.textContaining('14 days'), findsWidgets);
      expect(find.textContaining('95%'), findsWidgets);
    });

    testWidgets('sleep timing shows its clock values and nights', (t) async {
      await _pumpScreen(t);
      expect(find.textContaining('23:30'), findsWidgets);
      expect(find.textContaining('07:15'), findsWidgets);
      expect(find.textContaining('9 nights'), findsWidgets);
    });

    testWidgets('too few nights: sleep timing shows dashes, never a time',
        (t) async {
      await _pumpScreen(t,
          summary: _noSummary, rhythm: _rejected(RhythmRejection.tooFewDays));
      expect(find.text('—'), findsWidgets);
      for (final s in _texts(t)) {
        expect(_clockText.hasMatch(s), isFalse, reason: '"$s"');
      }
    });

    for (final c in [
      (RhythmRejection.tooFewDays, '7 days'),
      (RhythmRejection.lowCoverage, '18 hours'),
      (RhythmRejection.unknownCoverage, 'before per-minute coverage'),
      (RhythmRejection.flat, 'flat'),
      (RhythmRejection.unstable, 'stable'),
    ]) {
      testWidgets('rejected (${c.$1.name}): says why, shows no clock time',
          (t) async {
        await _pumpScreen(t, summary: _noSummary, rhythm: _rejected(c.$1));
        expect(find.textContaining(c.$2), findsWidgets);
        final all = _texts(t);
        for (final s in all) {
          expect(_clockText.hasMatch(s), isFalse, reason: '"$s"');
        }
        // None of the admitted-fit figures leaks through.
        expect(all.any((s) => s.contains('16:00') || s.contains('04:00')),
            isFalse);
        expect(find.textContaining('6.0'), findsNothing);
        expect(find.textContaining('95%'), findsNothing);
      });
    }

    testWidgets('carries the experimental note, admitted or rejected',
        (t) async {
      await _pumpScreen(t);
      expect(find.textContaining(_note), findsWidgets);
      await _pumpScreen(t, rhythm: _rejected(RhythmRejection.flat));
      await t.pumpAndSettle();
      expect(find.textContaining(_note), findsWidgets);
    });

    testWidgets('the travel plan shows its hints, assumptions and day times',
        (t) async {
      await _pumpScreen(t, plan: _plan);
      expect(find.textContaining('seek morning light'), findsWidgets);
      for (final a in _plan.assumptions) {
        expect(find.textContaining(a), findsWidgets);
      }
      expect(find.textContaining('22:00'), findsWidgets);
      expect(find.textContaining('America/New_York'), findsWidgets);
    });

    testWidgets('a suppressed plan shows the reason and no light hint',
        (t) async {
      await _pumpScreen(t, plan: _suppressedPlan);
      expect(find.textContaining(_suppressedPlan.lightSuppressedReason!),
          findsWidgets);
      expect(find.textContaining('seek morning light'), findsNothing);
      expect(find.textContaining('seek evening light'), findsNothing);
    });

    testWidgets('banned phrases are absent in every state', (t) async {
      for (final rhythm in [
        _admitted,
        for (final r in RhythmRejection.values) _rejected(r),
      ]) {
        for (final plan in [null, _plan, _suppressedPlan]) {
          await _pumpScreen(t, rhythm: rhythm, plan: plan);
          await t.pumpAndSettle();
          for (final s in _texts(t)) {
            expect(_banned.hasMatch(s), isFalse, reason: '"$s"');
          }
        }
      }
    });
  });

  group('CircadianExploreEntry gating', () {
    const entry = ValueKey('circadian-explore-entry');

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
    });

    Future<void> pumpEntry(WidgetTester t,
        {required bool dev, required bool? pref}) async {
      if (pref != null) Prefs.setBool(Prefs.exploreCircadian, pref);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Provider<Capabilities>.value(
          value: Capabilities(CapabilityInputs(devMode: dev)),
          child: Scaffold(
            body: CircadianExploreEntry(
                summary: _summary, rhythm: _admitted, plan: _plan),
          ),
        ),
      ));
    }

    tearDown(() => Prefs.setBool(Prefs.exploreCircadian, false));

    testWidgets('developer mode on and the pref on: shown', (t) async {
      await pumpEntry(t, dev: true, pref: true);
      expect(find.byKey(entry), findsOneWidget);
    });

    testWidgets('developer mode on, pref never set: absent (default off)',
        (t) async {
      expect(Prefs.getBool(Prefs.exploreCircadian, false), isFalse);
      await pumpEntry(t, dev: true, pref: null);
      expect(find.byKey(entry), findsNothing);
    });

    testWidgets('developer mode on, pref off: absent', (t) async {
      await pumpEntry(t, dev: true, pref: false);
      expect(find.byKey(entry), findsNothing);
    });

    testWidgets('developer mode off, pref on: absent', (t) async {
      await pumpEntry(t, dev: false, pref: true);
      expect(find.byKey(entry), findsNothing);
    });

    testWidgets('developer mode off, pref off: absent', (t) async {
      await pumpEntry(t, dev: false, pref: false);
      expect(find.byKey(entry), findsNothing);
    });

    testWidgets('tapping the entry opens the screen', (t) async {
      t.view.physicalSize = const Size(1200, 6000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await pumpEntry(t, dev: true, pref: true);
      await t.tap(find.byKey(entry));
      await t.pumpAndSettle();
      expect(find.byType(CircadianExploreScreen), findsOneWidget);
      expect(find.text(_rhythmTitle), findsWidgets);
    });
  });
}
