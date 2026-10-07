// The read seam wiring for the pulse-pattern research view: what the loader
// makes of absent data, and that nothing is read while the view is gated off.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/explore/pulse/pulse_pattern_loader.dart';
import 'package:openstrap_edge/explore/pulse/pulse_pattern_night.dart';
import 'package:openstrap_edge/explore/pulse/pulse_pattern_research_screen.dart'
    show PulsePatternResearchScreen, kPulseResearchTitle;
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/theme.dart' show buildTheme;

Map<String, dynamic> _present(int cycles, double hours) => {
      'value': {
        'cycle_count': cycles,
        'cvhr_per_hour': cycles / hours,
        'analyzed_hours': hours,
      },
      'confidence': 0.85,
      'tier': 'HIGH',
      'inputs_used': ['rr_cleaned', 'beat_times'],
    };

class _Repo extends LocalRepository {
  _Repo({
    this.days = const [],
    this.cvhr = const {},
    this.durationMin = const {},
    this.windowHours = const {},
    this.rhythmFlag = const {},
    this.failFlagRead = false,
    this.failFirst = 0,
  });
  final List<String> days;
  final Map<String, Object?> cvhr;
  final Map<String, Object?> durationMin;

  /// NEW (fix round): the night's sleep WINDOW (onset to offset) in hours.
  /// Served under every key the read seam offers it under, all consistent:
  /// `getDayLungs()['sleep_window']` {start, end} (epoch s) and
  /// `getDaySleepV2()` `onset_ts` / `wake_ts` (epoch s) / `in_bed_min`.
  final Map<String, double> windowHours;

  /// NEW: stored `irregular_rhythm_flag` per day (1.0 / 0.0). A day with no
  /// entry has no stored point, i.e. the screen is unavailable for it.
  final Map<String, double> rhythmFlag;
  final bool failFlagRead;
  int failFirst;
  int reads = 0;

  @override
  Future<List<String>> availableDays() async {
    reads++;
    if (failFirst > 0) {
      failFirst--;
      throw StateError('read failed');
    }
    return days;
  }

  @override
  Future<Map<String, dynamic>> getDayLungs(String date) async {
    reads++;
    final w = windowHours[date];
    return {
      'cvhr': cvhr[date],
      if (w != null)
        'sleep_window': {'start': _onset, 'end': _onset + (w * 3600).round()},
    };
  }

  static const int _onset = 1760000000;

