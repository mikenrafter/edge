// RULES B.2 on Nutrition: BURNED is total calories. When it is an older
// calculation's value it is marked, and so is the BALANCE derived from it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/journal_fields.dart' show JournalMetricValue;
import 'package:openstrap_edge/data/nutrition_store.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/nutrition_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/older_version_fixtures.dart';

const _zero = NutrientTotal(null, 0, 0);
const _day = NutritionDay(
    date: '2026-10-04',
    entries: [],
    state: DayLogState.complete,
    kcal: NutrientTotal(2000, 1, 0),
    protein: _zero,
    carbs: _zero,
    fat: _zero,
    fibre: _zero);

Future<void> _card(WidgetTester t, Metric? burned) async {
  await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
          body: SingleChildScrollView(
              child: DayEnergyCard(day: _day, burned: burned)))));
  await t.pump();
}

void main() {
  testWidgets('older burned: asterisk on burned and on the balance it drives',
      (t) async {
    final h = t.ensureSemantics();
    await _card(
        t,
        const Metric(
            value: 2300,
            confidence: .8,
            fromOlderVersion: 104,
            olderVersionReason: kReasonRaw));
    expect(find.textContaining('2300'), findsWidgets);
    expect(olderMark('calories_total'), findsOneWidget);
    expect(olderMark('balance'), findsOneWidget);
    expect(find.bySemanticsLabel(kSpoken), findsWidgets);
    expectSpokenNotTappable(t, olderMark('calories_total'));
    h.dispose();
  });

  testWidgets('older burned: the reason strip is on the card from the first '
      'frame, once, with the history icon and no tap', (t) async {
    final h = t.ensureSemantics();
    await _card(
        t,
        const Metric(
            value: 2300,
            confidence: .8,
            fromOlderVersion: 104,
            olderVersionReason: kReasonRaw));
    expect(olderNote('calories_total'), findsOneWidget);
    expect(t.widget<Text>(olderNote('calories_total')).data, kNoteV104Reason);
    expect(find.byIcon(LucideIcons.history), findsOneWidget);
    // One source for the announcement: the strip's note, not note plus marks.
    expect(spokenCount(t), 1);
    h.dispose();
  });

  testWidgets('current burned: no strip, no icon', (t) async {
    await _card(t, const Metric(value: 2300, confidence: .8));
    expect(find.byIcon(LucideIcons.history), findsNothing);
    expect(olderNote('calories_total'), findsNothing);
  });

  testWidgets('current burned: no marker', (t) async {
    await _card(t, const Metric(value: 2300, confidence: .8));
    expect(anyOlderMarker(), findsNothing);
  });

  testWidgets('absent burned: no burned row and no marker', (t) async {
    await _card(t, const Metric(fromOlderVersion: 104));
    expect(find.textContaining('BURNED'), findsNothing);
    expect(anyOlderMarker(), findsNothing);
  });

  group('Week balance and Goals expenditure (the screen, with its database)',
      () {
    late Database db;
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await LocalDb.close();
      LocalDb.dbName = 'older_version_nutrition_test.db';
      await databaseFactory.deleteDatabase(
          p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName));
      db = await LocalDb.instance;
    });
    tearDown(() async => LocalDb.close());

    Future<void> settle(WidgetTester t) async {
      for (var i = 0; i < 30; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> open(WidgetTester t, Map<String, dynamic> burned,
        String tab) async {
      t.view.physicalSize = const Size(390 * 3, 2400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      // One COMPLETE day (an evening entry, every entry with energy).
      final y = DateTime.now().subtract(const Duration(days: 1));
      await t.runAsync(() => NutritionDb.put(
          db,
          FoodEntry(
              id: 'e1',
              date: dayLabelOf(y),
              meal: 'dinner',
              label: 'Dinner',
              atTs: DateTime(y.year, y.month, y.day, 20).millisecondsSinceEpoch ~/ 1000,
              kcal: 2000)));
      final app = AppState.forTesting()
        ..repo = _NutritionRepo({
          'daily': {'calories_total': burned},
          'status': const {},
        });
      addTearDown(app.dispose);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ChangeNotifierProvider<AppState>.value(
            value: app, child: const Scaffold(body: NutritionScreen())),
      ));
      await settle(t);
      await t.tap(find.text(tab));
      await settle(t);
    }

    final older = {
      'value': 2300,
      'confidence': .8,
      'from_older_version': 104,
      'older_version_reason': kReasonRaw,
    };
    final current = {'value': 2300, 'confidence': .8};

    testWidgets('Week: burned and the balance it drives are starred',
        (t) async {
      await open(t, older, 'Week');
      expect(find.text('Energy balance'), findsOneWidget);
      expect(olderMark('calories_total'), findsOneWidget);
      expect(olderMark('balance'), findsOneWidget);
    });

    testWidgets('Week: current burned is plain', (t) async {
      await open(t, current, 'Week');
      expect(find.text('Energy balance'), findsOneWidget);
      expect(anyOlderMarker(), findsNothing);
    });

    testWidgets('Goals: estimated expenditure is starred', (t) async {
      await open(t, older, 'Goals');
      expect(find.text('Estimated expenditure'), findsOneWidget);
      expect(olderMark('calories_total'), findsOneWidget);
      expectBareMark(olderMark('calories_total'));
    });

    testWidgets('Goals: the reason strip is on the card on load, once',
        (t) async {
      final h = t.ensureSemantics();
      await open(t, older, 'Goals');
      expect(olderNote('calories_total'), findsOneWidget);
      expect(find.byIcon(LucideIcons.history), findsOneWidget);
      expect(spokenCount(t), 1);
      h.dispose();
    });

    testWidgets('Goals: current expenditure is plain', (t) async {
      await open(t, current, 'Goals');
      expect(anyOlderMarker(), findsNothing);
    });
  });
}

class _NutritionRepo extends LocalRepository {
  final Map<String, dynamic> today;
  _NutritionRepo(this.today);
  @override
  Future<Map<String, dynamic>> getTodayStored() async => today;
  @override
  Future<Map<String, dynamic>> getToday() async => today;
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async =>
      const {};
}
