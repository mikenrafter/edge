// The circadian explore wiring: hourly bins from a stored minute curve (DST
// safe), the two-key gate on the Device lab door, the travel form's refusal to
// plan without usual sleep times, and the loader end to end.
//
// Why bins come from `getDayHeart(day)['hr']` and not a decoded_onehz query:
// decoded_onehz is pruned at rawRetentionDays = 3, so a 14-day window cannot be
// read from it. The derived day's minute curve survives.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/explore/circadian/circadian_explore_data.dart';
import 'package:openstrap_edge/explore/circadian/circadian_explore_probe.dart';
import 'package:openstrap_edge/explore/circadian/hourly_hr_bins.dart';
import 'package:openstrap_edge/explore/circadian/hr_rhythm_fit.dart';
import 'package:openstrap_edge/explore/circadian/sleep_timing_summary.dart';
import 'package:openstrap_edge/explore/circadian/travel_plan_form.dart';
import 'package:openstrap_edge/explore/circadian/travel_schedule_planner.dart';
import 'package:openstrap_edge/platform/app_icon.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SetRow;
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// One point per minute of [dayStart, dayEnd), the real elapsed minutes.
List<Map<String, num>> _curve(DateTime dayStart, DateTime dayEnd,
    {num Function(int sec)? v}) {
  final out = <Map<String, num>>[];
  for (var s = dayStart.millisecondsSinceEpoch ~/ 1000;
      s < dayEnd.millisecondsSinceEpoch ~/ 1000;
      s += 60) {
    out.add({'t': s, 'v': v?.call(s) ?? 62});
  }
  return out;
}