  /// `metric_series` stamps one point per derived day at LOCAL NOON.
  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async {
    reads++;
    if (metric != 'irregular_rhythm_flag') return const {'points': []};
    if (failFlagRead) throw StateError('flag read failed');
    return {
      'points': [
        for (final e in rhythmFlag.entries)
          {
            't': DateTime.parse('${e.key} 12:00:00').millisecondsSinceEpoch ~/
                1000,
            'v': e.value,
          },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async {
    reads++;
    final w = windowHours[date];
    return {
      'duration_min': durationMin[date],
      if (w != null) ...{
        'onset_ts': _onset,
        'wake_ts': _onset + (w * 3600).round(),
        'in_bed_min': (w * 60).round(),
      },
    };
  }
}

Capabilities _caps(bool dev) =>
    Capabilities(CapabilityInputs.detached(devMode: dev));

Future<void> _pumpPanel(WidgetTester t, _Repo repo,
    {required bool dev, required bool pref}) async {
  Prefs.setBool(Prefs.explorePulsePatterns, pref);
  await t.pumpWidget(Provider<Capabilities>.value(
    value: _caps(dev),
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: PulsePatternResearchPanel(repo: repo)),
    ),
  ));
  await t.pump();
  await t.pump();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  tearDown(() => Prefs.setBool(Prefs.explorePulsePatterns, false));

  group('loadPulsePatternNights', () {
    test('an absent envelope is "not analysed", never a count of 0', () async {
      final repo = _Repo(days: ['2026-10-06'], durationMin: {'2026-10-06': 420});
      final nights = await loadPulsePatternNights(repo);
      expect(nights, hasLength(1));
      expect(nights.single.cycleCount, isNull);
      expect(nights.single.exclusions, [kPulseExclusionNotAnalysed]);
    });

    test('a missing sleep duration is "coverage unknown", not full coverage',
        () async {
      final repo = _Repo(days: ['2026-10-06'], cvhr: {
        '2026-10-06': _present(12, 6.0),
      });
      final n = (await loadPulsePatternNights(repo)).single;
      expect(n.cycleCount, 12);
      expect(n.coverage, isNull);
      expect(n.exclusions, [kPulseExclusionCoverageUnknown]);
      expect(n.admitted, isFalse);
    });

    // EDITED (fix round, Sol P2): this test supplied only `duration_min`
    // (asleep minutes, 420) and expected coverage 6/7 from it, i.e. it encoded
    // the defect of dividing analysed time by asleep time. The denominator is
    // now the sleep window onset to offset, here 7 h.
    test('window seconds become hours: 6 analysed of a 7 h window is admitted',
        () async {
      final repo = _Repo(
        days: ['2026-10-06'],
        cvhr: {'2026-10-06': _present(3, 6.0)},
        durationMin: {'2026-10-06': 420},
        windowHours: {'2026-10-06': 7.0},
        rhythmFlag: {'2026-10-06': 0.0},
      );
      final n = (await loadPulsePatternNights(repo)).single;
      expect(n.coverage, closeTo(6.0 / 7.0, 1e-9));
      expect(n.admitted, isTrue);
    });

    // NEW (Sol P2, reviewer scenario): 8 h window, 5 h asleep, 4 h analysed.
    // Asleep time is the wrong denominator (4/5 = 80%, admitted today); the
    // window is the right one (4/8 = 50%, not admitted).
    test('8 h window, 5 h asleep, 4 h analysed: 50% coverage, not admitted',
        () async {
      final repo = _Repo(
        days: ['2026-10-06'],
        cvhr: {'2026-10-06': _present(9, 4.0)},
        durationMin: {'2026-10-06': 300},
        windowHours: {'2026-10-06': 8.0},
        rhythmFlag: {'2026-10-06': 0.0},
      );
      final n = (await loadPulsePatternNights(repo)).single;
      expect(n.coverage, closeTo(0.5, 1e-9));
      expect(n.exclusions, contains(kPulseExclusionUnderCoverage));
      expect(n.admitted, isFalse);
    });

    // NEW (Sol P2): the window denominator also applies the other way. 7 h
    // analysed of an 8 h window with 5 h asleep is 87.5%, not a clamped 100%.
    test('8 h window, 5 h asleep, 7 h analysed: 87.5%, not a clamped 100%',
        () async {
      final repo = _Repo(
        days: ['2026-10-06'],
        cvhr: {'2026-10-06': _present(9, 7.0)},
        durationMin: {'2026-10-06': 300},
        windowHours: {'2026-10-06': 8.0},
        rhythmFlag: {'2026-10-06': 0.0},
      );
      final n = (await loadPulsePatternNights(repo)).single;
      expect(n.coverage, closeTo(0.875, 1e-9));
      expect(n.admitted, isTrue);
    });

    // NEW (Sol P2): analysis longer than the window is a data problem to
    // surface, never a silent clamp to full coverage.
    test('analysis longer than the sleep window is flagged, not clamped',
        () async {
      final repo = _Repo(
        days: ['2026-10-06'],
        cvhr: {'2026-10-06': _present(9, 7.0)},
        durationMin: {'2026-10-06': 300},
        windowHours: {'2026-10-06': 6.0},
        rhythmFlag: {'2026-10-06': 0.0},
      );
      final n = (await loadPulsePatternNights(repo)).single;
      expect(n.exclusions, contains('analysis longer than the sleep window'));
      expect(n.admitted, isFalse);
      expect(n.coverage == null || n.coverage! > 1.0, isTrue);
    });

    // NEW (Sol P2): asleep minutes alone must not stand in for the window. No
    // window means coverage unknown, even when `duration_min` is present.
    test('asleep minutes without a sleep window is "coverage unknown"',
        () async {
      final repo = _Repo(
        days: ['2026-10-06'],
        cvhr: {'2026-10-06': _present(3, 6.0)},
        durationMin: {'2026-10-06': 420},
        rhythmFlag: {'2026-10-06': 0.0},
      );
      final n = (await loadPulsePatternNights(repo)).single;
      expect(n.coverage, isNull);
      expect(n.exclusions, [kPulseExclusionCoverageUnknown]);
      expect(n.admitted, isFalse);
    });

    // NEW (Sol P2): a qualifying night (6 h of a 7 h window, >= 4 h, >= 80%)
    // whose stored irregular-rhythm flag is set is out of the comparison. The
    // flag is `metric_series` `irregular_rhythm_flag` (1/0 per derived day),
    // read via `getChart` and matched by local day label, the way the
    // pinned-analytics cross-gate in investigate.dart does.
    test('a night with the irregular-rhythm flag set is excluded', () async {
      final repo = _Repo(
        days: ['2026-10-06'],
        cvhr: {'2026-10-06': _present(30, 6.0)},
        durationMin: {'2026-10-06': 400},
        windowHours: {'2026-10-06': 7.0},
        rhythmFlag: {'2026-10-06': 1.0},
      );
      final n = (await loadPulsePatternNights(repo)).single;
      expect(n.exclusions, contains('irregular rhythm flagged'));
      expect(n.admitted, isFalse);
    });

    test('the flag is matched per day, not applied to every night', () async {
      final repo = _Repo(
        days: ['2026-10-06', '2026-10-05'],
        cvhr: {
          '2026-10-06': _present(30, 6.0),
          '2026-10-05': _present(20, 6.0),
        },
        durationMin: {'2026-10-06': 400, '2026-10-05': 400},
        windowHours: {'2026-10-06': 7.0, '2026-10-05': 7.0},
        rhythmFlag: {'2026-10-06': 1.0, '2026-10-05': 0.0},
      );
      final nights = await loadPulsePatternNights(repo);
      expect(nights[0].exclusions, contains('irregular rhythm flagged'));
      expect(nights[1].exclusions, isEmpty);
      expect(nights[1].admitted, isTrue);
    });

    test('a stored flag of 0 admits the night with no rhythm caveat',
        () async {
      final repo = _Repo(
        days: ['2026-10-06'],
        cvhr: {'2026-10-06': _present(30, 6.0)},
        durationMin: {'2026-10-06': 400},
        windowHours: {'2026-10-06': 7.0},
        rhythmFlag: {'2026-10-06': 0.0},
      );
      final n = (await loadPulsePatternNights(repo)).single;
      expect(n.exclusions, isEmpty);
      expect(n.admitted, isTrue);
    });

    // NEW (Sol P2): no stored flag for the day is UNKNOWN, not "regular". The
    // night is not excluded, and the screen says the rhythm screen was
    // unavailable.
    testWidgets('an unknown flag does not exclude, and the screen says so',
        (t) async {
      final repo = _Repo(
        days: ['2026-10-06'],
        cvhr: {'2026-10-06': _present(30, 6.0)},
        durationMin: {'2026-10-06': 400},
        windowHours: {'2026-10-06': 7.0},
        // no rhythmFlag entry for the day
      );
      final nights = await loadPulsePatternNights(repo);
      expect(nights.single.exclusions, isNot(contains('irregular rhythm flagged')));
      expect(nights.single.admitted, isTrue);

      t.view.physicalSize = const Size(1170, 12000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(Provider<Capabilities>.value(
        value: _caps(true),
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: PulsePatternResearchScreen(nights: nights),
        ),
      ));
      await t.pump();
      final all = [
        for (final w in t.widgetList<RichText>(
            find.byType(RichText, skipOffstage: false)))
          w.text.toPlainText(),
      ].join('\n');
      expect(all, contains('rhythm screen unavailable'));
    });

    // NEW: a failed flag read is a failed read, like the other reads; it is
    // never turned into "unknown".
    test('a failed rhythm-flag read throws instead of reading as unknown',
        () async {
      final repo = _Repo(
        days: ['2026-10-06'],
        cvhr: {'2026-10-06': _present(30, 6.0)},
        durationMin: {'2026-10-06': 400},
        windowHours: {'2026-10-06': 7.0},
        failFlagRead: true,
      );
      expect(loadPulsePatternNights(repo), throwsStateError);
    });

    test('reads the newest 30 days only, newest first', () async {
      final days = [for (var i = 40; i >= 1; i--) '2026-09-${i.toString().padLeft(2, '0')}'];
      final nights = await loadPulsePatternNights(_Repo(days: days));
      expect(nights.map((n) => n.dayId), days.take(kPulseNightsRead));
    });

    test('a failed read throws instead of returning an empty list', () async {
      expect(loadPulsePatternNights(_Repo(failFirst: 1)), throwsStateError);
    });
  });

  group('PulsePatternResearchPanel gating', () {
    for (final c in [
      (dev: false, pref: false),
      (dev: true, pref: false),
      (dev: false, pref: true),
    ]) {
      testWidgets('developer=${c.dev} pref=${c.pref}: no reads, nothing drawn',
          (t) async {
        final repo = _Repo(days: ['2026-10-06']);
        await _pumpPanel(t, repo, dev: c.dev, pref: c.pref);
        expect(repo.reads, 0);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text(kPulseResearchTitle), findsNothing);
      });
    }

    testWidgets('both on: reads, then shows the entry', (t) async {
      final repo = _Repo(days: ['2026-10-06']);
      await _pumpPanel(t, repo, dev: true, pref: true);
      expect(repo.reads, greaterThan(0));
      expect(find.text(kPulseResearchTitle), findsOneWidget);
    });

    testWidgets('a failed read is a retryable error, not an empty view',
        (t) async {
      final repo = _Repo(days: ['2026-10-06'], failFirst: 1);
      await _pumpPanel(t, repo, dev: true, pref: true);
      expect(find.text('Could not read the nights'), findsOneWidget);
      expect(find.text(kPulseResearchTitle), findsNothing);
      await t.tap(find.text('Try again'));
      await t.pump();
      await t.pump();
      expect(find.text('Could not read the nights'), findsNothing);
      expect(find.text(kPulseResearchTitle), findsOneWidget);
    });
  });
}

