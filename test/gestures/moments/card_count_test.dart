// The Home follow-up card counts assumed water glasses too (they need review),
// and says so neutrally. The count is pending moments + assumed glasses, from
// the same gates as the follow-up screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _now = DateTime(2026, 10, 7, 12, 0);
AssumedGlass _g(String d, int m, [AssumedState s = AssumedState.assumed]) =>
    AssumedGlass(date: d, atMin: m, ml: 250, state: s);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pendingCount (pure)', () {
    test('moments plus assumed glasses', () {
      final f = MomentFollowUps(
        enabledSince: DateTime(2026, 10, 1),
        marked: const [(date: '2026-10-06', hhmm: '09:15')],
        assumed: [
          _g('2026-10-06', 600),
          _g('2026-10-06', 720, AssumedState.kept),
          _g('2026-10-07', 480),
        ],
      );
      expect(f.pending(_now), hasLength(1));
      expect(f.pendingAssumed(_now), hasLength(2));
      expect(f.pendingCount(_now), 3);
    });

    test('setting off: nothing to review', () {
      final f = MomentFollowUps(
          enabledSince: null, assumed: [_g('2026-10-07', 480)]);
      expect(f.pendingCount(_now), 0);
    });
  });

  group('the Home card', () {
    const dbName = 'openstrap_card_count_test.db';

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

    testWidgets('an assumed glass alone makes the card appear, with the '
        'neutral wording', (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await t.runAsync(() async {
        await app.gestureSettings.setFollowUpMoments(true,
            now: DateTime.now().subtract(const Duration(hours: 1)));
        await LocalDb.logAssumedWater(
            date: todayLabel(),
            atMin: DateTime.now().hour * 60 + DateTime.now().minute,
            ml: 250,
            loggedAtMs: 1);
      });
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ChangeNotifierProvider<AppState>.value(
          value: app,
          child: Scaffold(body: Builder(builder: (c) => momentFollowUpCard(c)!)),
        ),
      ));
      final card = find.text('1 thing to review — marked moments and assumed water');
      for (var i = 0; i < 60 && card.evaluate().isEmpty; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(card, findsOneWidget);
    });
  });
}
