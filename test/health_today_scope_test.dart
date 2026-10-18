// Today combined current activity with historical wear and
// heart rate. Today may have only interim wake features (strain, steps, wear)
// and no derived day of its own; VitalsData.load then falls back to an earlier
// finalized day for the heart rate range and wear, and the tab printed that
// day's numbers under "Today".
//
// Health has no Today sub-tab any more; the same read now fills Vitals, which
// shows ONE day and names it. What is pinned: a fallen-back day's heart rate
// range and wear are labelled with THAT day, never "Today"; today's own vitals
// are labelled Today.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Map<String, dynamic> _env(num v, {String? unit}) =>
    {'value': v, 'confidence': .7, 'tier': 'ESTIMATE', 'unit': ?unit};

final _older = dayLabelOf(DateTime.now().subtract(const Duration(days: 5)));

HealthData _data() => HealthData(today: {
      'status': {'today_day': todayLabel()},
      'daily': {
        'strain': _env(4.5),
        'steps': _env(1800, unit: 'steps'),
        'calories': _env(210, unit: 'kcal'),
        'wear_min': _env(300, unit: 'min'),
      },
    });

/// The newest FINALIZED day, five days ago: what the loader falls back to.
final _olderVitals = VitalsData(
  day: _older,
  days: [_older],
  timeline: const {
    'highs': {
      'low_hr': {'v': 48},
      'peak_hr': {'v': 142},
    },
  },
  wear: const {'worn_min': 1300, 'coverage_pct': 94},
);

Future<void> _pump(WidgetTester t, HealthData d, VitalsData v) async {
  t.view.physicalSize = const Size(390 * 3, 6000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: HealthScreen(data: d, vitals: v, tab: 3)),
  ));
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

MetricRow _row(WidgetTester t, String name) => t
    .widgetList<MetricRow>(find.byType(MetricRow))
    .singleWhere((r) => r.name == name);

void main() {
  testWidgets("an older day's heart rate range is dated to that day, not "
      'Today', (t) async {
    await _pump(t, _data(), _olderVitals);
    final hr = _row(t, 'Heart rate');
    expect(hr.value, '48 – 142');
    expect(hr.sub, prettyDay(_older));
    expect(hr.sub, isNot('Today'));
  });

  testWidgets("an older day's wear is that day's coverage, not \"the day\"",
      (t) async {
    await _pump(t, _data(), _olderVitals);
    final wear = _row(t, 'Wear time');
    expect(wear.value, '21h 40m');
    expect(wear.sub, contains(prettyDay(_older)));
    expect(wear.sub, isNot(contains('the day')));
  });

  testWidgets("vitals that are today's are labelled Today", (t) async {
    final v = VitalsData(
      day: todayLabel(),
      days: [todayLabel()],
      timeline: const {
        'highs': {
          'low_hr': {'v': 51},
          'peak_hr': {'v': 133},
        },
      },
      wear: const {'worn_min': 300, 'coverage_pct': 21},
    );
    await _pump(t, _data(), v);
    final hr = _row(t, 'Heart rate');
    expect(hr.value, '51 – 133');
    expect(hr.sub, 'Today');
    expect(_row(t, 'Wear time').sub, '21% of the day');
  });
}
