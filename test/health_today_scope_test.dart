// Today combined current activity with historical wear and
// heart rate. Today may have only interim wake features (strain, steps, wear)
// and no derived day of its own; VitalsData.load then falls back to an earlier
// finalized day for the heart rate range and wear, and the tab printed that
// day's numbers under "Today" and ignored `daily.wear_min`.
//
// Today is strictly today: wear from today's own envelope, a heart rate range
// only when the vitals are for today, and an honest absence otherwise.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Map<String, dynamic> _env(num v, {String? unit}) =>
    {'value': v, 'confidence': .7, 'tier': 'ESTIMATE', 'unit': ?unit};

final _older = dayLabelOf(DateTime.now().subtract(const Duration(days: 5)));

HealthData _data({Map<String, dynamic>? wear}) => HealthData(today: {
      'status': {'today_day': todayLabel()},
      'daily': {
        'strain': _env(4.5),
        'steps': _env(1800, unit: 'steps'),
        'calories': _env(210, unit: 'kcal'),
        'wear_min': wear ?? _env(300, unit: 'min'),
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
    home: Scaffold(body: HealthScreen(data: d, vitals: v, tab: 1)),
  ));
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets("Today's wear time is today's own, not the older day's",
      (t) async {
    await _pump(t, _data(), _olderVitals);
    expect(find.text('5h 00m'), findsOneWidget, reason: 'daily.wear_min');
    expect(find.text('21h 40m'), findsNothing,
        reason: 'the older day\'s 1300 worn minutes');
    expect(find.textContaining('94%'), findsNothing,
        reason: 'the older day\'s coverage');
  });

  testWidgets('no heart rate range for today is an honest absence, not the '
      "older day's range", (t) async {
    await _pump(t, _data(), _olderVitals);
    expect(find.textContaining('142'), findsNothing);
    expect(find.textContaining('No heart rate range'), findsOneWidget);
    expect(find.textContaining(prettyDay(_older)), findsNothing,
        reason: 'nothing on Today is dated to another day');
  });

  testWidgets('an absent wear envelope for today is an absence card, not the '
      "older day's wear", (t) async {
    await _pump(
        t,
        _data(wear: {
          'value': '—',
          'confidence': 0,
          'tier': 'HIGH',
          'note': 'no_input:today_activity',
        }),
        _olderVitals);
    expect(find.text('21h 40m'), findsNothing);
    expect(find.textContaining('No wear time'), findsOneWidget);
  });

  testWidgets("vitals that are today's still show the range", (t) async {
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
    expect(find.textContaining('133'), findsOneWidget);
    expect(find.textContaining('No heart rate range'), findsNothing);
  });
}
