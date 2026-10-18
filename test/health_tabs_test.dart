// Health is upstream's five sub-tabs:
// Overview · Explore · Trends · Vitals · Labs.
//
// What these pin:
//   * the five sub-tabs, in that order, opening on Overview, with Explore
//     fully on screen at 360 and 390 pt (it sits second for that reason);
//   * Overview: the night's rows in a fixed order, labelled with the night's
//     date, each opening its own MetricDetail ON that night; Observations
//     under them; the Heart Screener door only when Capabilities allows it;
//   * Explore: every family with Readiness and Stress in it, a metric with a
//     history listed once, empty measures folded into one card, and an
//     import-only SpO2 row only when an import wrote one;
//   * Trends: the three trend cards and Consistency, each card opening its
//     MetricDetail;
//   * Vitals: one day, named, with its heart rate range, breathing, skin
//     temperature and wear, and the rows that open a detail;
//   * Labs is the content it was, now at index 4.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
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
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/structure_harness.dart';

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
      // A fresh State per pump: it copies its data in initState.
      key: UniqueKey(),
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

MetricRow _row(WidgetTester t, String name) => t
    .widgetList<MetricRow>(find.byType(MetricRow))
    .singleWhere((r) => r.name == name);

Finder _rowNamed(String name) =>
    find.byWidgetPredicate((w) => w is MetricRow && w.name == name);

