// 8AF C (red): three honesty bugs, each test named for the bug it pins
// (AGENTS.md 3.3, 4.1).
//
//   1. a night held over from an earlier date drew sparklines (trend arrows read
//      off a 24-day series) as though they described that night;
//   2. a gap card for a missing overnight metric could carry no reason at all
//      (stress missing on a night that had sleep);
//   3. a trend delta was drawn against a "1-day average".
//
// Health is pumped with `HealthScreen(data:, tab:)` and no AppState, the way the
// existing goldens do. Sub-tab order: Last night 0, Today 1, Trends 2, Explore 3, Labs 4.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/models/metric.dart' show Metric;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _heldNight = '2026-05-16';
const _heldNightLabel = '16 May';

Map<String, dynamic> _env(num v, {String tier = 'ESTIMATE'}) => {
      'value': v,
      'confidence': .8,
      'tier': tier,
      'inputs_used': const <String>[],
    };

int _noon(int daysAgo) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - daysAgo, 12)
          .millisecondsSinceEpoch ~/
      1000;
}

/// [n] stored days ending today, one per calendar day.
List<ChartPoint> _stored(int n, {double base = 50}) => [
      for (var i = n - 1; i >= 0; i--) (t: _noon(i), v: base + (n - 1 - i)),
    ];

