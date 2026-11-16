// why: source deletion must remove rebuildable health copies. CLAIM(home-cache-reset).
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'support/as_of_recalc_fakes.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/settings/settings_repository.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'backup/backup_support.dart';

class _DeletionReads extends HomeRepo {
  _DeletionReads() : super(homeBundle(withDaily: false));
  final old = Completer<Map<String, dynamic>>();
  int storedReads = 0;
  @override
  Future<Map<String, dynamic>> getTodayStored() =>
      ++storedReads == 1 ? old.future : Future.value(today);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('deleting a day removes its durable health snapshot', () async {
    final env = await BackupEnv.create('home-delete-snapshot.db');
    try {
      await env.seedData();
      await Prefs.ensureLoaded();
      final cache = HomeRingDetailCache.local;
      cache.record(
        '2026-09-21',
        'en',
        const HomeData(readiness: Metric(value: 33.33)),
        null,
      );
      await Future<void>.value();
      await SettingsRepository.instance.update((_) {}, sections: const {});
      expect(cache.read('2026-09-21', 'en')!.data.readiness.value, 33.33);
      final removed = await LocalDb.deleteDays({'2026-09-21'});
      expect(removed, greaterThan(0));
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final durable = prefs.getString(HomeRingDetailCache.prefKey);
      cache.record(
        '2026-09-22',
        'en',
        const HomeData(readiness: Metric(value: 44.44)),
        null,
      );
      await Future<void>.value();
      await SettingsRepository.instance.update((_) {}, sections: const {});
      await prefs.reload();
      expect(prefs.getString(HomeRingDetailCache.prefKey), contains('44.44'));
      expect(
        prefs.getString(HomeRingDetailCache.prefKey),
        isNot(contains('33.33')),
      );
      final live = cache.read('2026-09-21', 'en');
      expect(
        {
          'liveSnapshotGone': live == null,
          'durableSnapshotGone': !(durable?.contains('33.33') ?? false),
        },
        {'liveSnapshotGone': true, 'durableSnapshotGone': true},
        reason: 'day deletion must remove memory and durable health judgments',
      );
    } finally {
      await env.dispose();
    }
  });
  // why: an old read completing after actual source deletion cannot revive
  // its cached advice, even with the same repository. CLAIM(home-cache-reset).
  testWidgets('day deletion fences a pending Home read', (t) async {
    final env = await t.runAsync(
      () => BackupEnv.create('home-delete-pending.db'),
    );
    await Prefs.ensureLoaded();
    final repo = _DeletionReads();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    try {
      await t.runAsync(() async {
        final db = await LocalDb.instance;
        await db.insert('day_result', {
          'day_id': todayLabel(),
          'algo_version': 100,
          'payload_json': '{}',
          'computed_at': 1,
          'finalized': 1,
        });
      });
      HomeRingDetailCache.local.record(
        todayLabel(),
        'en_US',
        const HomeData(readiness: Metric(value: 33.33)),
        null,
      );
      await t.pumpWidget(perfApp(app, const HomeScreen()));
      await t.pump();
      expect(repo.storedReads, 1);
      final removed = await t.runAsync(
        () => LocalDb.deleteDays({todayLabel()}),
      );
      expect(removed, greaterThan(0));
      expect(HomeRingDetailCache.local.read(todayLabel(), 'en_US'), isNull);
      await t.pump();
      repo.old.complete(homeBundle(readiness: 33.33));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(repo.storedReads, 2);
      expect(
        HomeRingDetailCache.local
            .read(todayLabel(), 'en_US')!
            .data
            .readiness
            .value,
        isNull,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(HomeRingDetailCache.prefKey),
        isNot(contains('33.33')),
      );
    } finally {
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() => env!.dispose());
    }
  });
}