void main() {
  setUpAll(() async {
    // NapsScreen reads the nap edits straight from LocalDb, and a pushed
    // screen with no database factory throws an unhandled error. Every
    // other pushed screen goes through the fake repository.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_health_h2_tabs_test.db';
    await _loadType();
  });

  // ───────────────────── the five sub-tabs ─────────────────────
  group('sub-tabs', () {
    testWidgets('are exactly Overview, Explore, Trends, Vitals, Labs, in that '
        'order', (t) async {
      await _pump(t, _screen());
      expect(_tabs(t).items, ['Overview', 'Explore', 'Trends', 'Vitals', 'Labs']);
      for (final gone in ['Last night', 'Today']) {
        expect(
            find.descendant(of: find.byType(SubTabs), matching: find.text(gone)),
            findsNothing,
            reason: '$gone is no longer a sub-tab');
      }
    });

    testWidgets('open on Overview by default', (t) async {
      // A deep link (notification, /recap) lands on Health with no sub-tab
      // chosen, and that has to be Overview.
      await _pump(t, _screen());
      expect(_tabs(t).index, 0);
      expect(_rowNamed('Resting heart rate'), findsOneWidget);
      expect(find.text('Add a result'), findsNothing,
          reason: 'Labs is not the landing tab');
    });

    for (final (name, width) in [('360', 360.0), ('390', 390.0)]) {
      testWidgets('Explore is fully on screen at $name pt', (t) async {
        // Five chips do not all fit; Explore sits second so that it is never
        // the clipped one.
        await _pump(t, _screen(), size: Size(width, 2400));
        final r = t.getRect(find.descendant(
            of: find.byType(SubTabs), matching: find.text('Explore')));
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(width),
            reason: 'Explore clipped at the right edge of $name pt');
      });
    }

    testWidgets('tapping each chip shows that tab', (t) async {
      await _pump(t, _screen());
      // The chip row scrolls to the selected chip, so bring each one into
      // view before tapping it.
      for (final (i, label) in [
        (1, 'Explore'),
        (2, 'Trends'),
        (3, 'Vitals'),
        (4, 'Labs'),
        (0, 'Overview'),
      ]) {
        final chip = find.descendant(
            of: find.byType(SubTabs), matching: find.text(label));
        await t.ensureVisible(chip);
        await t.pumpAndSettle();
        await t.tap(chip);
        await t.pump();
        expect(_tabs(t).index, i, reason: label);
      }
    });
  });

  // ───────────────────── structure at phone sizes ─────────────────────
  // Not overflowing at 360x640, 390x844 and 2x text, scrolled to the bottom.
  Widget framed(HealthScreen s, {bool ecg = false}) => Scaffold(
        body: Provider<Capabilities>.value(value: _caps(ecg: ecg), child: s),
      );

  screenStructure('Health · Overview', framed(_screen(tab: 0), ecg: true), () {
    expect(find.text('Resting heart rate'), findsOneWidget);
    expect(find.text('Observations'), findsOneWidget);
    expect(find.byType(EcgEntryCard), findsOneWidget);
  });
  screenStructure('Health · Explore', framed(_screen(tab: 1)), () {
    expect(find.text('Heart & rhythm'), findsOneWidget);
  });
  screenStructure('Health · Trends', framed(_screen(tab: 2)), () {
    expect(find.text('Consistency'), findsOneWidget);
  });
  screenStructure('Health · Vitals', framed(_screen(tab: 3)), () {
    expect(find.text('Wear time'), findsOneWidget);
  });
  screenStructure('Health · Labs', framed(_screen(tab: 4)), () {
    expect(find.text('Add a result'), findsOneWidget);
  });

  // ───────────────────── Overview ─────────────────────
  group('Overview', () {
    testWidgets('rows come in the order Resting heart rate, HRV, Sleep, '
        'Stress, Respiratory rate', (t) async {
      await _pump(t, _screen());
      final ys = [
        for (final n in [
          'Resting heart rate',
          'HRV',
          'Sleep',
          'Stress',
          'Respiratory rate',
        ])
          _y(t, _rowNamed(n)),
      ];
      expect(ys, orderedEquals([...ys]..sort()),
          reason: 'rows are out of order: $ys');
      expect(ys.toSet().length, ys.length, reason: 'two rows share a line');
    });

    testWidgets('Observations come after the rows', (t) async {
      await _pump(t, _screen());
      expect(_y(t, find.text('Observations')),
          greaterThan(_y(t, _rowNamed('Respiratory rate'))));
    });

    testWidgets('a held-over night is labelled with its own date', (t) async {
      await _pump(t, _screen());
      final label = prettyDay(_night);
      expect(label, isNotEmpty);
      expect(_row(t, 'HRV').sub, contains(label),
          reason: 'a night held over from an earlier day says which night');
      expect(_row(t, 'Sleep').sub, label);
    });

    // Each row, and the detail a tap on it opens: its own metric, on the
    // night the row was read from.
    for (final (label, key) in [
      ('Resting heart rate', 'resting_hr'),
      ('HRV', 'hrv'),
      ('Sleep', 'sleep'),
      ('Stress', 'stress'),
      ('Respiratory rate', 'resp_rate'),
    ]) {
      testWidgets('$label opens MetricDetail($key) on the held-over night',
          (t) async {
        await _pump(t, _screen());
        await _tap(t, _rowNamed(label));
        final d = t.widget<MetricDetail>(find.byType(MetricDetail));
        expect(d.metricKey, key);
        expect(d.initialDay, _night);
      });
    }

    testWidgets("a night that is today's carries no day into the detail",
        (t) async {
      await _pump(t, _screen(data: _data(heldOver: false)));
      await _tap(t, _rowNamed('HRV'));
      expect(t.widget<MetricDetail>(find.byType(MetricDetail)).initialDay,
          isNull);
    });

    testWidgets('Heart Screener appears only when Capabilities says ecgEntry '
        'is available', (t) async {
      await _pump(t, _screen(), caps: _caps(ecg: false));
      expect(find.byType(EcgEntryCard), findsNothing);

      await _pump(t, _screen(), caps: _caps(ecg: true));
      expect(find.byType(EcgEntryCard), findsOneWidget);
    });

    testWidgets('a red illness watch shows its card', (t) async {
      await _pump(t, _screen(data: _data(illness: 'red')));
      expect(find.text('Recent nights add up to a raised resting heart rate'),
          findsOneWidget);
    });
  });

  // ───────────────────── Explore ─────────────────────
  group('Explore', () {
    testWidgets('lists every family, with Readiness and Stress in the list',
        (t) async {
      await _pump(t, _screen(tab: 1));
      for (final family in [
        'Recovery',
        'Heart & rhythm',
        'Sleep',
        'Breathing',
        'Movement & load',
        'Body & wear',
      ]) {
        expect(find.text(family), findsWidgets, reason: family);
      }
      expect(_rowNamed('Stress'), findsOneWidget,
          reason: 'Stress has a history and was missing from the catalogue');
    });

    testWidgets('a metric with a history appears once', (t) async {
      await _pump(t, _screen(tab: 1));
      for (final name in ['HRV', 'Resting heart rate', 'Steps', 'Strain']) {
        expect(_rowNamed(name), findsOneWidget, reason: name);
      }
    });

    testWidgets('a family with no history folds into one card', (t) async {
      await _pump(t, _screen(tab: 1));
      // Body & wear has nothing stored: one card, naming both, and no rows.
      expect(find.textContaining('Skin temperature · Wear time'),
          findsOneWidget);
      expect(_rowNamed('Wear time'), findsNothing,
          reason: 'an empty measure is named in the fold, not given a row');
      expect(find.text('Nothing measured here yet'), findsOneWidget);
    });

    testWidgets('SpO2 is listed only once an import has written it',
        (t) async {
      await _pump(t, _screen(tab: 1));
      expect(_rowNamed('Blood oxygen'), findsNothing,
          reason: 'no import, no SpO2 row');
      expect(find.textContaining('Blood oxygen'), findsNothing,
          reason: 'and no "not measured yet" claim about it either');

      await _pump(
          t,
          _screen(
              tab: 1,
              explore: ExploreData(counts: {..._explore.counts, 'spo2': 12})));
      expect(_rowNamed('Blood oxygen'), findsOneWidget);
      expect(_y(t, _rowNamed('Blood oxygen')),
          greaterThan(_y(t, find.text('Breathing'))));
      expect(_y(t, _rowNamed('Blood oxygen')),
          lessThan(_y(t, find.text('Movement & load'))),
          reason: 'the row belongs to Breathing');
    });

    for (final (label, key) in [
      ('Stress', 'stress'),
      ('HRV', 'hrv'),
    ]) {
      testWidgets('$label opens MetricDetail($key)', (t) async {
        await _pump(t, _screen(tab: 1));
        await _tap(t, _rowNamed(label));
        expect(
            t.widget<MetricDetail>(find.byType(MetricDetail)).metricKey, key);
      });
    }
  });

  // ───────────────────── Trends ─────────────────────
  group('Trends', () {
    testWidgets('three trend cards, then Consistency', (t) async {
      await _pump(t, _screen(tab: 2));
      final labels = [
        for (final c in t.widgetList<TrendCard>(find.byType(TrendCard))) c.label
      ];
      expect(labels, ['Resting heart rate', 'HRV', 'Time asleep']);
      expect(_y(t, find.text('Consistency')),
          greaterThan(_y(t, find.byType(TrendCard).last)));
    });

    for (final (label, key) in [
      ('Resting heart rate', 'resting_hr'),
      ('HRV', 'hrv'),
      ('Time asleep', 'sleep'),
    ]) {
      testWidgets('$label opens MetricDetail($key)', (t) async {
        await _pump(t, _screen(tab: 2));
        await _tap(
            t,
            find.byWidgetPredicate(
                (w) => w is TrendCard && w.label == label));
        expect(
            t.widget<MetricDetail>(find.byType(MetricDetail)).metricKey, key);
      });
    }
  });

  // ───────────────────── Vitals ─────────────────────
  group('Vitals', () {
    testWidgets("today's heart rate range, breathing, skin temperature and "
        'wear, once each', (t) async {
      await _pump(t, _screen(tab: 3));
      final hr = _row(t, 'Heart rate');
      expect(hr.value, '48 – 142');
      expect(hr.sub, 'Today');
      expect(_row(t, 'Respiratory rate').value, '14.2');
      expect(_row(t, 'Wear time').sub, '94% of the day');
    });

    testWidgets('skin temperature is a deviation in SD against your own nights',
        (t) async {
      await _pump(t, _screen(tab: 3));
      final skin = _row(t, 'Skin temperature');
      expect(skin.value, '+0.31');
      expect(skin.unit, 'SD');
      expect(skin.sub, contains('vs your own nights'));
    });

    for (final (label, key) in [
      ('Skin temperature', 'skin_temp'),
      ('Wear time', 'wear'),
    ]) {
      testWidgets('$label opens MetricDetail($key)', (t) async {
        await _pump(t, _screen(tab: 3));
        await _tap(t, _rowNamed(label));
        expect(
            t.widget<MetricDetail>(find.byType(MetricDetail)).metricKey, key);
      });
    }
  });

  // ───────────────────── Labs ─────────────────────
  group('Labs', () {
    testWidgets('keeps its content, at index 4', (t) async {
      await _pump(t, _screen(tab: 4));
      expect(_tabs(t).index, 4);
      expect(find.text('Add a result'), findsOneWidget);
      expect(find.textContaining('Last panel 2026-03-12'), findsOneWidget);
      expect(find.text('Ranges differ by lab. Use the one on your report.'),
          findsOneWidget);
    });

    testWidgets('with no results says so', (t) async {
      await _pump(t, _screen(tab: 4, labs: const LabsData()));
      expect(find.text('No lab results'), findsOneWidget);
      expect(find.text('Add a result'), findsOneWidget);
    });
  });

  // ───────────────────── skin temperature detail ─────────────────────
  group('skin temperature detail', () {
    testWidgets('says it is a deviation and points at a tab that exists',
        (t) async {
      await _pump(t, const MetricDetail('skin_temp', data: MetricData()));
      expect(_mentions('a deviation, not a temperature'), findsWidgets,
          reason: 'a suppressed series says why');
      expect(find.textContaining('Vitals'), findsWidgets,
          reason: 'Vitals is where the night is shown');
    });
  });
}