/// Bounded pumps, not pumpAndSettle: a sub-tab that is still loading shows a
/// spinner that never settles, and "timed out" would hide what is on screen.
Future<void> _settled(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pump(WidgetTester t, HealthData d, {int tab = 0}) async {
  t.view.physicalSize = const Size(390 * 3, 6000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: HealthScreen(data: d, tab: tab)),
  ));
  await _settled(t);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_health_h2_honesty_test.db';
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ── 1 ──
  group('a held-over night draws no sparkline', () {
    // `getToday` serves the last scored night when today's has not settled. The
    // numbers describe THAT night, so a 24-day series beside them says nothing
    // about it, and the old Overview drew one on every row.
    final held = HealthData(
      today: {
        'status': {
          'today_day': '2026-05-20',
          'overnight_day': _heldNight,
          'showing_prior_overnight': true,
        },
        'daily': {'resting_hr': _env(52, tier: 'HIGH')},
        'sleep': {'duration_min': _env(465)},
        'hrv': {'rmssd': 68, 'confidence': .6},
        'resp': {'value': 14.2, 'confidence': .6},
        'illness': {'state': 'green'},
      },
      charts: {
        'resting_hr': _stored(24),
        'hrv': _stored(24, base: 60),
        'sleep': _stored(24, base: 420),
        'stress': _stored(24, base: 30),
        'resp_rate': _stored(24, base: 14),
      },
    );

    testWidgets(
        'held-over night: no row on Last night carries a series, so none draws a trend arrow',
        (t) async {
      await _pump(t, held);
      final rows = t.widgetList<MetricRow>(find.byType(MetricRow)).toList();
      expect(rows, isNotEmpty, reason: 'the night itself still has rows');
      for (final r in rows) {
        expect(r.series, isEmpty,
            reason: '"${r.name}" got a series on a one-night tab');
      }
      expect(find.byType(TrendCard), findsNothing);
      expect(
          find.byWidgetPredicate(
              (w) => w is CustomPaint && w.painter is LineChart),
          findsNothing);
    });

    testWidgets('a night with its own date draws none either', (t) async {
      await _pump(
          t,
          HealthData(
            today: {
              'daily': {'resting_hr': _env(52, tier: 'HIGH')},
              'sleep': {'duration_min': _env(465)},
            },
            charts: {'resting_hr': _stored(24), 'sleep': _stored(24, base: 420)},
          ));
      for (final r in t.widgetList<MetricRow>(find.byType(MetricRow))) {
        expect(r.series, isEmpty, reason: '"${r.name}"');
      }
    });

    testWidgets('the held-over night is labelled with its own date', (t) async {
      await _pump(t, held);
      expect(find.textContaining(_heldNightLabel), findsWidgets,
          reason: 'a night from an earlier date must say which night it is');
    });
  });

  // ── 2 ──
  group('every absence card states a reason', () {
    // Sleep was scored, the rest of the night's rows were not.
    final sleepOnly = HealthData(
      today: {
        'daily': {'resting_hr': _env(52, tier: 'HIGH')},
        'sleep': {'duration_min': _env(465)},
        'illness': {'state': 'green'},
      },
    );

    testWidgets(
        'stress missing on a night that had sleep gets a reason, not an empty gap card',
        (t) async {
      await _pump(t, sleepOnly);
      final cards = t.widgetList<StatusCard>(find.byType(StatusCard)).toList();
      final stress = cards.where((c) => c.what.toLowerCase().contains('stress'));
      expect(stress, isNotEmpty,
          reason: 'an absent stress row still owes the user a card');
      for (final c in stress) {
        expect(c.why.trim(), isNotEmpty);
        expect(c.why, 'Not enough overnight data for this one',
            reason: 'no specific reason was supplied, so the honest generic one');
      }
    });

    for (final (name, tab) in [('Last night', 0), ('Today', 1), ('Trends', 2)]) {
      testWidgets('$name: no StatusCard has an empty reason', (t) async {
        await _pump(t, sleepOnly, tab: tab);
        for (final c in t.widgetList<StatusCard>(find.byType(StatusCard))) {
          expect(c.why.trim(), isNotEmpty,
              reason: '"${c.what}" on $name has no reason');
        }
      });
    }

    testWidgets(
        'Last night with nothing measured: every card has a reason, and none says "no record of why"',
        (t) async {
      await _pump(t, const HealthData());
      final cards = t.widgetList<StatusCard>(find.byType(StatusCard)).toList();
      expect(cards, isNotEmpty);
      for (final c in cards) {
        expect(c.why.trim(), isNotEmpty, reason: '"${c.what}"');
        expect(c.why, isNot('The app has no record of why this is missing.'),
            reason: '"${c.what}" says it does not know instead of naming the gap');
      }
    });

    testWidgets(
        'Last night with sleep scored: no overnight gap card admits it does not know',
        (t) async {
      await _pump(t, sleepOnly);
      for (final c in t.widgetList<StatusCard>(find.byType(StatusCard))) {
        expect(c.why, isNot('The app has no record of why this is missing.'),
            reason: '"${c.what}"');
      }
    });

    testWidgets('a reason the pipeline gave outranks the generic one', (t) async {
      await _pump(
          t,
          HealthData(
            today: {
              'sleep': {'duration_min': _env(465)},
              'stress': {
                'value': '—',
                'confidence': 0,
                'tier': 'ESTIMATE',
                'note': 'only 12 min of resting beats',
              },
            },
          ));
      final stress = t
          .widgetList<StatusCard>(find.byType(StatusCard))
          .where((c) => c.what.toLowerCase().contains('stress'));
      expect(stress, isNotEmpty);
      for (final c in stress) {
        expect(c.why, contains('12 min'));
        expect(c.why, isNot('Not enough overnight data for this one'));
      }
    });
  });

  // ── 3 ──
  group('a trend delta needs a baseline of 7 prior days', () {
    // Trends draws a delta from the newest stored point against the mean of the
    // days before it. With one prior day that mean is "1-day average" and the
    // arrow is a coin flip dressed as a measurement.
    HealthData rhr(int stored) =>
        HealthData(charts: {'resting_hr': _stored(stored)});

    testWidgets('a delta against a 1-day average is not drawn', (t) async {
      await _pump(t, rhr(2), tab: 2);
      expect(find.textContaining('1-day average'), findsNothing);
      expect(find.text('Building your baseline (1 of 7 days)'), findsOneWidget);
    });

    testWidgets('1 prior day: the value is shown and the card passes no judgement',
        (t) async {
      await _pump(t, rhr(2), tab: 2);
      // The newest stored value is still on the card; only the delta goes.
      expect(find.textContaining('51'), findsWidgets);
      for (final c in t.widgetList<TrendCard>(find.byType(TrendCard))) {
        expect(c.good, isNull, reason: 'an arrow and hue need a baseline');
      }
    });

    testWidgets('6 prior days is still a building baseline', (t) async {
      await _pump(t, rhr(7), tab: 2);
      expect(find.text('Building your baseline (6 of 7 days)'), findsOneWidget);
      expect(find.textContaining('6-day average'), findsNothing);
    });

    testWidgets('7 prior days draws the delta and states its window', (t) async {
      await _pump(t, rhr(8), tab: 2);
      expect(find.textContaining('Building your baseline'), findsNothing);
      expect(find.text('vs your 7-day average'), findsOneWidget);
    });

    testWidgets('a sleep delta against the computed need needs no 7 days',
        (t) async {
      // The comparison there is the need, not an average of prior days, so the
      // 7-day rule is about averages only.
      await _pump(
          t,
          HealthData(
            charts: {'sleep': _stored(2, base: 400)},
            need: const Metric(value: 462, unit: 'min'),
          ),
          tab: 2);
      expect(find.textContaining('Building your baseline'), findsNothing);
      expect(find.textContaining('need'), findsWidgets);
    });
  });
}
