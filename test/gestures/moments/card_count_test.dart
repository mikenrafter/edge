// The Home follow-up card counts assumed water glasses too (they need review).
// It shows the two counts apart: "N marked moments" (pending marks plus started
// ranges that only owe their announcement) and "N assumed water" (glasses
// waiting for keep / remove), from the same gates as the follow-up screen. The
// two always add up to `reviewCount`.

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
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
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

  group('reviewCounts (pure): the split behind the two card lines', () {
    final owed = MomentReviewQueue.empty
        .withRange(
            const PendingMoment(date: '2026-10-06', hhmm: '09:15'),
            const PendingMoment(date: '2026-10-06', hhmm: '10:05'),
            MomentChoice.nap)
        .ranges
        .single
        .copyWith(windowWritten: true, startLabelled: true, endLabelled: true);

    test('marks and glasses are counted apart', () {
      final f = MomentFollowUps(
        enabledSince: DateTime(2026, 10, 1),
        marked: const [
          (date: '2026-10-06', hhmm: '09:15'),
          (date: '2026-10-06', hhmm: '11:30'),
        ],
        assumed: [
          _g('2026-10-06', 600),
          _g('2026-10-06', 720, AssumedState.kept),
          _g('2026-10-07', 480),
          _g('2026-10-07', 490, AssumedState.removed),
        ],
      );
      final c = f.reviewCounts(_now, MomentReviewQueue.empty);
      expect(c.moments, 2);
      expect(c.assumedWater, 2, reason: 'kept and removed glasses are done');
    });

    test('a range that only owes its announcement is a marked moment', () {
      final f = MomentFollowUps(
        enabledSince: DateTime(2026, 10, 1),
        marked: const [(date: '2026-10-07', hhmm: '07:05')],
        assumed: [_g('2026-10-07', 480)],
      );
      final q = MomentReviewQueue.empty.withRangeProgress(owed);
      final c = f.reviewCounts(_now, q);
      expect(c.moments, 2, reason: 'one pending mark + one owed range');
      expect(c.assumedWater, 1);
    });

    test('the two always add up to reviewCount', () {
      final q = MomentReviewQueue.empty.withRangeProgress(owed);
      for (final f in [
        MomentFollowUps(enabledSince: DateTime(2026, 10, 1)),
        MomentFollowUps(
            enabledSince: DateTime(2026, 10, 1),
            assumed: [_g('2026-10-07', 480), _g('2026-10-07', 500)]),
        MomentFollowUps(
            enabledSince: DateTime(2026, 10, 1),
            marked: const [(date: '2026-10-07', hhmm: '07:05')],
            assumed: [_g('2026-10-07', 480)]),
      ]) {
        final c = f.reviewCounts(_now, q);
        expect(c.moments + c.assumedWater, f.reviewCount(_now, q));
      }
    });

    test('setting off: both are zero, never a count for something hidden', () {
      final f = MomentFollowUps(
        enabledSince: null,
        marked: const [(date: '2026-10-07', hhmm: '07:05')],
        assumed: [_g('2026-10-07', 480)],
      );
      final c = f.reviewCounts(
          _now, MomentReviewQueue.empty.withRangeProgress(owed));
      expect((c.moments, c.assumedWater), (0, 0));
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

    Future<void> pumpCard(WidgetTester t, AppState app) async {
      // Providers sit ABOVE the app so the pushed review route sees them too.
      await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          // The review screen opens through `themedRoute`.
          ChangeNotifierProvider(
              create: (_) =>
                  ThemeController.seed(AppThemeChoice.light, Brightness.light)),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: Builder(builder: (c) => momentFollowUpCard(c)!)),
        ),
      ));
    }

    testWidgets('an assumed glass alone makes the card appear: an "assumed '
        'water" line, and no marked-moments line', (t) async {
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
      await pumpCard(t, app);
      final line = find.byKey(const ValueKey('moment-follow-up-water'));
      for (var i = 0; i < 60 && line.evaluate().isEmpty; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(t.widget<Text>(line).data, '1 assumed water');
      expect(find.byKey(const ValueKey('moment-follow-up-moments')),
          findsNothing);
      expect(find.textContaining('things to review'), findsNothing);
    });

    testWidgets('Answer opens the review screen', (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await t.runAsync(() async {
        await app.gestureSettings.setFollowUpMoments(true,
            now: DateTime.now().subtract(const Duration(hours: 1)));
        // Idempotent per (date, minute): the previous test's glass is reused.
        await LocalDb.logAssumedWater(
            date: todayLabel(),
            atMin: DateTime.now().hour * 60 + DateTime.now().minute,
            ml: 250,
            loggedAtMs: 1);
      });
      await pumpCard(t, app);
      final answer = find.byKey(const ValueKey('moment-follow-up-answer'));
      for (var i = 0; i < 60 && answer.evaluate().isEmpty; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(answer, findsOneWidget);
      await t.tap(answer);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(MomentFollowUpScreen), findsOneWidget);
    });
  });
}
