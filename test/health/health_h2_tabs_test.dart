// 8AF A + D, RED. Health is organised by question, one time scope per tab:
// Last night · Today · Trends · Labs.
//
// What these pin:
//   * the four sub-tabs, in that order, all on screen at 360 and 390 pt;
//   * Last night: one night, labelled with its date, no sparklines, rows in a
//     fixed order, each one tappable to its own destination, Observations then
//     Daytime sleep, and the Heart Screener door only when Capabilities allows
//     it;
//   * Today: Strain, Steps, Active minutes, Calories, Heart rate range, Wear
//     time, every row tappable;
//   * Trends: Body clock and Consistency first, then one list by family with
//     Readiness and Stress in it, empty families folded, the SpO2 note, and
//     MetricDetail opened from here starting on 30 days;
//   * Labs is the content it was, one tab to the right of where it was.
//
// The old-index migration lives in health_h2_migration_test.dart so that a
// missing symbol there cannot hide the screen tests here.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/lab_catalogue.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../proof/structure_harness.dart';

// ─────────────────────────── fixtures ───────────────────────────

/// Tests run on the held-over path on purpose: the night is NOT today's, so
/// "label the night's date" has a date to label and "SleepDetail for that
/// night" has a day that differs from today's.
// From the clock, not literals: a fixed date turns "today" into a held-over
// day at the next local midnight and the Today rows correctly go blank.
final _today = todayLabel();
final _night = dayLabelOf(() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - 1, 12);
}());

Map<String, dynamic> _env(num v, {String tier = 'ESTIMATE', String? unit}) => {
      'value': v,
      'confidence': .7,
      'tier': tier,
      'unit': ?unit,
    };

/// Thirty stored nights with a clear slope, so that a row which still reads a
/// series for a direction arrow draws one.
List<ChartPoint> _series(double start, double step) {
  final n = DateTime.now();
  return [
    for (var i = 29; i >= 0; i--)
      (
        t: DateTime(n.year, n.month, n.day - i, 12).millisecondsSinceEpoch ~/
            1000,
        v: start + (29 - i) * step,
      ),
  ];
}

HealthData _data({String illness = 'amber', bool heldOver = true}) => HealthData(
      today: {
        'status': {
          'today_day': _today,
          'overnight_day': _night,
          'showing_prior_overnight': heldOver,
          'overnight_state': 'ready',
        },
        'daily': {
          'readiness': _env(82, tier: 'HIGH'),
          'resting_hr': _env(52, tier: 'HIGH', unit: 'bpm'),
          'strain': _env(11.2),
          'steps': _env(8421, unit: 'steps'),
          'active_min': _env(74, unit: 'min'),
          'calories': _env(612, unit: 'kcal'),
          'wear_min': _env(1300, unit: 'min'),
        },
        'sleep': {'duration_min': _env(465)},
        'hrv': {'rmssd': 68, 'confidence': .6},
        'stress': {
          'value': 28,
          'score': 28,
          'level': 'Low',
          'confidence': .55,
          'tier': 'ESTIMATE',
        },
        'resp': {'value': 14.2, 'confidence': .6},
        'skin_temp': {
          'value': 0.31,
          'confidence': .5,
          'tier': 'RELATIVE',
          'inputs_used': const ['skin_temp_raw'],
          'note': 'relative deviation (z) vs your baseline',
        },
        'illness': {
          'state': illness,
          'z': 2.4,
          'date': _night,
        },
      },
      insights: const {
        'chronotype': {
          'value': {'type_label': 'slight evening type'},
          'confidence': .6,
          'tier': 'ESTIMATE',
        },
        'regularity': {
          'value': {'sri': 78, 'band': 'steady'},
          'confidence': .7,
          'tier': 'ESTIMATE',
        },
      },
      charts: {
        'resting_hr': _series(50, .2),
        'hrv': _series(40, 1),
        'sleep': _series(400, 2),
        'stress': _series(20, .5),
        'resp_rate': _series(13, .05),
      },
      daysWithData: 24,
      napMin: 35,
      napCount: 1,
      napDay: _night,
    );

final _vitals = VitalsData(
  day: _today,
  days: [_today, _night],
  timeline: {
    'highs': {
      'low_hr': {'v': 48},
      'peak_hr': {'v': 142},
      'avg_hr': {'v': 71},
    },
  },
  lungs: {
    'resp': {'value': 14.2, 'confidence': .6},
  },
  wear: {'worn_min': 1300, 'coverage_pct': 94},
  hrv: {'rmssd': 68.2},
);

