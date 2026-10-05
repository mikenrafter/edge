// 8AH, RED. The day scale: several lanes of one local day on one clock axis,
// sleep / nap / workout bands behind them, gaps that stay gaps, a day picker.
//
// ASSUMED API: test/explorer/support.dart, explorer_series_test.dart.
//   * explore-scale:day switches to intraday; the chosen day starts at today
//     (ExplorerView(today:)) and is NOT remembered across opens.
//   * One repo.getDayTimeline(day) read serves every lane for that day;
//     repo.getDayCalorieCurve(day) is read only when calories is picked.
//   * explore-day-prev / explore-day-next step one local calendar day;
//     next is inert on today (nothing in the future). explore-day-label shows
//     the day.
//   * ExplorePlotPainter.bands = exploreBands(timeline, ...) fractions;
//     a day with no sleep/workout has none.
//   * The readout lists a lane per picked metric ("<n> <unit>" or "—") and,
//     only for a day that has them, "Asleep" and "Workout" cells reading
//     "Yes"/"No" (the same words the Day timeline's chart key uses).
//   * x = (t - dayStart) / (dayEnd - dayStart) with the day's REAL local length.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/explorer_series.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/ui2/screens/explorer.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support.dart';

const _day = '2026-10-03';
final int _start = localDayStartSec(_day)!;
final int _end = localDayEndSec(_day)!;
double _at(num minute) => (minute * 60) / (_end - _start);
int _ts(int minute) => _start + minute * 60;

Map<String, dynamic> _timeline() => {
      'date': _day,
      'day_start': _start,
      // One-minute heart rate 08:00-09:00 and 12:00-12:30, nothing between.
      'hr': [
        for (var m = 480; m < 540; m++) {'t': _ts(m), 'v': 60 + (m - 480)},
        for (var m = 720; m < 750; m++) {'t': _ts(m), 'v': 90},
      ],
      // One-minute HRV samples 08:00-09:00, one missing (08:30).
      'hrv': [
        for (var m = 480; m < 540; m++)
          if (m != 510) {'t': _ts(m), 'v': 50 + (m - 480) / 5},
      ],
      'resp': const [],
      'skin_temp': const [],
      'activity': [
        {'t': _ts(480), 'v': 0.4},
        {'t': _ts(485), 'v': 0.0},
      ],
      'sleep': [
        {'onset_ts': _ts(-60), 'wake_ts': _ts(420)},
      ],
      'naps': const [],
      'sessions': [
        {'start_ts': _ts(1020), 'end_ts': _ts(1080)},
      ],
    };

ExplorerRepo _repo({Map<String, dynamic>? timeline, Map<String, dynamic>? cal}) =>
    ExplorerRepo(
      timelines: {_day: timeline ?? _timeline()},
      calorieCurves: {_day: cal},
    );

Future<void> _openDay(WidgetTester t, ExplorerRepo repo,
    {List<String> picks = const ['hr'], double width = 390, double scale = 1}) async {
  await pumpExplorer(t, repo, today: '2026-10-04', width: width, scale: scale);
  await tapKey(t, 'explore-scale:day');
  await tapKey(t, 'explore-day-prev');
  for (final k in picks) {
    await tapKey(t, 'explore-pick:$k');
  }
}

