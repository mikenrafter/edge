// 8AF review finding: Active minutes were permanently absent in production.
// `LocalRepositoryImpl.getToday()` never put `active_min` in `daily`, so Health
// → Today always said "No active minutes", and the widget fixtures that hand
// `daily.active_min` to the screen directly hid it.
//
// These tests go through the production repository over a real database, the
// way the other repository tests do, and then through HealthData.load into the
// screen. An absent figure must come back as an absent envelope with a reason
// (AGENTS.md 3.3, 4.1), never as a zero.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _putToday(Map<String, Object?> scalars) async {
  await LocalDb.putDayResult(
    dayId: todayLabel(),
    algoVersion: kAlgoVersion,
    payloadJson: jsonEncode({'date': todayLabel(), 'scalars': scalars}),
    windowJson: '{}',
    finalized: true,
  );
  await LocalDb.refreshComputeFreshness();
}

Future<void> _settled(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalRepositoryImpl repo;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_health_active_min_repo_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    repo = LocalRepositoryImpl(getProfileMap: () => const {});
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final db = await LocalDb.instance;
    await db.delete('day_result');
    await db.delete('wake_day_features');
    await db.delete('baselines');
  });

  group('getToday carries active_min with its absence envelope', () {
    test('a derived day with active_min reads back as a measured minute count',
        () async {
      await _putToday({'strain': 9.0, 'steps': 5000, 'active_min': 74.0});
      final today = await repo.getToday();
      final m = Metric.parse((today['daily'] as Map)['active_min']);
      expect(m.isEmpty, isFalse);
      expect(m.value, 74);
      expect(m.unit, 'min');
    });

    test('a derived day with no active_min is absent, with a reason, not 0',
        () async {
      await _putToday({'strain': 9.0, 'steps': 5000});
      final today = await repo.getToday();
      final daily = (today['daily'] as Map).cast<String, dynamic>();
      expect(daily.containsKey('active_min'), isTrue,
          reason: 'an absent figure is an envelope, not a missing key');
      final m = Metric.parse(daily['active_min']);
      expect(m.isEmpty, isTrue);
      expect(m.value, isNull);
      expect(m.note, isNotNull);
    });

    test("today's interim wake features carry active_min too", () async {
      await LocalDb.putWakeDayFeatures(
        dayId: todayLabel(),
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode({'strain': 6.0, 'steps': 800, 'active_min': 12.0}),
      );
      await LocalDb.refreshComputeFreshness();
      final today = await repo.getToday();
      final m = Metric.parse((today['daily'] as Map)['active_min']);
      expect(m.value, 12);
    });
  });

  group('Health → Today over the production repository', () {
    Future<void> pumpToday(WidgetTester t) async {
      final data = await t.runAsync(() => HealthData.load(repo));
      t.view.physicalSize = const Size(390 * 3, 6000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: HealthScreen(data: data, vitals: const VitalsData(), tab: 1),
        ),
      ));
      await _settled(t);
    }

    testWidgets('a stored active_min is shown as a row', (t) async {
      await t.runAsync(() => _putToday({'strain': 9.0, 'active_min': 74.0}));
      await pumpToday(t);
      expect(find.text('Active minutes'), findsOneWidget);
      expect(find.text('74'), findsOneWidget);
      expect(find.textContaining('No active minutes'), findsNothing);
    });

    testWidgets('no active_min is the honest absence card, never a zero',
        (t) async {
      await t.runAsync(() => _putToday({'strain': 9.0}));
      await pumpToday(t);
      expect(find.textContaining('No active minutes'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });
  });
}
