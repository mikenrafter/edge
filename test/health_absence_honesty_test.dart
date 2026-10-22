// Three honesty bugs, each test named for the bug it pins
// (AGENTS.md 3.3, 4.1).
//
//   1. a night held over from an earlier date was stated as last night's;
//   2. a gap card for a missing overnight metric could carry no reason at all
//      (stress missing on a night that had sleep);
//   3. a trend delta was drawn against a "1-day average".
//
// Health is pumped with `HealthScreen(data:, tab:)` and no AppState, the way the
// existing goldens do. Sub-tab order: Overview 0, Explore 1, Trends 2,
// Vitals 3, Labs 4.
//
// (Overview rows carry a sparkline again, as upstream's Overview does: the
// series ends at the night the row names, so it is that night's history, and
// the row says which night. The old "no series on a one-night tab" cases left
// with the Last night tab.)

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
      for (var i = n - 1; i >= 0; i--) ChartPoint(t: _noon(i), v: base + (n - 1 - i)),
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

/// An absent metric keeps its row in the rows surface (so first launch and
/// loaded are the same card): a dash, and the reason as the row's status line.
Iterable<MetricRow> _emptyRows(WidgetTester t) =>
    t.widgetList<MetricRow>(find.byType(MetricRow)).where((r) => r.value == '—');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_health_h2_honesty_test.db';
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ── 1 ──
  group('a held-over night says which night it is', () {
    // `getToday` serves the last scored night when today's has not settled. The
    // numbers describe THAT night, and a row that says "Last night" about it
    // states a date the data does not support.
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
      final stress =
          _emptyRows(t).where((r) => r.name.toLowerCase().contains('stress'));
      expect(stress, isNotEmpty,
          reason: 'an absent stress row keeps its slot, with a dash');
      for (final r in stress) {
        expect(r.sub.trim(), isNotEmpty);
        expect(r.sub, 'Not enough overnight data for this one',
            reason: 'no specific reason was supplied, so the honest generic one');
      }
    });

    for (final (name, tab) in [('Overview', 0), ('Trends', 2)]) {
      testWidgets('$name: no StatusCard has an empty reason', (t) async {
        await _pump(t, sleepOnly, tab: tab);
        for (final c in t.widgetList<StatusCard>(find.byType(StatusCard))) {
          expect(c.why.trim(), isNotEmpty,
              reason: '"${c.what}" on $name has no reason');
        }
      });
    }

    testWidgets(
        'Overview with nothing measured: every card has a reason, and none says "no record of why"',
        (t) async {
      await _pump(t, const HealthData());
      final rows = _emptyRows(t).toList();
      expect(rows, isNotEmpty);
      for (final r in rows) {
        expect(r.sub.trim(), isNotEmpty, reason: '"${r.name}"');
        expect(r.sub, isNot('The app has no record of why this is missing.'),
            reason: '"${r.name}" says it does not know instead of naming the gap');
      }
    });

    testWidgets(
        'Overview with sleep scored: no overnight gap card admits it does not know',
        (t) async {
      await _pump(t, sleepOnly);
      for (final c in t.widgetList<StatusCard>(find.byType(StatusCard))) {
        expect(c.why, isNot('The app has no record of why this is missing.'),
            reason: '"${c.what}"');
      }
      for (final r in _emptyRows(t)) {
        expect(r.sub, isNot('The app has no record of why this is missing.'),
            reason: '"${r.name}"');
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
      final stress =
          _emptyRows(t).where((r) => r.name.toLowerCase().contains('stress'));
      expect(stress, isNotEmpty);
      for (final r in stress) {
        expect(r.sub, contains('12 min'));
        expect(r.sub, isNot('Not enough overnight data for this one'));
      }
    });
  });

  // ── 3 ──
  group('a trend card judges only against a usual range', () {
    // Trends once drew a delta from the newest stored point against the mean
    // of the days before it. With one prior day that mean is a "1-day average"
    // and the arrow is a coin flip dressed as a measurement. Trends now judges
    // against the usual range, which abstains until there is one.
    HealthData rhr(int stored) =>
        HealthData(charts: {'resting_hr': _stored(stored)});

    testWidgets('a delta against a 1-day average is not drawn', (t) async {
      await _pump(t, rhr(2), tab: 2);
      expect(find.textContaining('average'), findsNothing);
      expect(find.text('Your usual range appears after 14 days. 2 so far.'),
          findsOneWidget);
    });

    testWidgets('1 prior day: the value is shown and the card passes no judgement',
        (t) async {
      await _pump(t, rhr(2), tab: 2);
      // The newest stored value is still on the card; only the delta goes.
      expect(find.textContaining('51'), findsWidgets);
      for (final c in t.widgetList<TrendCard>(find.byType(TrendCard))) {
        expect(c.good, isNull, reason: 'an arrow and hue need a baseline');
        expect(c.band, isNull);
      }
    });

    testWidgets('a long series without the pipeline baseline still abstains',
        (t) async {
      // Resting heart rate's usual range is the pipeline's baseline and
      // nothing else: thirty stored days are not filled in as one.
      await _pump(t, rhr(30), tab: 2);
      final card = t
          .widgetList<TrendCard>(find.byType(TrendCard))
          .singleWhere((c) => c.label == 'Resting heart rate');
      expect(card.band, isNull);
      expect(card.good, isNull);
      expect(card.delta, isEmpty);
      expect(find.textContaining('no usual range yet'), findsOneWidget);
    });

    testWidgets('a sleep delta against the computed need needs no usual range',
        (t) async {
      // The comparison there is the need, not a range of prior days.
      await _pump(
          t,
          HealthData(
            charts: {'sleep': _stored(2, base: 400)},
            need: const Metric(value: 462, unit: 'min'),
          ),
          tab: 2);
      expect(find.textContaining('usual range appears'), findsNothing);
      expect(find.textContaining('need'), findsWidgets);
    });
  });
}