void main() {
  setUpAll(() async {
    await initPrefs();
    await loadType();
  });
  setUp(clearPrefs);

  group('day picker', () {
    testWidgets('starts today; prev reads the day before; next is inert on today',
        (t) async {
      final repo = _repo();
      await pumpExplorer(t, repo, today: '2026-10-04');
      await tapKey(t, 'explore-scale:day');
      await tapKey(t, 'explore-pick:hr');
      expect(repo.timelineCalls.last, '2026-10-04');
      final n = repo.timelineCalls.length;
      await tapKey(t, 'explore-day-next');
      expect(repo.timelineCalls.length, n, reason: 'no day after today');
      await tapKey(t, 'explore-day-prev');
      expect(repo.timelineCalls.last, '2026-10-03');
      await tapKey(t, 'explore-day-prev');
      expect(repo.timelineCalls.last, '2026-10-02');
      await tapKey(t, 'explore-day-next');
      expect(repo.timelineCalls.last, '2026-10-03');
      expect(find.byKey(const ValueKey('explore-day-label')), findsOneWidget);
    });

    testWidgets('prev steps by calendar day across a DST change', (t) async {
      final repo = ExplorerRepo();
      await pumpExplorer(t, repo, today: '2026-11-02');
      await tapKey(t, 'explore-scale:day');
      await tapKey(t, 'explore-pick:hr');
      await tapKey(t, 'explore-day-prev');
      expect(repo.timelineCalls.last, '2026-11-01');
      await tapKey(t, 'explore-day-prev');
      expect(repo.timelineCalls.last, '2026-10-31');
    });

    testWidgets('one day read serves every lane', (t) async {
      final repo = _repo();
      await _openDay(t, repo, picks: ['hr', 'hrv', 'activity']);
      expect(repo.timelineCalls.where((d) => d == _day).length, 1);
      expect(repo.calorieCalls, isEmpty,
          reason: 'the calorie curve is read only when calories is picked');
    });
  });

  group('lanes and bands on one axis', () {
    testWidgets('lines sit on the day clock at their real minute', (t) async {
      await _openDay(t, _repo(), picks: ['hr', 'hrv']);
      final hr = plotLine(t, 'hr'), hrv = plotLine(t, 'hrv');
      expect(hr.runs.first.first.at, closeTo(_at(480), 1e-9));
      expect(hr.runs.first.last.at, closeTo(_at(539), 1e-9));
      expect(hr.runs.last.first.at, closeTo(_at(720), 1e-9));
      expect(hrv.runs.first.first.at, closeTo(_at(480), 1e-9));
    });

    testWidgets('each lane is normalised to its own range', (t) async {
      await _openDay(t, _repo(), picks: ['hr', 'hrv']);
      for (final k in ['hr', 'hrv']) {
        final ys = [for (final r in plotLine(t, k).runs) for (final p in r) p.y];
        expect(ys.reduce((a, b) => a < b ? a : b), 0.0, reason: k);
        expect(ys.reduce((a, b) => a > b ? a : b), 1.0, reason: k);
      }
    });

    testWidgets('minutes with no heart rate break the line; nothing joins them',
        (t) async {
      await _openDay(t, _repo());
      expect(runLens(plotLine(t, 'hr')), [60, 30]);
    });

    testWidgets('HRV is a one-minute lane: one missing minute is a hole',
        (t) async {
      await _openDay(t, _repo(), picks: ['hrv']);
      // 08:00 .. 08:29 (30 samples) | 08:31 .. 08:59 (29 samples)
      expect(runLens(plotLine(t, 'hrv')), [30, 29]);
    });

    testWidgets('a 5-minute lane breaks at a missing sample and not between '
        'neighbours; sparse readings are never joined', (t) async {
      final tl = _timeline()
        ..['resp'] = [
          for (final m in [480, 485, 490, 500, 505])
            {'t': _ts(m), 'v': 14.0 + m % 3},
        ]
        ..['skin_temp'] = [
          {'t': _ts(480), 'v': 0.1},
          {'t': _ts(1200), 'v': 0.2},
        ];
      await _openDay(t, _repo(timeline: tl), picks: ['resp', 'skin_temp']);
      expect(runLens(plotLine(t, 'resp')), [3, 2]);
      expect(runLens(plotLine(t, 'skin_temp')), [1, 1],
          reason: 'two readings 12 h apart are two dots, not one line');
      await scrubAt(t, _at(840)); // 14:00, hours from either reading
      expect(readoutText(t, kExploreIntraday.singleWhere((s) => s.key == 'skin_temp').label),
          '—');
    });

    testWidgets('a sleep that began yesterday and a workout are bands, clipped',
        (t) async {
      await _openDay(t, _repo());
      final bands = plotPainter(t).bands;
      expect([for (final b in bands) b.kind],
          [ExploreBandKind.sleep, ExploreBandKind.workout]);
      expect(bands.first.from, 0.0);
      expect(bands.first.to, closeTo(_at(420), 1e-9));
      expect(bands.last.from, closeTo(_at(1020), 1e-9));
      expect(bands.last.to, closeTo(_at(1080), 1e-9));
    });

    testWidgets('a day with no sleep or workout has no bands at all', (t) async {
      final tl = _timeline()
        ..['sleep'] = const []
        ..['sessions'] = const [];
      await _openDay(t, _repo(timeline: tl));
      expect(plotPainter(t).bands, isEmpty);
      expect(readoutValue('Asleep'), findsNothing);
      expect(readoutValue('Workout'), findsNothing);
    });

    testWidgets('calories come from the stored curve as active energy; an unmeasured minute is a break',
        (t) async {
      final cal = {
        'minutes': [
          for (var m = 600; m < 603; m++)
            {'t': _ts(m), 'total': 3.0, 'active': 2.0, 'basal': 1.0},
          {'t': _ts(603), 'total': null, 'active': null, 'basal': null},
          for (var m = 604; m < 606; m++)
            {'t': _ts(m), 'total': 4.0, 'active': 3.0, 'basal': 1.0},
        ],
      };
      final repo = _repo(cal: cal);
      await _openDay(t, repo, picks: ['calories']);
      expect(repo.calorieCalls, contains(_day));
      expect(runLens(plotLine(t, 'calories')), [3, 2]);
      expect(plotLine(t, 'calories').runs.first.first.at, closeTo(_at(600), 1e-9));
    });

    testWidgets('a metric the day has nothing for has no line and says so',
        (t) async {
      await _openDay(t, _repo(), picks: ['hr', 'resp', 'calories']);
      expect([for (final l in plotPainter(t).lines) l.key], ['hr']);
      expect(find.byKey(const ValueKey('explore-empty:resp')), findsOneWidget);
      expect(find.byKey(const ValueKey('explore-empty:calories')), findsOneWidget);
    });

    testWidgets('a day with no stored timeline draws nothing', (t) async {
      final repo = ExplorerRepo();
      await pumpExplorer(t, repo, today: '2026-10-04');
      await tapKey(t, 'explore-scale:day');
      await tapKey(t, 'explore-pick:hr');
      expect(find.byKey(ExplorerView.plotKey), findsNothing);
      expect(find.byKey(const ValueKey('explore-no-data')), findsOneWidget);
    });
  });

  group('z is not offered intraday', () {
    testWidgets('the toggle is disabled and says why', (t) async {
      await _openDay(t, _repo());
      expect(find.byKey(const ValueKey('explore-z-reason:hr')), findsOneWidget);
      expect(
          t.widget<Text>(find.byKey(const ValueKey('explore-z-reason:hr'))).data,
          exploreZUnavailable('hr', const [], intraday: true));
    });
  });

  group('scrub readout on the clock', () {
    testWidgets('real values with units, and the clock time of the position',
        (t) async {
      await _openDay(t, _repo(), picks: ['hr', 'hrv']);
      await scrubAt(t, _at(510));
      final hr = readoutText(t, kExploreIntraday.singleWhere((s) => s.key == 'hr').label);
      expect(hr, contains('bpm'));
      final n = int.parse(RegExp(r'\d+').firstMatch(hr)!.group(0)!);
      expect(n, inInclusiveRange(84, 96), reason: 'minute ~510 reads ~90');
      final clock = t.widgetList<Text>(find.descendant(
          of: find.byKey(ChartKeyReadout.timeKey), matching: find.byType(Text)));
      expect([for (final x in clock) x.data ?? ''].join(' '),
          matches(RegExp(r'\d{1,2}:\d{2}')),
          reason: 'the time row names the clock time of the position');
    });

    testWidgets('inside a hole every lane without a reading there reads "—"',
        (t) async {
      await _openDay(t, _repo(), picks: ['hr', 'hrv']);
      await scrubAt(t, _at(600)); // 10:00, nothing recorded
      for (final k in ['hr', 'hrv']) {
        expect(readoutText(t, kExploreIntraday.singleWhere((s) => s.key == k).label),
            '—',
            reason: k);
      }
    });

    testWidgets('Asleep and Workout say Yes inside their stretch and No outside',
        (t) async {
      await _openDay(t, _repo());
      await scrubAt(t, _at(200));
      expect(readoutText(t, 'Asleep'), 'Yes');
      expect(readoutText(t, 'Workout'), 'No');
      await scrubAt(t, _at(1050));
      expect(readoutText(t, 'Asleep'), 'No');
      expect(readoutText(t, 'Workout'), 'Yes');
    });

    testWidgets('activity reads as the day screen does: a share of time moving',
        (t) async {
      await _openDay(t, _repo(), picks: ['activity']);
      await scrubAt(t, _at(481));
      final v = readoutText(t, kExploreIntraday.singleWhere((s) => s.key == 'activity').label);
      expect(v, anyOf(contains('40'), startsWith('0')),
          reason: 'at pixel resolution it is the 08:00 or the 08:05 bucket; a measured 0 is a value, not a dash');
    });
  });
}
