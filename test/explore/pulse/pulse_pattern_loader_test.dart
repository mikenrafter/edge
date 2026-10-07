// The read seam wiring for the pulse-pattern research view: what the loader
// makes of absent data, and that nothing is read while the view is gated off.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/explore/pulse/pulse_pattern_loader.dart';
import 'package:openstrap_edge/explore/pulse/pulse_pattern_night.dart';
import 'package:openstrap_edge/explore/pulse/pulse_pattern_research_screen.dart' show kPulseResearchTitle;
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
    this.failFirst = 0,
  });
  final List<String> days;
  final Map<String, Object?> cvhr;
  final Map<String, Object?> durationMin;
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
    return {'cvhr': cvhr[date]};
  }

  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async {
    reads++;
    return {'duration_min': durationMin[date]};
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

    test('minutes become hours: 360 of 420 analysed minutes is admitted',
        () async {
      final repo = _Repo(
        days: ['2026-10-06'],
        cvhr: {'2026-10-06': _present(3, 6.0)},
        durationMin: {'2026-10-06': 420},
      );
      final n = (await loadPulsePatternNights(repo)).single;
      expect(n.coverage, closeTo(6.0 / 7.0, 1e-9));
      expect(n.admitted, isTrue);
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

