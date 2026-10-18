// Design 04 phase 1, Sol r1: deleting from an EARLIER attempt's Details route
// deletes the whole group, so no route may go on showing it. Path under test:
// history list -> latest attempt -> earlier attempt -> delete. After it every
// Details route is gone, the history list no longer lists the group, and the
// rows are gone from the table. Real LocalDb (sqflite_common_ffi).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ui2/screens/ecg.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/cardio_fixtures.dart';
import 'support/ecg_home_harness.dart';

EcgReading _chain(String id, int attempt) => cardioReading(
  id: id,
  startTs: kC0 + attempt * 200,
  attemptGroup: 'A',
  attempt: attempt,
  supersededBy: attempt < 3 ? ['B', 'C'][attempt - 1] : null,
);

Future<void> _seed() async {
  final db = await LocalDb.instance;
  await db.delete('ecg_reading_packet');
  await db.delete('ecg_reading');
  for (final r in [_chain('A', 1), _chain('B', 2), _chain('C', 3)]) {
    await db.insert('ecg_reading', r.toRow());
  }
}

/// Real time for sqflite, then a frame, until [f] shows or ~2 s pass.
Future<void> _until(WidgetTester t, Finder f, {int n = 1}) async {
  for (var i = 0; i < 100; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 50));
    if (f.evaluate().length >= n) return;
  }
}

Future<void> _settleReal(WidgetTester t) async {
  for (var i = 0; i < 15; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_ecg_delete_nav_test.db';
  });
  setUp(resetPrefs);
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  testWidgets('latest -> earlier attempt -> delete: no Details route is left '
      'showing the deleted group, and the list no longer lists it', (t) async {
    await t.runAsync(_seed);
    await pumpWithApp(t, const EcgHomeScreen(), ready: find.byType(EcgReadingRow));
    expect(find.byType(EcgReadingRow), findsOneWidget);

    // Home -> the latest attempt (C).
    await t.tap(find.byType(EcgReadingRow));
    await _until(t, find.byType(EcgDetailScreen));
    await t.pumpAndSettle();
    expect(find.byType(EcgDetailScreen), findsOneWidget);

    // C's Details -> the earlier attempt A.
    await t.tap(find.byKey(const ValueKey('ecg-details')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('ecg-attempt:A')));
    await _until(t, find.byType(EcgDetailScreen, skipOffstage: false), n: 2);
    await t.pumpAndSettle();
    expect(find.byType(EcgDetailScreen, skipOffstage: false), findsNWidgets(2));

    // Delete from A and confirm.
    await t.tap(find.text('Delete reading'));
    await t.pumpAndSettle();
    expect(find.text('Delete this reading and all 3 attempts?'), findsOneWidget);
    await t.tap(find.text('Delete'));
    await _settleReal(t);
    await t.pumpAndSettle();

    expect(find.byType(EcgDetailScreen, skipOffstage: false), findsNothing,
        reason: 'no route may still show the deleted reading or waveform');
    expect(find.byType(EcgHomeScreen), findsOneWidget);
    expect(find.byType(EcgReadingRow), findsNothing,
        reason: 'the history list no longer lists the group');
    final left = await t.runAsync(() async {
      final db = await LocalDb.instance;
      return (await db.query('ecg_reading')).length;
    });
    expect(left, 0);
  });
}
