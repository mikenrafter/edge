// why: replacement must fence both already-queued saves and pending Home reads.
// CLAIM(home-cache-reset). Uses the real settings queue and a held preference write.
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The platform store seam holds a real settings write behind a gate.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/home_snapshot_store.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/settings/settings_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'support/as_of_recalc_fakes.dart';

class _SlowPrefs extends InMemorySharedPreferencesStore {
  _SlowPrefs() : super.empty();
  final snapshotWrites = <String>[];
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.lifecycle.probe') {
      entered.complete();
      await release.future;
    }
    if (key == 'flutter.${HomeRingDetailCache.prefKey}') {
      snapshotWrites.add(value as String);
    }
    return super.setValue(type, key, value);
  }
}

class _Held extends HomeRepo {
  _Held() : super(homeBundle(readiness: 19));
  final gate = Completer<void>();
  @override
  Future<Map<String, dynamic>> getTodayStored() async {
    await gate.future;
    return today;
  }
}

Future<void> flush() async {
  await Future<void>.value();
  await SettingsRepository.instance.update((_) {}, sections: const {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  test(
    'replacement removes warm data and fences a save waiting in the settings queue',
    () async {
      final store = _SlowPrefs();
      SharedPreferencesStorePlatform.instance = store;
      final cache = HomeRingDetailCache.local;
      final app = AppState.forTesting()..repo = HomeRepo(homeBundle());
      addTearDown(app.dispose);
      cache.record(
        'old-day',
        'en',
        const HomeData(readiness: Metric(value: 22.77)),
        null,
      );
      await flush();
      final blocked = SettingsRepository.instance.update(
        (d) => d.setString('lifecycle.probe', 'held'),
        sections: const {},
      );
      await store.entered.future;
      final queuedCache = HomeRingDetailCache(userKey: () => 'old-profile');
      queuedCache.record(
        'queued-day',
        'en',
        const HomeData(readiness: Metric(value: 33.88)),
        null,
      );
      await Future<void>.value();
      final writesBeforeReplacement = store.snapshotWrites.length;
      app.repo = HomeRepo(homeBundle());
      final oldEntry = cache.read('old-day', 'en');
      cache.record(
        'new-day',
        'en',
        const HomeData(readiness: Metric(value: 44.99)),
        null,
      );
      store.release.complete();
      await blocked;
      await flush();
      expect(oldEntry, isNull);
      expect(
        store.snapshotWrites.skip(writesBeforeReplacement),
        everyElement(isNot(contains('33.88'))),
        reason: 'a queued edit is fenced before it can attempt a stale write',
      );
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString(HomeRingDetailCache.prefKey)!;
      expect(encoded, contains('44.99'));
      expect(encoded, isNot(contains('22.77')));
      expect(encoded, isNot(contains('33.88')));
    },
  );
  test(
    'plain database open retains a snapshot, wipe invalidates it before returning',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = await Directory.systemTemp.createTemp('home-cache-store-');
      final previousName = LocalDb.dbName;
      await LocalDb.close();
      LocalDb.dbName = '${dir.path}/cache.db';
      try {
        final cache = HomeRingDetailCache.local;
        cache.record(
          'before-open',
          'en',
          const HomeData(readiness: Metric(value: 55.66)),
          null,
        );
        await flush();
        await LocalDb.instance;
        expect(cache.read('before-open', 'en'), isNotNull);
        await LocalDb.wipeAll();
        expect(cache.read('before-open', 'en'), isNull);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString(HomeRingDetailCache.prefKey),
          isNot(contains('55.66')),
        );
        cache.record(
          'after-wipe',
          'en',
          const HomeData(readiness: Metric(value: 77.88)),
          null,
        );
        await flush();
        expect(
          prefs.getString(HomeRingDetailCache.prefKey),
          isNot(contains('55.66')),
        );
      } finally {
        await LocalDb.close();
        LocalDb.dbName = previousName;
        await dir.delete(recursive: true);
      }
    },
  );
  // why: a deletion must fence edits already queued behind unrelated settings.
  // CLAIM(home-cache-reset). This drives LocalDb.deleteDays, not invalidation alone.
  test('day deletion fences a delayed snapshot save', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('home-cache-delete-');
    final previousName = LocalDb.dbName;
    await LocalDb.close();
    LocalDb.dbName = '${dir.path}/cache.db';
    final store = _SlowPrefs();
    SharedPreferencesStorePlatform.instance = store;
    final cache = HomeRingDetailCache.local;
    await HomeSnapshotStore.invalidate();
    final db = await LocalDb.instance;
    await db.insert('day_result', {
      'day_id': '2026-09-21',
      'algo_version': 100,
      'payload_json': '{}',
      'computed_at': 1,
      'finalized': 1,
    });
    cache.record(
      '2026-09-21',
      'en',
      const HomeData(readiness: Metric(value: 33.33)),
      null,
    );
    await flush();
    final blocked = SettingsRepository.instance.update(
      (d) => d.setString('lifecycle.probe', 'deleting'),
      sections: const {},
    );
    await store.entered.future;
    final queued = HomeRingDetailCache(userKey: () => 'queued-profile');
    queued.record(
      '2026-09-21',
      'en',
      const HomeData(readiness: Metric(value: 22.22)),
      null,
    );
    await Future<void>.value();
    final writesBefore = store.snapshotWrites.length;
    final invalidated = Completer<void>();
    void changed() {
      if (!invalidated.isCompleted) invalidated.complete();
    }

    HomeSnapshotStore.changes.addListener(changed);
    final deletion = LocalDb.deleteDays({'2026-09-21'});
    try {
      await invalidated.future.timeout(const Duration(seconds: 5));
      expect(cache.read('2026-09-21', 'en'), isNull);
      expect(queued.read('2026-09-21', 'en'), isNull);
    } finally {
      HomeSnapshotStore.changes.removeListener(changed);
      store.release.complete();
      await blocked;
      await deletion;
      await flush();
      await LocalDb.close();
      LocalDb.dbName = previousName;
      await dir.delete(recursive: true);
    }
    expect(
      store.snapshotWrites.skip(writesBefore),
      everyElement(isNot(contains('22.22'))),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(HomeRingDetailCache.prefKey), isNull);
  });
  testWidgets(
    'a pending read from the replaced repository cannot revive old snapshots',
    (t) async {
      final old = _Held();
      final app = AppState.forTesting()..repo = old;
      addTearDown(app.dispose);
      await t.pumpWidget(perfApp(app, const HomeScreen()));
      await t.pump();
      app.repo = HomeRepo(homeBundle(readiness: 30));
      await t.pump();
      old.gate.complete();
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('Recovery 19 of 100'), findsNothing);
      final entry = HomeRingDetailCache.local.read(todayLabel(), 'en_US');
      expect(entry?.data.readiness.value, isNot(19));
      expect(entry?.data.readiness.value, 30);
      await t.pumpWidget(const SizedBox());
    },
  );
}
