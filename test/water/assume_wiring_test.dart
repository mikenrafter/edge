// "Assume I drank water" is wired into the app (RED -> GREEN): catch-up runs at
// launch and on resume, the strap-buzz timer's slot hook logs the glass (only
// when the toggle is on), and the Settings toggle writes its prefs including the
// switched-on time.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/water_units.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../support/dart_source_lexical.dart';

/// Reminder on, no quiet hours (08:00 to 22:00 every 2 h), assume toggle as given,
/// switched on three days ago so slots are due whatever time the test runs.
NotificationPrefs _prefs({required bool assume}) {
  final since = DateTime.now().subtract(const Duration(days: 3));
  return NotificationPrefs(
    waterEnabled: true,
    quietEnabled: false,
    waterIntervalMin: 120,
    waterAssumeDrank: assume,
    waterAssumeSinceMs: since.millisecondsSinceEpoch,
  );
}

var _n = 0;
final _created = <String>[];

Future<String> _path(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

Future<void> _freshDb() async {
  final name = 'openstrap_assume_wiring_${_n++}.db';
  _created.add(name);
  await LocalDb.close();
  await databaseFactory.deleteDatabase(await _path(name));
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  await LocalDb.instance;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(() async {
    await LocalDb.close();
    for (final n in _created) {
      await databaseFactory.deleteDatabase(await _path(n));
    }
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _freshDb();
  });

  group('AppState.catchUpAssumedWater', () {
    test('toggle on: logs the slots due, marked assumed', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final n = await app.catchUpAssumedWater(prefs: _prefs(assume: true));
      expect(n, greaterThan(0));
      final all = await LocalDb.assumedWater();
      expect(all, hasLength(n));
      expect(all.map((g) => g.state), everyElement(AssumedState.assumed));
    });

    test('toggle off (the default): writes nothing', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect(await app.catchUpAssumedWater(prefs: _prefs(assume: false)), 0);
      expect(await LocalDb.assumedWater(), isEmpty);
    });

    test('with no prefs given it reads the stored ones', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await _prefs(assume: true).save();
      expect(await app.catchUpAssumedWater(), greaterThan(0));
    });

    test('running it twice logs each slot once', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final first = await app.catchUpAssumedWater(prefs: _prefs(assume: true));
      final again = await app.catchUpAssumedWater(prefs: _prefs(assume: true));
      expect(first, greaterThan(0));
      expect(again, 0);
    });

    test('the glass is the saved units preference\'s step', () async {
      SharedPreferences.setMockInitialValues({'units_system': 'imperial'});
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await app.catchUpAssumedWater(prefs: _prefs(assume: true));
      final g = (await LocalDb.assumedWater()).first;
      expect(g.ml, closeTo(WaterUnits.stepMl(UnitSystem.imperial), 1e-9));
    });
  });

  group('launch', () {
    test('arming the water reminder (done at launch and when the toggle '
        'changes) also catches up the missed slots', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await app.armWaterReminder(_prefs(assume: true));
      expect(await LocalDb.assumedWater(), isNotEmpty);
    });

    test('arming with the toggle off logs nothing', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await app.armWaterReminder(_prefs(assume: false));
      expect(await LocalDb.assumedWater(), isEmpty);
    });

    test('launch arms the water reminder', () {
      final code = codeOnly(File('lib/state/app_state.dart').readAsStringSync());
      expect(code.contains('unawaited(armWaterReminder());'), isTrue);
    });
  });

  group('resume', () {
    test('the foreground pass runs the catch-up', () {
      final code = codeOnly(File('lib/app.dart').readAsStringSync());
      final resumed = code.indexOf('AppLifecycleState.resumed');
      expect(resumed, greaterThan(0));
      expect(code.indexOf('catchUpAssumedWater()', resumed), greaterThan(resumed));
    });
  });

  group('the strap-buzz timer\'s slot hook', () {
    test('is hooked in AppState', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect(app.debugWaterBuzzer.onSlot, isNotNull);
    });

    test('a slot firing logs the glass when the toggle is on', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await _prefs(assume: true).save();
      await app.debugWaterBuzzer.onSlot!(DateTime.now());
      expect(await LocalDb.assumedWater(), isNotEmpty);
    });

    test('and nothing when the toggle is off', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await _prefs(assume: false).save();
      await app.debugWaterBuzzer.onSlot!(DateTime.now());
      expect(await LocalDb.assumedWater(), isEmpty);
    });
  });

  group('the Settings toggle', () {
    testWidgets('writes the pref and stamps the switched-on time', (t) async {
      t.view.physicalSize = const Size(1170, 24000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await t.runAsync(() => const NotificationPrefs(waterEnabled: true).save());
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ChangeNotifierProvider<AppState>.value(
            value: app, child: const NotificationSettings()),
      ));
      final row = find.text('Assume I drank water');
      for (var i = 0; i < 80 && row.evaluate().isEmpty; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(row, findsOneWidget);
      final before = DateTime.now().millisecondsSinceEpoch;
      await t.tap(row);
      await t.pump();
      NotificationPrefs? saved;
      for (var i = 0; i < 80 && saved?.waterAssumeDrank != true; i++) {
        await t.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          saved = await NotificationPrefs.load();
        });
      }
      expect(saved!.waterAssumeDrank, isTrue);
      expect(saved!.waterAssumeSinceMs, greaterThanOrEqualTo(before));
      expect(saved!.waterEnabled, isTrue, reason: 'the reminder is untouched');
    });
  });
}
