// The scrubbed values live in a row under the chart, in the
// chart's own key. Synthetic fixtures; no device or personal data.
//
//   • day_hr_gaps      the day heart-rate chart with a hole in it: Movement,
//                      Heart rate, Asleep, Workout and "Not recorded", with the
//                      latest values under each.
//   • day_hr_no_gaps   a fully worn day: no "Not recorded" key at all.
//   • day_hr_on_gap    the finger on the hole: every series "—", and "Not
//                      recorded" says "Here".
//   • two_series   a framed two-series chart with a gap, values under the
//                      legend entries.
//   • row              the row on its own, scrubbed value and scrubbed gap.
//
// Same capture rules as affected_views_test.dart: light/dark, 1x/2x text,
// bundled fonts, committed baselines under fixtures/proof_goldens/chart_key_*.png.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/ui2/profile/gallery.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'ui2_sync_alerts_views_test.dart' show loadFonts;

const _day = '2026-08-12';
final int _start = localDayStartSec(_day)!;
int _at(int h, [int m = 0]) => _start + h * 3600 + m * 60;

typedef _Act = Future<void> Function(WidgetTester t);

Map<String, dynamic> _timeline({required bool gaps}) => {
      'date': _day,
      'day_start': _start,
      'hr': [
        for (var m = gaps ? 300 : 0; m < (gaps ? 1200 : 1440); m++)
          // A hole from 11:00 to 12:30 when the day has one.
          if (!(gaps && m >= 660 && m < 750))
            {'t': _start + m * 60, 'v': 56 + (m * 7 % 41)},
      ],
      'activity': [
        for (var m = gaps ? 300 : 0; m < (gaps ? 1200 : 1440); m += 5)
          if (!(gaps && m >= 660 && m < 750))
            {'t': _start + m * 60, 'v': (m ~/ 5 % 9) / 10},
      ],
      'sleep': gaps
          ? [
              {'onset_ts': _start - 3600, 'wake_ts': _at(6)}
            ]
          : const [],
      'naps': const [],
      'sessions': gaps
          ? [
              {'start_ts': _at(17), 'end_ts': _at(18)}
            ]
          : const [],
    };

Widget _dayHr({required bool gaps}) => Builder(
      builder: (c) => Scaffold(
        body: ListView(children: [
          ...timelineBody(
            c,
            TimelineData(
              day: _day,
              graph: dayGraph(_timeline(gaps: gaps)),
            ),
          ),
        ]),
      ),
    );

Future<void> _tapPlot(WidgetTester t, double frac) async {
  final box = t.getRect(find.byType(ChartScrub));
  await t.tapAt(Offset(box.left + box.width * frac, box.center.dy));
}

void main() {
  setUpAll(loadFonts);
  final fixtures = <String, (double, Widget, _Act?)>{
    'day_hr_gaps': (900, _dayHr(gaps: true), null),
    'day_hr_no_gaps': (900, _dayHr(gaps: false), null),
    // 11:45 is inside the hole (minute 705 of 1440).
    'day_hr_on_gap': (900, _dayHr(gaps: true), (t) => _tapPlot(t, 705 / 1440)),
    'day_hr_scrubbed': (900, _dayHr(gaps: true), (t) => _tapPlot(t, 15 / 24)),
    'two_series': (
      900,
      Builder(
        builder: (c) => Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(S.x4),
            child: galleryCases()['chart_key_readout']!,
          ),
        ),
      ),
      null,
    ),
    'row': (
      1000,
      Builder(
        builder: (c) => Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(S.x4),
            child: galleryCases()['chart_key_readout_row']!,
          ),
        ),
      ),
      null,
    ),
  };
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final fixture in fixtures.entries) {
        final name = 'chart_key_${fixture.key}_${brightness.name}_${scale.toInt()}x';
        testWidgets(name, (tester) async {
          final boundary = GlobalKey();
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(390, fixture.value.$1);
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: RepaintBoundary(key: boundary, child: fixture.value.$2),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          if (fixture.value.$3 case final act?) {
            await act(tester);
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byKey(boundary),
            matchesGoldenFile('fixtures/proof_goldens/$name.png'),
          );
        });
      }
    }
  }
}