/// Every series the Trends list can carry has history, except two families.
/// Breathing keeps one measure, so it stays a list and carries the SpO2 note;
/// Body & wear has none, so it must fold into one card.
const _explore = ExploreData(counts: {
  'readiness': 30,
  'stress': 28,
  'rhr': 30,
  'rmssd': 30,
  'hrv_cv': 30,
  'lf_hf': 30,
  'dip_pct': 30,
  'hrr_bpm': 30,
  'tst_min': 30,
  'efficiency': 30,
  'deep_min': 30,
  'rem_min': 30,
  'nap_min': 30,
  'resp_rate': 30,
  'brv_cv': 0,
  'steps': 30,
  'active_min': 30,
  'calories': 30,
  'strain': 30,
  'trimp': 30,
  'skin_temp_z': 0,
  'worn_min': 0,
});

const _labs = LabsData(markers: kLabMarkers, results: [
  {'marker': 'ldl', 'taken_on': '2026-03-12', 'value': 104.0, 'unit': 'mg/dL'},
  {'marker': 'hba1c', 'taken_on': '2026-03-12', 'value': 5.2, 'unit': '%'},
]);

/// Enough repository for the screens a tap lands on to load without throwing.
/// Forty derived days put the 30 day range on offer in MetricDetail, which is
/// what lets a test read which range it opened on.
class _Repo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) async =>
      {
        'points': [
          for (final p in _series(50, .2)) {'t': p.t, 'v': p.v},
        ],
      };

  @override
  Future<List<String>> availableDays() async {
    final n = DateTime.now();
    return [
      for (var i = 0; i < 40; i++)
        '${DateTime(n.year, n.month, n.day - i).year.toString().padLeft(4, '0')}-'
            '${DateTime(n.year, n.month, n.day - i).month.toString().padLeft(2, '0')}-'
            '${DateTime(n.year, n.month, n.day - i).day.toString().padLeft(2, '0')}',
    ];
  }

  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
  @override
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) async =>
      const {};
  @override
  Future<Map<String, dynamic>> getToday() async => const {};
  @override
  Future<Map<String, dynamic>> getDayNaps(String date) async => const {};
  @override
  Future<Map<String, dynamic>> getDayWear(String date) async => const {};
}

Capabilities _caps({bool ecg = false}) =>
    Capabilities(CapabilityInputs(ecgPaired: ecg));

Future<void> _loadType() async {
  final files = Directory('assets/fonts/Manrope')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ttf'));
  for (final family in const ['Manrope', '.SF Pro Text']) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(f
          .readAsBytes()
          .then((b) => ByteData.sublistView(Uint8List.fromList(b))));
    }
    await loader.load();
  }
}

HealthScreen _screen({
  int tab = 0,
  HealthData? data,
  VitalsData? vitals,
  ExploreData? explore,
  LabsData? labs,
}) =>
    HealthScreen(
      data: data ?? _data(),
      vitals: vitals ?? _vitals,
      explore: explore ?? _explore,
      labs: labs ?? _labs,
      tab: tab,
    );

/// [screen] over a real AppState (so MetricDetail's own reads have somewhere
/// to go) and a Capabilities built directly. Tall, so the lazy list builds
/// every row.
Future<void> _pump(
  WidgetTester t,
  Widget screen, {
  Capabilities? caps,
  Size size = const Size(390, 8000),
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  final app = AppState.forTesting()..repo = _Repo();
  addTearDown(app.dispose);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider(
          create: (_) => UnitsController.seed(UnitSystem.metric)),
      ChangeNotifierProvider(
          create: (_) =>
              ThemeController.seed(AppThemeChoice.light, Brightness.light)),
      ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
      Provider<Capabilities>.value(value: caps ?? _caps()),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: screen),
    ),
  ));
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
}

/// Lets a pushed route finish and its first (failing-safe) read land. A busy
/// spinner never settles, so this is bounded pumps and not pumpAndSettle.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tap(WidgetTester t, Finder f) async {
  expect(f, findsOneWidget, reason: 'row to tap is not on screen exactly once');
  await t.tap(f);
  await _settle(t);
}

double _y(WidgetTester t, Finder f) {
  expect(f, findsWidgets, reason: 'expected on screen to read its position');
  return t.getTopLeft(f.first).dy;
}

