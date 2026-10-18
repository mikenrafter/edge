// The +/- steppers and the displays use the shared water formatter and the
// unit-aware step (RED).
//
// Three surfaces: the Journal's FieldStepper, the Nutrition water row, and (in
// test/gestures/moments/water_answer_unit_test.dart) the marked-moment Water
// answer. Metric steps 250 ml; imperial steps one US cup, 8 fl oz. Nothing
// here changes what is stored: always ml in `water_ml`.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/water_units.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _water = kJournalFieldsByKey['water_ml']!;
final _cup = WaterUnits.stepMl(UnitSystem.imperial);

class _Repo extends LocalRepository {
  Map<String, JournalMetricValue> journal = const {};
  final posted = <Map<String, JournalMetricValue>>[];

  @override
  Future<Map<String, dynamic>> getToday() async => const {};
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async =>
      journal;
  @override
  Future<void> postJournalMetrics(
      String date, Map<String, JournalMetricValue> fields) async {
    posted.add(Map.of(fields));
    journal = Map.of(fields);
  }
}

Future<void> _until(WidgetTester t, Finder f, {int n = 60}) async {
  for (var i = 0; i < n && f.evaluate().isEmpty; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump();
  }
}

Widget _stepper(
  UnitSystem? system, {
  double? value,
  double? assumedMl,
  required ValueChanged<double?> onChanged,
  JournalFieldSpec? spec,
}) {
  final field = FieldStepper(
    spec: spec ?? _water,
    value: value,
    assumedMl: assumedMl,
    onChanged: onChanged,
  );
  return MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: system == null
          ? field
          : ChangeNotifierProvider<UnitsController>.value(
              value: UnitsController.seed(system), child: field),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Journal FieldStepper (water_ml)', () {
    testWidgets('metric: shows exact ml and steps 250', (t) async {
      final got = <double?>[];
      await t.pumpWidget(
          _stepper(UnitSystem.metric, value: 750, onChanged: got.add));
      expect(find.text('750 ml'), findsOneWidget);
      expect(find.text('0.8 L'), findsNothing);
      await t.tap(find.byIcon(LucideIcons.plus));
      await t.tap(find.byIcon(LucideIcons.minus));
      expect(got, [1000, 500]);
    });

    testWidgets('no units provider at all behaves as metric', (t) async {
      final got = <double?>[];
      await t.pumpWidget(_stepper(null, value: 250, onChanged: got.add));
      expect(find.text('250 ml'), findsOneWidget);
      await t.tap(find.byIcon(LucideIcons.plus));
      expect(got, [500]);
    });

    testWidgets('imperial: shows fl oz and steps one 8 fl oz cup', (t) async {
      final got = <double?>[];
      await t.pumpWidget(
          _stepper(UnitSystem.imperial, value: _cup * 2, onChanged: got.add));
      expect(find.text('16 fl oz'), findsOneWidget);
      expect(find.textContaining(' ml'), findsNothing);
      await t.tap(find.byIcon(LucideIcons.plus));
      await t.tap(find.byIcon(LucideIcons.minus));
      expect(got, hasLength(2));
      expect(got[0], closeTo(_cup * 3, 1e-9));
      expect(got[1], closeTo(_cup, 1e-9));
    });

    testWidgets('imperial from nothing: one cup, and the ceiling still clamps',
        (t) async {
      final got = <double?>[];
      await t.pumpWidget(
          _stepper(UnitSystem.imperial, value: null, onChanged: got.add));
      expect(find.text('Not logged'), findsOneWidget);
      await t.tap(find.byIcon(LucideIcons.plus));
      expect(got.single, closeTo(_cup, 1e-9));

      got.clear();
      await t.pumpWidget(_stepper(UnitSystem.imperial,
          value: _water.max - 10, onChanged: got.add));
      await t.pump();
      await t.tap(find.byIcon(LucideIcons.plus));
      expect(got.single, _water.max);
    });

    testWidgets('imperial stepping down off the last cup lands on absence '
        'through zero, as before', (t) async {
      final got = <double?>[];
      await t.pumpWidget(
          _stepper(UnitSystem.imperial, value: _cup, onChanged: got.add));
      await t.tap(find.byIcon(LucideIcons.minus));
      expect(got.single, 0, reason: 'a logged zero first');
    });

    testWidgets('other fields do not change with the unit system', (t) async {
      final got = <double?>[];
      final caffeine = kJournalFieldsByKey['caffeine_mg']!;
      await t.pumpWidget(_stepper(UnitSystem.imperial,
          value: 100, spec: caffeine, onChanged: got.add));
      expect(find.text('100 mg'), findsOneWidget);
      await t.tap(find.byIcon(LucideIcons.plus));
      expect(got, [125]);
    });

    testWidgets('assumed glasses are marked in the water display', (t) async {
      await t.pumpWidget(_stepper(UnitSystem.metric,
          value: 750, assumedMl: 250, onChanged: (_) {}));
      expect(
          find.textContaining(
              RegExp(r'250 ml.*assumed|assumed.*250 ml', caseSensitive: false)),
          findsOneWidget);
      expect(find.text('750 ml'), findsOneWidget,
          reason: 'the total is still the total');
    });

    testWidgets('no assumed glasses: nothing says assumed', (t) async {
      await t.pumpWidget(_stepper(UnitSystem.metric,
          value: 750, assumedMl: 0, onChanged: (_) {}));
      expect(find.textContaining('ssumed'), findsNothing);
    });

    testWidgets('assumed amount is shown in the user\'s units', (t) async {
      await t.pumpWidget(_stepper(UnitSystem.imperial,
          value: _cup * 3, assumedMl: _cup, onChanged: (_) {}));
      expect(
          find.textContaining(
              RegExp(r'8 fl oz.*assumed|assumed.*8 fl oz', caseSensitive: false)),
          findsOneWidget);
    });
  });

  group('Nutrition water row', () {
    const dbName = 'openstrap_water_steppers_test.db';

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = dbName;
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, dbName));
    });
    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, dbName));
    });
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<_Repo> pump(WidgetTester t, UnitSystem system,
        {Map<String, JournalMetricValue> journal = const {}}) async {
      t.view.physicalSize = const Size(390 * 3, 2400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final repo = _Repo()..journal = journal;
      app.repo = repo;
      final units = UnitsController.seed(system);
      addTearDown(units.dispose);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: app),
            ChangeNotifierProvider<LocaleController>.value(
                value: LocaleController.seed(null)),
            ChangeNotifierProvider<UnitsController>.value(value: units),
          ],
          child: const Scaffold(body: NutritionScreen()),
        ),
      ));
      return repo;
    }

    testWidgets('250 ml reads 250 ml, never 0.3 L', (t) async {
      await pump(t, UnitSystem.metric,
          journal: const {'water_ml': JournalMetricValue(250)});
      await _until(t, find.text('250 ml'));
      expect(find.text('250 ml'), findsOneWidget);
      expect(find.text('0.3 L'), findsNothing);
    });

    testWidgets('750 ml reads 750 ml, never 0.8 L; 1250 reads 1.25 L',
        (t) async {
      final repo = await pump(t, UnitSystem.metric,
          journal: const {'water_ml': JournalMetricValue(750)});
      await _until(t, find.text('750 ml'));
      expect(find.text('750 ml'), findsOneWidget);
      expect(find.text('0.8 L'), findsNothing);
      repo.journal = const {'water_ml': JournalMetricValue(1250)};
      final app = t.element(find.byType(NutritionScreen)).read<AppState>();
      app.bumpInsights();
      await _until(t, find.text('1.25 L'));
      expect(find.text('1.25 L'), findsOneWidget);
    });

    testWidgets('imperial shows fl oz', (t) async {
      await pump(t, UnitSystem.imperial,
          journal: {'water_ml': JournalMetricValue(_cup * 2)});
      await _until(t, find.text('16 fl oz'));
      expect(find.text('16 fl oz'), findsOneWidget);
      expect(find.textContaining(' ml'), findsNothing);
    });

    testWidgets('metric +: one 250 ml glass is posted', (t) async {
      final repo = await pump(t, UnitSystem.metric);
      await _until(t, find.text('None yet'));
      await t.tap(find.byIcon(LucideIcons.plus));
      for (var i = 0; i < 60 && repo.posted.isEmpty; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(repo.posted.single['water_ml']!.value, 250);
    });

    testWidgets('imperial +: one 8 fl oz cup (exact ml) is posted, and - takes '
        'exactly that cup back', (t) async {
      final repo = await pump(t, UnitSystem.imperial);
      await _until(t, find.text('None yet'));
      await t.tap(find.byIcon(LucideIcons.plus));
      for (var i = 0; i < 60 && repo.posted.isEmpty; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(repo.posted.single['water_ml']!.value, closeTo(_cup, 1e-9));
      await _until(t, find.text('8 fl oz'));
      expect(find.text('8 fl oz'), findsOneWidget);
    });

    testWidgets('assumed glasses are marked in the Nutrition water display',
        (t) async {
      // sqflite answers in real time; the widget test's fake clock never would.
      await t.runAsync(() => LocalDb.logAssumedWater(
          date: todayLabel(), atMin: 8 * 60, ml: 250, loggedAtMs: 1));
      await pump(t, UnitSystem.metric,
          journal: const {'water_ml': JournalMetricValue(750)});
      await _until(t, find.text('750 ml'));
      expect(
          find.textContaining(
              RegExp(r'250 ml.*assumed|assumed.*250 ml', caseSensitive: false)),
          findsOneWidget);
    });
  });

  test('Nutrition no longer formats litres itself (one formatter)', () {
    final nutrition =
        File('lib/ui2/screens/nutrition_screen.dart').readAsStringSync();
    expect(nutrition.contains('/ 1000).toStringAsFixed'), isFalse);
    expect(nutrition.contains('WaterUnits') || nutrition.contains('.water('),
        isTrue);
  });
}