void main() {
  // Before the groups below build: they look zones up while declaring tests.
  tzdata.initializeTimeZones();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });

  group('hourlyBinsFromHrCurve', () {
    final ny = tz.getLocation('America/New_York');
    DateTime nyLocal(int s) =>
        tz.TZDateTime.fromMillisecondsSinceEpoch(ny, s * 1000);

    test('a normal day is 24 full local hours', () {
      final bins = hourlyBinsFromHrCurve(
        _curve(DateTime(2026, 5, 4), DateTime(2026, 5, 5)),
      );
      expect(bins, hasLength(24));
      expect([for (final b in bins) b.hourStartLocal.hour],
          [for (var h = 0; h < 24; h++) h]);
      // RED EDIT (Sol P2, minute summaries inflate the gate): this used to
      // assert realMinutes == 60, i.e. that a stored minute is a real minute.
      // The stored curve carries no per-minute sample count, so the number of
      // real minutes in an hour is unknown, not 60.
      expect(bins.every((b) => b.meanHr == 62), isTrue);
      expect(bins.every((b) => (b as dynamic).realMinutes == null), isTrue,
          reason: 'real minutes are not knowable from {t, v} points');
    });

    test('a spring-forward day is 23 local hours, and 02:00 is missing', () {
      final bins = hourlyBinsFromHrCurve(
        _curve(tz.TZDateTime(ny, 2026, 3, 8), tz.TZDateTime(ny, 2026, 3, 9)),
        toLocal: nyLocal,
      );
      expect(bins, hasLength(23));
      expect(bins.map((b) => b.hourStartLocal.hour).contains(2), isFalse);
      // RED EDIT (Sol P2): was realMinutes == 60 for every bin.
      expect(bins.every((b) => (b as dynamic).realMinutes == null), isTrue,
          reason: 'real minutes are not knowable from {t, v} points');
      expect(bins.every((b) => b.hourStartLocal.day == 8), isTrue);
    });

    test('a fall-back day is 25 bins: the repeated wall hour is two bins', () {
      final bins = hourlyBinsFromHrCurve(
        _curve(tz.TZDateTime(ny, 2026, 11, 1), tz.TZDateTime(ny, 2026, 11, 2)),
        toLocal: nyLocal,
      );
      expect(bins, hasLength(25));
      expect(bins.where((b) => b.hourStartLocal.hour == 1), hasLength(2));
    });

    // RED EDIT (Sol P2): retitled from 'minutes are counted, not assumed'.
    test('stored minutes are not counted as real minutes; no sample is not a zero',
        () {
      final base = DateTime(2026, 5, 4, 10).millisecondsSinceEpoch ~/ 1000;
      final bins = hourlyBinsFromHrCurve([
        {'t': base, 'v': 60},
        {'t': base + 60, 'v': 70},
        {'t': base + 120, 'v': 0}, // not worn
        {'t': base + 180, 'v': null},
        {'t': base + 240},
        'junk',
      ]);
      expect(bins, hasLength(1));
      // RED EDIT (Sol P2): was `realMinutes == 2`. Two stored minutes say
      // nothing about how many seconds each held, so the count is unknown.
      expect((bins.single as dynamic).realMinutes, isNull);
      expect(bins.single.meanHr, 65);
    });

    // Sol P2 (hourly_hr_bins.dart:38): `_downsampleHr` emits a {t, v} point
    // for a minute with even ONE valid second, and stores nothing else, so the
    // hourly real-minute count is not recoverable from hr_curve. Seven days x
    // 18 hours x 10 isolated seconds an hour (in 10 distinct minutes) is 21
    // minutes of actual samples over the week, and it must not pass any gate.
    test('7 days x 18 h x 10 isolated seconds an hour is not a rhythm', () {
      DateTime utc(int s) =>
          DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);
      final curve = <Map<String, num>>[];
      for (var d = 0; d < 7; d++) {
        for (var h = 0; h < 18; h++) {
          for (var m = 0; m < 10; m++) {
            // Ten distinct minutes of the hour, one valid second each: the
            // downsampler would emit exactly these points.
            final t = DateTime.utc(2026, 5, 4 + d, h, m * 6)
                    .millisecondsSinceEpoch ~/
                1000;
            curve.add({
              't': t,
              'v': (60 + 6 * math.cos(2 * math.pi * (h + 0.5 - 16) / 24))
                  .round(),
            });
          }
        }
      }
      final bins = hourlyBinsFromHrCurve(curve, toLocal: utc);
      expect(bins, hasLength(7 * 18));
      final r = fitHrRhythm(bins);
      expect(r.rejection, isNotNull,
          reason: '21 minutes of samples in a week must not fit a rhythm');
      expect(['lowCoverage', 'unknownCoverage'], contains(r.rejection?.name));
      expect(r.acrophaseClock, isNull);
      expect(r.bathyphaseClock, isNull);
      expect(r.amplitudeBpm, isNull);
      expect(r.mesorBpm, isNull);
    });
  });

  group('the gate on the Device lab door', () {
    Future<void> pump(WidgetTester t,
        {required bool dev,
        required bool pref,
        required CircadianLoader load,
        LocalRepository? repo}) async {
      Prefs.setBool(Prefs.exploreCircadian, pref);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Provider<Capabilities>.value(
          value: Capabilities(CapabilityInputs(devMode: dev)),
          child: Scaffold(
            body: CircadianExploreProbe(repo: repo ?? _FakeRepo(), load: load),
          ),
        ),
      ));
      await t.pumpAndSettle();
    }

    tearDown(() => Prefs.setBool(Prefs.exploreCircadian, false));

    const entry = ValueKey('circadian-explore-entry');
    const data = CircadianExploreData(
      summary: SleepTimingSummary(nights: 0),
      rhythm: HrRhythm(
          daysUsed: 0, coverage: 0, rejection: RhythmRejection.tooFewDays),
    );

    for (final c in [
      (false, false),
      (true, false),
      (false, true),
    ]) {
      testWidgets('developer ${c.$1}, pref ${c.$2}: nothing drawn, nothing read',
          (t) async {
        var reads = 0;
        await pump(t, dev: c.$1, pref: c.$2, load: (_) async {
          reads++;
          return data;
        });
        expect(find.byKey(entry), findsNothing);
        expect(find.byType(Surface), findsNothing);
        expect(reads, 0);
      });
    }

    testWidgets('both on: reads once and shows the entry', (t) async {
      var reads = 0;
      await pump(t, dev: true, pref: true, load: (_) async {
        reads++;
        return data;
      });
      expect(find.byKey(entry), findsOneWidget);
      expect(reads, 1);
    });

    testWidgets('no repository: nothing drawn', (t) async {
      Prefs.setBool(Prefs.exploreCircadian, true);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Provider<Capabilities>.value(
          value: Capabilities(CapabilityInputs(devMode: true)),
          child: const Scaffold(body: CircadianExploreProbe(repo: null)),
        ),
      ));
      expect(find.byType(Surface), findsNothing);
    });

    testWidgets('a failed read says so and retries on tap, never an empty '
        'state', (t) async {
      var reads = 0;
      await pump(t, dev: true, pref: true, load: (_) async {
        reads++;
        if (reads == 1) throw StateError('db busy');
        return data;
      });
      expect(find.byKey(const ValueKey('circadian-explore-error')),
          findsOneWidget);
      expect(find.byKey(entry), findsNothing);
      await t.tap(find.byKey(const ValueKey('circadian-explore-error')));
      await t.pumpAndSettle();
      expect(find.byKey(entry), findsOneWidget);
      expect(reads, 2);
    });

    testWidgets('Settings > Developer > Circadian estimate toggles the pref',
        (t) async {
      t.view.physicalSize = const Size(1170, 30000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      var taps = 0;
      Future<void> settings(bool on) => t.pumpWidget(
            ChangeNotifierProvider<LocaleController>.value(
              value: LocaleController.seed(null),
              child: MaterialApp(
                theme: buildTheme(Brightness.light),
                home: MoreSettingsView(
                  devMode: true,
                  version: '0.9.99 (1)',
                  appIcon: AppIconChoice.colourful,
                  exploreCircadian: on,
                  onToggleExploreCircadian: () => taps++,
                ),
              ),
            ),
          );
      await settings(false);
      await t.pumpAndSettle();
      final row = find.text('Circadian estimate');
      expect(row, findsOneWidget);
      await t.tap(row);
      expect(taps, 1);
      expect(
          find.descendant(
              of: find.ancestor(of: row, matching: find.byType(SetRow)),
              matching: find.text('Off')),
          findsOneWidget);
      await settings(true);
      await t.pumpAndSettle();
      expect(
          find.descendant(
              of: find.ancestor(
                  of: find.text('Circadian estimate'),
                  matching: find.byType(SetRow)),
              matching: find.text('On')),
          findsOneWidget);
    });
  });

  group('TravelPlanForm', () {
    Future<void> pumpForm(
      WidgetTester t, {
      required SleepTimingSummary summary,
      required List<TravelPlan> plans,
      String? dest,
      DateTime? dep,
    }) async {
      t.view.physicalSize = const Size(1200, 6000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: TravelPlanForm(
              summary: summary,
              onPlan: plans.add,
              localZone: () async => 'America/New_York',
              initialDest: dest,
              initialDeparture: dep,
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();
    }

    final error = find.byKey(const ValueKey('circadian-form-error'));
    final submit = find.byKey(const ValueKey('circadian-form-plan'));

    testWidgets('refuses to plan without usual sleep times, and says so',
        (t) async {
      final plans = <TravelPlan>[];
      // Everything else is filled in: only the usual times are missing.
      await pumpForm(t,
          summary: const SleepTimingSummary(nights: 2),
          plans: plans,
          dest: 'Europe/London',
          dep: DateTime(2026, 6, 15));
      expect(find.text('Required'), findsNWidgets(2));
      await t.tap(submit);
      await t.pumpAndSettle();
      expect(plans, isEmpty);
      expect(t.widget<Text>(error).data, contains('usual sleep and wake'));
    });

    testWidgets('the usual times default to the recorded means, the origin to '
        'the phone zone; a missing destination still refuses', (t) async {
      final plans = <TravelPlan>[];
      await pumpForm(t,
          summary: const SleepTimingSummary(
            meanOnsetClock: Duration(hours: 23),
            meanWakeClock: Duration(hours: 7),
            nights: 9,
          ),
          plans: plans);
      expect(find.text('23:00'), findsOneWidget);
      expect(find.text('07:00'), findsOneWidget);
      expect(find.text('America/New_York'), findsOneWidget);
      await t.tap(submit);
      await t.pumpAndSettle();
      expect(plans, isEmpty);
      expect(error, findsOneWidget);
    });

    testWidgets('a complete form makes the plan', (t) async {
      final plans = <TravelPlan>[];
      await pumpForm(t,
          summary: const SleepTimingSummary(
            meanOnsetClock: Duration(hours: 23),
            meanWakeClock: Duration(hours: 7),
            nights: 9,
          ),
          plans: plans,
          dest: 'Europe/London',
          dep: DateTime(2026, 6, 15));
      await t.tap(submit);
      await t.pumpAndSettle();
      expect(error, findsNothing);
      expect(plans, hasLength(1));
      expect(plans.single.shiftHours, 5);
      expect(plans.single.days.last.targetOnset, const Duration(hours: 23));
    });
  });

  group('loadCircadianExploreData', () {
    // RED EDIT (Sol P2): this test fed a bare {t, v} minute curve and expected
    // an ADMITTED rhythm, i.e. it encoded the defect. A minute curve has no
    // per-minute sample count, so the real-data gate cannot be met from it: the
    // nights and the summary still read, the rhythm abstains.
    test('reads nights and a stored minute curve, fits off the UI isolate',
        () async {
      // Local time is UTC under TZ=UTC; both sides use the device zone anyway.
      final now = DateTime(2026, 10, 7, 12);
      final repo = _FakeRepo(
        days: [
          for (var back = 1; back <= 14; back++)
            _label(DateTime(2026, 10, 7 - back)),
          // Today has a partial curve that must not be read.
        ],
        heart: (day) {
          final d = DateTime.parse(day);
          return {
            'hr': _curve(d, DateTime(d.year, d.month, d.day + 1), v: (s) {
              final h = DateTime.fromMillisecondsSinceEpoch(s * 1000);
              final hour = h.hour + h.minute / 60 + 0.5 / 60;
              return (60 + 6 * math.cos(2 * math.pi * (hour - 16) / 24))
                  .round();
            }),
          };
        },
        sleep: (day) {
          final d = DateTime.parse(day);
          return {
            'onset_ts': DateTime(d.year, d.month, d.day - 1, 23)
                    .millisecondsSinceEpoch ~/
                1000,
            'wake_ts':
                DateTime(d.year, d.month, d.day, 7).millisecondsSinceEpoch ~/
                    1000,
            'duration_min': 420,
          };
        },
      );
      final d = await loadCircadianExploreData(repo, now: now);
      expect(d.summary.nights, 14);
      expect(d.summary.meanOnsetClock, const Duration(hours: 23));
      expect(d.summary.meanWakeClock, const Duration(hours: 7));
      expect(d.rhythm.rejection, isNotNull,
          reason: 'bare minute points do not establish real minutes');
      expect(['lowCoverage', 'unknownCoverage'], contains(d.rhythm.rejection?.name));
      expect(d.rhythm.acrophaseClock, isNull);
      expect(repo.heartReads, isNot(contains(_label(now))),
          reason: 'today is partial and is not read');
    });

    test('a night with no total sleep time is not a window', () async {
      final repo = _FakeRepo(
        days: ['2026-10-06', '2026-10-05'],
        heart: (_) => const {},
        sleep: (_) => {'onset_ts': 1, 'wake_ts': 100, 'duration_min': null},
      );
      final d = await loadCircadianExploreData(repo, now: DateTime(2026, 10, 7));
      expect(d.summary.nights, 0);
      expect(d.rhythm.rejection, RhythmRejection.tooFewDays);
    });
  });
}

String _label(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// Only the three readers the explore loader calls.
class _FakeRepo extends LocalRepository {
  _FakeRepo({
    this.days = const [],
    this.heart,
    this.sleep,
  });

  final List<String> days; // newest first
  final Map<String, dynamic> Function(String day)? heart;
  final Map<String, dynamic> Function(String day)? sleep;
  final heartReads = <String>[];

  @override
  Future<List<String>> availableDays() async => days;

  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async =>
      sleep!(date);

  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async {
    heartReads.add(date);
    return heart!(date);
  }
}