/// A Text whose content mentions [word], whatever the casing.
Finder _mentions(String word) => find.byWidgetPredicate(
    (w) => w is Text && (w.data ?? '').toLowerCase().contains(word.toLowerCase()));

SubTabs _tabs(WidgetTester t) => t.widget<SubTabs>(find.byType(SubTabs).first);

void main() {
  setUpAll(() async {
    // NapsScreen reads the nap edits straight from LocalDb, and a pushed
    // Naps screen with no database factory throws an unhandled error. Every
    // other pushed screen goes through the fake repository.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_health_h2_tabs_test.db';
    await _loadType();
  });

  // ───────────────────── the four sub-tabs ─────────────────────
  group('sub-tabs', () {
    testWidgets('are exactly Last night, Today, Trends, Labs, in that order',
        (t) async {
      await _pump(t, _screen());
      expect(_tabs(t).items, ['Last night', 'Today', 'Trends', 'Labs']);
      for (final gone in ['Overview', 'Explore', 'Vitals']) {
        expect(find.text(gone), findsNothing,
            reason: '$gone is no longer a sub-tab');
      }
    });

    testWidgets('open on Last night by default', (t) async {
      // A deep link (notification, /recap) lands on Health with no sub-tab
      // chosen, and that has to be Last night.
      await _pump(t, _screen());
      expect(_tabs(t).index, 0);
      expect(find.text('Readiness'), findsOneWidget);
      expect(find.text('Strain'), findsNothing,
          reason: 'Strain belongs to Today');
    });

    for (final (name, width) in [('360', 360.0), ('390', 390.0)]) {
      testWidgets('all four fit on screen at $name pt, none clipped',
          (t) async {
        await _pump(t, _screen(), size: Size(width, 2400));
        for (final label in _tabs(t).items) {
          final r = t.getRect(find.descendant(
              of: find.byType(SubTabs), matching: find.text(label)));
          expect(r.left, greaterThanOrEqualTo(0), reason: '$label clipped left');
          expect(r.right, lessThanOrEqualTo(width),
              reason: '$label clipped at the right edge of $name pt');
        }
        final scroller = find.descendant(
            of: find.byType(SubTabs), matching: find.byType(Scrollable));
        expect(t.state<ScrollableState>(scroller.first).position.maxScrollExtent,
            0,
            reason: 'the sub-tab row has to fit without scrolling at $name pt');
      });
    }

    testWidgets('tapping each chip shows that tab', (t) async {
      await _pump(t, _screen());
      await t.tap(find.text('Today'));
      await t.pump();
      expect(_tabs(t).index, 1);
      await t.tap(find.text('Trends'));
      await t.pump();
      expect(_tabs(t).index, 2);
      await t.tap(find.text('Labs'));
      await t.pump();
      expect(_tabs(t).index, 3);
      await t.tap(find.text('Last night'));
      await t.pump();
      expect(_tabs(t).index, 0);
    });
  });

  // ───────────────────── structure at phone sizes ─────────────────────
  // Not overflowing at 360x640, 390x844 and 2x text, scrolled to the bottom.
  Widget framed(HealthScreen s, {bool ecg = false}) => Scaffold(
        body: Provider<Capabilities>.value(value: _caps(ecg: ecg), child: s),
      );

  screenStructure('Health · Last night', framed(_screen(tab: 0), ecg: true), () {
    expect(find.text('Readiness'), findsOneWidget);
    expect(find.text('Daytime sleep'), findsOneWidget);
    expect(find.byType(EcgEntryCard), findsOneWidget);
  });
  screenStructure('Health · Today', framed(_screen(tab: 1)), () {
    expect(find.text('Strain'), findsOneWidget);
    expect(find.text('Wear time'), findsOneWidget);
  });
  screenStructure('Health · Trends', framed(_screen(tab: 2)), () {
    expect(find.text('Body clock'), findsOneWidget);
    expect(find.text('Consistency'), findsOneWidget);
  });
  screenStructure('Health · Labs', framed(_screen(tab: 3)), () {
    expect(find.text('Add a result'), findsOneWidget);
  });

  // ───────────────────── Last night ─────────────────────
  group('Last night', () {
    testWidgets('rows come in the order Readiness, Sleep, HRV, Resting heart '
        'rate, Respiratory rate, stress, Skin temperature', (t) async {
      await _pump(t, _screen());
      final ys = [
        _y(t, find.text('Readiness')),
        _y(t, find.text('Sleep')),
        _y(t, find.text('HRV')),
        _y(t, find.text('Resting heart rate')),
        _y(t, find.text('Respiratory rate')),
        _y(t, _mentions('stress')),
        _y(t, find.textContaining('Skin temperature')),
      ];
      expect(ys, orderedEquals([...ys]..sort()),
          reason: 'rows are out of order: $ys');
      expect(ys.toSet().length, ys.length, reason: 'two rows share a line');
    });

    testWidgets('Observations come after the rows and before Daytime sleep',
        (t) async {
      await _pump(t, _screen());
      final skin = _y(t, find.textContaining('Skin temperature'));
      final obs = _y(t, find.text('Observations'));
      final naps = _y(t, find.text('Daytime sleep'));
      expect(obs, greaterThan(skin));
      expect(naps, greaterThan(obs));
    });

    testWidgets('the night is labelled with its own date', (t) async {
      await _pump(t, _screen());
      final label = prettyDay(_night);
      expect(label, isNotEmpty);
      expect(find.textContaining(label), findsWidgets,
          reason: 'a night held over from an earlier day says which night');
    });

    testWidgets('draws no sparklines and no trend arrows (it is one night)',
        (t) async {
      await _pump(t, _screen());
      expect(find.byType(TrendCard), findsNothing);
      expect(find.byType(ChartFrame), findsNothing);
      for (final icon in [
        LucideIcons.arrowUpRight,
        LucideIcons.arrowDownRight,
        LucideIcons.arrowRight,
      ]) {
        expect(find.byIcon(icon), findsNothing,
            reason: 'a direction arrow is a history, and this tab has none');
      }
    });

    testWidgets('skin temperature is labelled "vs your usual" and explains SD',
        (t) async {
      await _pump(t, _screen());
      expect(find.textContaining('vs your usual'), findsOneWidget);
      expect(find.textContaining('standard deviation'), findsWidgets,
          reason: 'the SD unit has to be explained somewhere on the tab');
    });

    // Each row, and where a tap on it goes.
    final destinations = <(String, Finder Function(), void Function(WidgetTester))>[
      (
        'Readiness',
        () => find.text('Readiness'),
        (t) => expect(find.byType(ReadinessDetail), findsOneWidget)
      ),
      (
        'Sleep',
        () => find.text('Sleep'),
        (t) {
          expect(find.byType(SleepDetail), findsOneWidget);
          expect(find.byType(MetricDetail), findsNothing,
              reason: 'Sleep opens the night, not a metric drill-down');
          expect(t.widget<SleepDetail>(find.byType(SleepDetail)).day, _night,
              reason: 'the night the day used, opened directly');
        }
      ),
      for (final (label, key, finder) in <(String, String, Finder Function())>[
        ('HRV', 'hrv', () => find.text('HRV')),
        ('Resting heart rate', 'resting_hr',
            () => find.text('Resting heart rate')),
        ('Respiratory rate', 'resp_rate', () => find.text('Respiratory rate')),
        ('Overnight stress', 'stress', () => _mentions('stress')),
        ('Skin temperature', 'skin_temp',
            () => find.textContaining('Skin temperature')),
      ])
        (
          label,
          finder,
          (t) => expect(
              t.widget<MetricDetail>(find.byType(MetricDetail)).metricKey, key)
        ),
    ];
    for (final (label, finder, check) in destinations) {
      testWidgets('$label is tappable and opens its own destination',
          (t) async {
        await _pump(t, _screen());
        final f = finder();
        await t.tap(f.first);
        await _settle(t);
        check(t);
      });
    }

    testWidgets('a MetricDetail opened from Last night starts on Today',
        (t) async {
      // Only Trends asks for 30 days. A tile that says "last night" opens on
      // last night. When that night IS today's there is no day to carry and the
      // screen opens on Today; a held-over night opens on its own day (see
      // health_h2_held_over_detail_test.dart).
      await _pump(t, _screen(data: _data(heldOver: false)));
      await t.tap(find.text('HRV'));
      await _settle(t);
      final ranges = find.descendant(
          of: find.byType(MetricDetail), matching: find.byType(SubTabs));
      expect(ranges, findsOneWidget);
      expect(t.widget<SubTabs>(ranges).index, 0);
    });

    testWidgets('Daytime sleep opens the naps screen for that day', (t) async {
      await _pump(t, _screen());
      await t.tap(find.text('Daytime sleep'));
      await _settle(t);
      expect(find.byType(NapsScreen), findsOneWidget);
    });

    testWidgets('Heart Screener appears only when Capabilities says ecgEntry '
        'is available, and sits at the bottom', (t) async {
      await _pump(t, _screen(), caps: _caps(ecg: false));
      expect(find.byType(EcgEntryCard), findsNothing);

      await _pump(t, _screen(), caps: _caps(ecg: true));
      expect(find.byType(EcgEntryCard), findsOneWidget);
      expect(_y(t, find.byType(EcgEntryCard)),
          greaterThan(_y(t, find.text('Daytime sleep'))),
          reason: 'the ECG door is the last thing on Last night');
    });

    testWidgets('the illness card says the same thing it says on Home',
        (t) async {
      // One widget, one set of words, two screens. Health used to keep its own
      // copy of the titles, and the two drifted.
      await _pump(t, _screen(data: _data(illness: 'red')));
      expect(find.text('Several nights in a row were outside your normal range'),
          findsOneWidget);
    });
  });

  // ───────────────────── Today ─────────────────────
  group('Today', () {
    testWidgets('has Strain, Steps, Active minutes, Calories, Heart rate range '
        'and Wear time, once each', (t) async {
      await _pump(t, _screen(tab: 1));
      for (final name in [
        'Strain',
        'Steps',
        'Active minutes',
        'Calories',
        'Wear time',
      ]) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      expect(find.textContaining('Heart rate'), findsWidgets);
      expect(find.textContaining('142'), findsOneWidget,
          reason: 'the heart rate range shows its high');
      expect(find.textContaining('48'), findsWidgets);
    });

    testWidgets('rows are in order Strain, Steps, Active minutes, Calories, '
        'Heart rate, Wear time', (t) async {
      await _pump(t, _screen(tab: 1));
      final ys = [
        _y(t, find.text('Strain')),
        _y(t, find.text('Steps')),
        _y(t, find.text('Active minutes')),
        _y(t, find.text('Calories')),
        _y(t, find.textContaining('Heart rate')),
        _y(t, find.text('Wear time')),
      ];
      expect(ys, orderedEquals([...ys]..sort()), reason: '$ys');
    });

    testWidgets('has no night rows on it', (t) async {
      await _pump(t, _screen(tab: 1));
      for (final name in ['Readiness', 'Sleep', 'HRV', 'Resting heart rate']) {
        expect(find.text(name), findsNothing,
            reason: '$name is a Last night row');
      }
    });

    testWidgets('Strain opens DayStrainDetail', (t) async {
      await _pump(t, _screen(tab: 1));
      await _tap(t, find.text('Strain'));
      expect(find.byType(DayStrainDetail), findsOneWidget);
    });

    testWidgets('Steps opens DayStepsDetail', (t) async {
      await _pump(t, _screen(tab: 1));
      await _tap(t, find.text('Steps'));
      expect(find.byType(DayStepsDetail), findsOneWidget);
    });

    for (final (label, key) in [
      ('Active minutes', 'active_min'),
      ('Calories', 'calories'),
      ('Wear time', 'wear'),
    ]) {
      testWidgets('$label opens MetricDetail($key)', (t) async {
        await _pump(t, _screen(tab: 1));
        await _tap(t, find.text(label));
        expect(
            t.widget<MetricDetail>(find.byType(MetricDetail)).metricKey, key);
      });
    }

    // Phase 1 sent this row to MetricDetail('resting_hr'): the night's lowest
    // sustained rate, which says nothing about a low-to-high range for the day.
    // It opens that day's own heart rate view instead.
    testWidgets('the heart rate range opens the day\'s heart rate, not the resting-rate screen',
        (t) async {
      await _pump(t, _screen(tab: 1));
      await t.tap(find.textContaining('142'));
      await _settle(t);
      final timeline =
          t.widgetList<DayTimelineScreen>(find.byType(DayTimelineScreen));
      expect(timeline, hasLength(1));
      expect(timeline.single.day, _today,
          reason: 'the day the row describes, not "the newest derived one"');
      expect(
          find.byWidgetPredicate(
              (w) => w is MetricDetail && w.metricKey == 'resting_hr'),
          findsNothing);
    });
  });

  // ───────────────────── Trends ─────────────────────
  group('Trends', () {
    testWidgets('Body clock and Consistency come first, before any metric',
        (t) async {
      await _pump(t, _screen(tab: 2));
      final clock = _y(t, find.text('Body clock'));
      final consistency = _y(t, find.text('Consistency'));
      final firstFamily = _y(t, find.text('Heart & rhythm'));
      final firstMetric = _y(t, find.text('Resting heart rate'));
      expect(clock, lessThan(consistency));
      expect(consistency, lessThan(firstFamily));
      expect(consistency, lessThan(firstMetric));
    });

    testWidgets('the Body clock card no longer points at an Explore tab',
        (t) async {
      await _pump(t, _screen(tab: 2));
      expect(find.text('Explore'), findsNothing);
    });

    testWidgets('lists every family, with Readiness and Stress in the list',
        (t) async {
      await _pump(t, _screen(tab: 2));
      for (final family in [
        'Heart & rhythm',
        'Sleep',
        'Breathing',
        'Movement & load',
      ]) {
        expect(find.text(family), findsWidgets, reason: family);
      }
      expect(find.text('Readiness'), findsOneWidget,
          reason: 'Readiness has a history and was missing from the catalogue');
      expect(find.text('Stress'), findsOneWidget,
          reason: 'Stress has a history and was missing from the catalogue');
    });

    testWidgets('a metric with a history appears once', (t) async {
      await _pump(t, _screen(tab: 2));
      for (final name in ['HRV', 'Resting heart rate', 'Steps', 'Strain']) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
    });

    testWidgets('a family with no history folds into one card', (t) async {
      await _pump(t, _screen(tab: 2));
      // Body & wear has nothing stored: one card, naming both, and no rows.
      expect(find.textContaining('Skin temperature · Wear time'),
          findsOneWidget);
      expect(find.text('Wear time'), findsNothing,
          reason: 'an empty measure is named in the fold, not given a row');
      expect(find.text('Nothing measured here yet'), findsOneWidget);
    });

    testWidgets('Breathing says why there is no SpO2, in one line', (t) async {
      await _pump(t, _screen(tab: 2));
      expect(find.textContaining('SpO2'), findsOneWidget);
      final note = _y(t, find.textContaining('SpO2'));
      expect(note, greaterThan(_y(t, find.text('Breathing'))));
      expect(note, lessThan(_y(t, find.text('Movement & load'))),
          reason: 'the note belongs to Breathing');
    });

    for (final (label, key) in [
      ('Readiness', 'readiness'),
      ('Stress', 'stress'),
      ('HRV', 'hrv'),
    ]) {
      testWidgets('$label opens MetricDetail($key) on 30 days', (t) async {
        await _pump(t, _screen(tab: 2));
        await _tap(t, find.text(label));
        expect(
            t.widget<MetricDetail>(find.byType(MetricDetail)).metricKey, key);
        final ranges = find.descendant(
            of: find.byType(MetricDetail), matching: find.byType(SubTabs));
        expect(ranges, findsOneWidget,
            reason: 'the range switcher is drawn once the detail has loaded');
        final tabs = t.widget<SubTabs>(ranges);
        expect(tabs.items[tabs.index], '30 days');
      });
    }
  });

  // ───────────────────── Labs ─────────────────────
  group('Labs', () {
    testWidgets('keeps its content, one tab to the right of where it was',
        (t) async {
      await _pump(t, _screen(tab: 3));
      expect(_tabs(t).index, 3);
      expect(find.text('Add a result'), findsOneWidget);
      expect(find.textContaining('Last panel 2026-03-12'), findsOneWidget);
      expect(find.text('Ranges differ by lab. Use the one on your report.'),
          findsOneWidget);
    });

    testWidgets('with no results says so', (t) async {
      await _pump(t, _screen(tab: 3, labs: const LabsData()));
      expect(find.text('No lab results'), findsOneWidget);
      expect(find.text('Add a result'), findsOneWidget);
    });
  });

  // ───────────────────── skin temperature detail ─────────────────────
  group('skin temperature detail', () {
    testWidgets('states "no trend yet" and no longer sends you to Vitals',
        (t) async {
      await _pump(t, const MetricDetail('skin_temp', data: MetricData()));
      expect(_mentions('no trend yet'), findsWidgets,
          reason: 'a suppressed series says so, in those words');
      expect(find.textContaining('Vitals'), findsNothing,
          reason: 'there is no Vitals tab to be shown on');
    });
  });
}
