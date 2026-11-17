import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/smart_wake.dart';
import 'package:openstrap_edge/wake/wake_confounders.dart';

void main() {
  const now = 12 * 3600000;
  final recent = [
    for (var i = 0; i < 300; i++)
      <String, Object?>{
        'rec_ts': now ~/ 1000 - 300 + i,
        'hr': 54.0,
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
      },
  ];
  test('legacy gate uses historical baseline without baseline samples', () {
    expect(
      evaluateLegacyWakeHeavy(
        now,
        now + 600000,
        recent,
        const [],
        const ConfounderProfile(),
        nightMin: 50,
      ),
      isTrue,
    );
    expect(
      evaluateLegacyWakeHeavy(
        now,
        now + 600000,
        recent,
        const [],
        const ConfounderProfile(),
      ),
      isFalse,
    );
    expect(
      evaluateLegacyWakeHeavy(
        now,
        now + 600000,
        recent,
        const [],
        const ConfounderProfile(hrArousalBpm: 6),
        nightMin: 50,
      ),
      isFalse,
    );
    expect(
      evaluateLegacyWakeHeavy(
        now,
        now + 600000,
        recent,
        const [],
        const ConfounderProfile(alcohol: true, stress: true),
        nightMin: 50,
      ),
      isFalse,
    );
  });
  // WHY/CLAIM WAKE-MAIN-630: the reviewed late-meal counterexample must
  // remain a veto in the fork's shared evidence owner. A 0.025 g rise is
  // above the ordinary 0.02 g threshold but below the old 1.5x threshold.
  // catches: restoring the late-meal multiplier permits an early buzz.
  test('late meal cannot admit a rise between the two movement thresholds', () {
    final rows = [for (var i = 0; i < 300; i++) <String, Object?>{
      'rec_ts': now ~/ 1000 - 300 + i,
      'hr': 55.0, 'ax': 0.0, 'ay': 0.0,
      'az': i < 210 ? 1.0 : 1.025,
    }];
    final profile = wakeConfounders([
      WakeJournalDay(DateTime(2026, 10, 25), {'late meal'}, const {}),
    ]);
    expect(evaluateLegacyWakeHeavy(now, now + 1200000, rows, const [],
        const ConfounderProfile(), nightMin: 50), isFalse);
    expect(evaluateLegacyWakeHeavy(now, now + 1200000, rows, const [],
        profile, nightMin: 50), isFalse);
  });

  // WHY/CLAIM WAKE-MAIN-630-TREND: PR #630 discussion_r4564190134 gives
  // this exact five-minute trace. Its half-means fall while its trailing
  // three-minute halves rise 0.03 g. The longer window only adds a veto.
  // catches: judging only the workout's five-minute window admits the buzz.
  test('a longer workout trend window retains the three-minute veto', () {
    final rows = [for (var i = 0; i < 300; i++) <String, Object?>{
      'rec_ts': now ~/ 1000 - 300 + i,
      'hr': 55.0, 'ax': 0.0, 'ay': 0.0,
      'az': 1.0 + (i < 120 ? 0.04 : i < 210 ? 0.0 : 0.03),
    }];
    expect(evaluateLegacyWakeHeavy(now, now + 1200000, rows, const [],
        const ConfounderProfile(), nightMin: 50), isFalse);
    expect(evaluateLegacyWakeHeavy(now, now + 1200000, rows, const [],
        const ConfounderProfile(workout: true, protectionMinutes: 10,
            trendWindowMinutes: 5), nightMin: 50), isFalse);
  });

  test('late protection boundary and near baseline', () {
    expect(
      lateWakeProtection(
        nowMs: now,
        endMs: now + 300000,
        baselineHr: 50,
        recentHr: 52,
      ),
      isTrue,
    );
    expect(
      lateWakeProtection(
        nowMs: now,
        endMs: now + 300001,
        baselineHr: 50,
        recentHr: 52,
      ),
      isFalse,
    );
    expect(
      lateWakeProtection(
        nowMs: now,
        endMs: now + 300000,
        baselineHr: 50,
        recentHr: 52.01,
      ),
      isFalse,
    );
    expect(
      lateWakeProtection(
        nowMs: now,
        endMs: now + 600000,
        baselineHr: 50,
        recentHr: 48,
        minutes: 10,
      ),
      isTrue,
    );
  });
  test(
    'historical fallback selects completed supported main sleep by instant',
    () {
      Map<String, Object?> night(
        int end,
        double hr, {
        int partial = 0,
        int skipped = 0,
        int finalized = 1,
        String source = 'band',
      }) => {
        'partial': partial,
        'skipped': skipped,
        'finalized': finalized,
        'source': source,
        'window_json': jsonEncode({
          'value': {'onset_ms': end - 8 * 3600000, 'offset_ms': end},
        }),
        'payload_json': jsonEncode({
          'scalars': {'hr_min_night': hr},
        }),
      };
      final good = night(now - 24 * 3600000, 49);
      final candidates = [
        good,
        night(now - 3600000, 40, partial: 1),
        night(now - 2 * 3600000, 41, skipped: 1),
        night(now - 3 * 3600000, 42, finalized: 0),
        night(now - 4 * 3600000, 43, source: 'imported'),
        night(now + 3600000, 44),
        night(now - 5 * 3600000, 200),
      ];
      expect(precedingNightBaselineHeavy(candidates, now), 49);
      expect(
        precedingNightBaselineHeavy(candidates.reversed.toList(), now),
        49,
      );
      expect(
        precedingNightBaselineHeavy([good, night(now - 12 * 3600000, 51)], now),
        51,
      );
      expect(
        precedingNightBaselineHeavy([night(now - 73 * 3600000, 50)], now),
        isNull,
      );
      expect(
        precedingNightBaselineHeavy([
          {'finalized': 1, 'partial': 0, 'skipped': 0, 'window_json': 'broken'},
        ], now),
        isNull,
      );
    },
  );
}
