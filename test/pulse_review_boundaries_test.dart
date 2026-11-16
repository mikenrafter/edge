import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/pulse_episode_worker.dart';
import 'support/pin_tz.dart';
import 'pulse_sleep_rr_fixture.dart';

// Boundary counts must not depend on the respiratory exclusion under test.
// Tiny periodic RR has pNN70=0, so these are independently normal windows.
final _normalHistory = List.generate(
  370,
  (i) => (1150 + 2 * sin(2 * pi * i / 3.7)).round(),
);

void main() {
  pinProcessTimeZone(
    "${Platform.environment['TZDIR'] ?? '/usr/share/zoneinfo'}/America/Denver",
  );
  // WHY: preserve reviewer probes for local dates and insufficient history.
  // # catches: using UTC dates or accepting only two earlier training dates.
  test('earlier local dates across UTC date boundary and thin history', () {
    expect(DateTime(2026, 11, 10).timeZoneOffset.inMinutes, -420);
    final target = DateTime(2026, 11, 10, 0, 5).millisecondsSinceEpoch;
    for (final days in [2, 3]) {
      final rows = <Map<String, Object?>>[], context = <Map<String, Object?>>[];
      void add(int start, int minutes, List<int> rr) {
        var t = start, i = 0;
        while (t < start + minutes * 60000) {
          final value = rr[i % rr.length];
          t += value;
          rows.add({
            'device_id': '',
            'ts_ms': t,
            'rec_ts': t ~/ 1000,
            'beat_index': 0,
            'beat_ts_ms': t,
            'rr_ms': value,
          });
          i++;
        }
        for (var w = start; w < start + minutes * 60000; w += 300000) {
          context.add({
            'source': '',
            'start_ms': w,
            'motion_samples': 300,
            'moving_samples': 0,
            'wrist': 1,
            'wear_samples': 300,
            'sleep_samples': 300,
            'sleep_known': 300,
          });
        }
      }

      for (var day = days; day > 0; day--) {
        add(
          DateTime(2026, 11, 10 - day, 22).millisecondsSinceEpoch,
          90,
          _normalHistory,
        );
      }
      // Same local date cannot train today, including across a UTC boundary.
      add(target - 300000, 5, _normalHistory);
      final random = Random(53);
      add(target, 30, List.generate(5000, (_) => 950 + random.nextInt(400)));
      rows.sort((a, b) => (a['ts_ms'] as int).compareTo(b['ts_ms'] as int));
      final result = detectPulseEpisodesHeavy(
        PulseDetectionInput(
          rows,
          target + 1800000,
          target,
          evaluateTo: target + 1200000,
          sourceStarts: {
            '': DateTime(2026, 11, 10 - days, 22).millisecondsSinceEpoch,
          },
          contextRows: context,
        ),
      );
      final w = result.detection.windows.first;
      expect(w.baselineDays, days);
      expect(w.baselineWindows, 18 * days);
      expect(
        w.toJson()['baseline']['status'],
        days == 3 ? 'ready' : 'calibrating',
      );
      expect(result.detection.episodes, hasLength(1));
    }
  });
  // WHY: preserve the reviewer's 239/240 sleep-support boundary and missing-input probe.
  // # catches: vetoing thin sleep evidence or withholding alerts without 1 Hz context.
  test(
    'sleep evidence requires 240 samples; missing sensors remain eligible',
    () {
      final rows = <Map<String, Object?>>[];
      var time = 0, index = 0;
      final rr = sleepRrFixtures.first;
      while (time < 1500000) {
        final value = rr[index++ % rr.length];
        time += value;
        rows.add({
          'device_id': '',
          'ts_ms': time,
          'rec_ts': time ~/ 1000,
          'beat_index': 0,
          'beat_ts_ms': time,
          'rr_ms': value,
        });
      }
      for (final samples in [239, 240, 299, 300]) {
        final context = [
          for (var t = 0; t < 1500000; t += 300000)
            {
              'source': '',
              'start_ms': t,
              'motion_samples': 300,
              'moving_samples': 0,
              'wrist': 1,
              'wear_samples': 300,
              'sleep_samples': samples,
              'sleep_known': 300,
            },
        ];
        final result = detectPulseEpisodesHeavy(
          PulseDetectionInput(
            rows,
            1500000,
            0,
            evaluateTo: 900000,
            contextRows: context,
          ),
        );
        expect(result.detection.episodes, hasLength(samples < 240 ? 1 : 0));
      }
      final missing = detectPulseEpisodesHeavy(
        PulseDetectionInput(
          rows,
          1500000,
          0,
          evaluateTo: 900000,
          sleepSpans: [
            [0, 1500000],
          ],
        ),
      );
      expect(missing.detection.episodes, hasLength(1));
      expect(missing.detection.episodes.single.alertEligible, isTrue);
    },
  );
  // WHY: preserve exact reviewer half-open halo boundaries.
  // # catches: excluding touching windows or admitting a one-minute overlap.
  test('episode thirty-minute halo has exact half-open boundaries', () {
    const target = 3 * 86400000;
    final beats = <ana.PulseBeatInput>[],
        context = <int, ana.PulseWindowContext>{};
    void add(int start, int minutes, List<int> rr) {
      var t = start, i = 0;
      while (t < start + minutes * 60000) {
        final value = rr[i % rr.length];
        t += value;
        beats.add(
          ana.PulseBeatInput(
            id: '$start:$i',
            source: 'strap',
            index: beats.length,
            timeMs: t,
            rawMs: value.toDouble(),
          ),
        );
        i++;
      }
      for (var w = start; w < start + minutes * 60000; w += 300000) {
        context[w] = ana.PulseWindowContext(
          asleep: true,
          motion: false,
          wear: true,
          day: '2026-11-${(7 + start ~/ 86400000).toString().padLeft(2, '0')}',
        );
      }
    }

    for (var day = 0; day < 3; day++) {
      add(day * 86400000, 55, _normalHistory);
    }
    final random = Random(53);
    add(target, 30, List.generate(5000, (_) => 950 + random.nextInt(400)));
    for (final kind in [
      'none',
      'leftHalo',
      'rightTouch',
      'rightOneMinuteOverlap',
    ]) {
      final excluded = <List<int>>[];
      for (var day = 0; day < 3; day++) {
        final t = day * 86400000;
        if (kind == 'leftHalo') {
          excluded.add([t + 55 * 60000, t + 65 * 60000]);
        }
        if (kind == 'rightTouch') {
          excluded.add([t - 40 * 60000, t - 30 * 60000]);
        }
        if (kind == 'rightOneMinuteOverlap') {
          excluded.add([t - 40 * 60000, t - 29 * 60000]);
        }
      }
      final result = ana.detectPulseEpisodes(
        beats,
        completeThroughMs: target + 1800000,
        sourceStartMs: 0,
        evaluateFromMs: target,
        evaluateToMs: target + 1200000,
        context: context,
        baselineExclusions: {'strap': excluded},
      );
      expect(
        result.windows.first.baselineWindows,
        {
          'none': 33,
          'leftHalo': 15,
          'rightTouch': 33,
          'rightOneMinuteOverlap': 30,
        }[kind],
      );
    }
  });
}
