import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/tracks/detection.dart';
import 'package:openstrap_edge/tracks/detection_windows.dart';

// Windows are built from the day's already-derived curves (hr_curve per minute,
// hrv_timeline per ~minute, activity_curve per 5 minutes), all in epoch
// seconds. Fixtures are spelled out here, independent of the builder.
final day = DateTime.utc(2026, 10, 1).millisecondsSinceEpoch ~/ 1000;
int at(int hour, [int minute = 0]) => day + hour * 3600 + minute * 60;

List<Map<String, num>> hrBetween(int from, int to, num bpm) => [
  for (var t = from; t < to; t += 60) {'t': t, 'v': bpm},
];

List<Map<String, num>> still(int from, int to, [num v = 0]) => [
  for (var t = from; t < to; t += 300) {'t': t, 'v': v},
];

List<Map<String, Object?>> build({
  List<Map<String, num>>? hr,
  List<Map<String, num>>? hrv,
  List<Map<String, num>>? activity,
  int? onset,
  int? offset,
  List<double>? rhr,
  List<double>? rmssd,
}) => TrackDetectionWindows.build(
  hrCurve: hr ?? const [],
  hrvTimeline: hrv ?? const [],
  activityCurve: activity ?? const [],
  sleepOnsetSec: onset ?? at(1),
  sleepOffsetSec: offset ?? at(8),
  rhrHistory: rhr ?? List.filled(8, 60.0),
  rmssdHistory: rmssd ?? List.filled(8, 45.0),
);

Map<String, Object?> only(List<Map<String, Object?>> w, String phase) =>
    w.singleWhere((m) => m['phase'] == phase);

void main() {
  group('early sleep', () {
    final hr = [...hrBetween(at(1), at(4), 68), ...hrBetween(at(4), at(8), 58)];
    final hrv = [
      for (var t = at(1, 5); t < at(8); t += 300)
        {'t': t, 'v': t < at(4) ? 30 : 50},
    ];

    test('first three hours of the night, measured values and baselines', () {
      final w = only(build(hr: hr, hrv: hrv), 'early_sleep');
      expect(w['start_ts'], at(1));
      expect(w['end_ts'], at(4));
      expect(w['hr'], 68);
      expect(w['rmssd'], 30);
      expect(w['baseline_hr'], 60);
      expect(w['baseline_rmssd'], 45);
      expect(w['coverage'], 1);
      expect(
        const TrackDetectors().alcohol(
          DetectionWindow.fromMap(w)!,
          const {'hr', 'hrv'},
        ),
        'early_sleep_hr_hrv',
      );
    });

    test('a short night is cut at wake, and coverage counts missing minutes',
        () {
      final w = only(
        build(
          hr: hrBetween(at(1), at(2), 68),
          hrv: hrv,
          onset: at(1),
          offset: at(2, 30),
        ),
        'early_sleep',
      );
      expect(w['end_ts'], at(2, 30));
      expect(w['coverage'], closeTo(60 / 90, 1e-9));
    });

    test('no HRV series: rmssd stays null, heart rate is never substituted', () {
      final w = only(build(hr: hr), 'early_sleep');
      expect(w['rmssd'], isNull);
      expect(w['hr'], 68);
      expect(
        const TrackDetectors().alcoholAbstain(
          DetectionWindow.fromMap(w)!,
          const {'hr', 'hrv'},
        ),
        DetectionAbstain.noHrvSeries,
      );
    });

    test('under seven nights of history there is no personal baseline', () {
      final w = only(
        build(hr: hr, hrv: hrv, rhr: [60, 60, 60], rmssd: [45, 45]),
        'early_sleep',
      );
      expect(w['baseline_hr'], isNull);
      expect(w['baseline_rmssd'], isNull);
      expect(
        const TrackDetectors().alcoholAbstain(
          DetectionWindow.fromMap(w)!,
          const {'hr', 'hrv'},
        ),
        DetectionAbstain.noBaseline,
      );
    });

    test('no sleep, no early-sleep window', () {
      final w = build(hr: hr, hrv: hrv, onset: 0, offset: 0);
      expect(w.where((m) => m['phase'] == 'early_sleep'), isEmpty);
    });
  });

  group('awake', () {
    // 09-13 resting at 70, 14:00 at 90, 16:00 at 90 but moving.
    final hr = [
      ...hrBetween(at(9), at(14), 70),
      ...hrBetween(at(14), at(15), 90),
      ...hrBetween(at(15), at(16), 70),
      ...hrBetween(at(16), at(17), 90),
    ];
    final activity = [
      ...still(at(9), at(16)),
      ...still(at(16), at(17), .6),
    ];

    test('hourly windows outside sleep, jump measured against the day median',
        () {
      final windows = build(hr: hr, activity: activity)
          .where((m) => m['phase'] == 'awake')
          .toList();
      final jump = windows.singleWhere((m) => m['start_ts'] == at(14));
      expect(jump['end_ts'], at(15));
      expect(jump['hr'], 90);
      expect(jump['motion'], 0);
      expect(jump['baseline_hr'], 70);
      expect(jump['coverage'], 1);
      final moving = windows.singleWhere((m) => m['start_ts'] == at(16));
      expect(moving['motion'], closeTo(.6, 1e-9));
      expect(
        const TrackDetectors().cannabis(
          DetectionWindow.fromMap(jump)!,
          const {'hr'},
        ),
        'resting_hr_jump',
      );
      expect(
        const TrackDetectors().cannabis(
          DetectionWindow.fromMap(moving)!,
          const {'hr'},
        ),
        isNull,
      );
    });

    test('nothing is built across the main sleep', () {
      final windows = build(
        hr: [...hrBetween(at(6), at(10), 70)],
        activity: still(at(6), at(10)),
      ).where((m) => m['phase'] == 'awake');
      expect(windows.map((m) => m['start_ts']), isNot(contains(at(7))));
      expect(windows.map((m) => m['start_ts']), contains(at(8)));
    });

    test('fewer than four resting hours: no day baseline, no jump claimed', () {
      final windows = build(
        hr: [...hrBetween(at(9), at(11), 70), ...hrBetween(at(14), at(15), 90)],
        activity: [...still(at(9), at(11)), ...still(at(14), at(15))],
      ).where((m) => m['phase'] == 'awake');
      expect(windows, isNotEmpty);
      expect(windows.every((m) => m['baseline_hr'] == null), isTrue);
    });

    test('no activity curve: motion unknown, so the cannabis detector abstains',
        () {
      final windows = build(hr: hr).where((m) => m['phase'] == 'awake');
      expect(windows.every((m) => m['motion'] == null), isTrue);
    });
  });
}
