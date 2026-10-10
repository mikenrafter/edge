// P2.5 fix round 3 (Sol r3 = REVISE), the Android health export.
//
//   1  a wipe while a platform call is awaited stops the pass at once (not at
//      the next bundle read), and no progress stamp (cursor, retry state) is
//      ever written into a replaced store.
//   2  with one pending night, the priority read also fills the one-shot slot;
//      a night replaced or deleted during the priority platform call must not
//      be served from that stale slot by the bulk pass.


import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/health_export.dart';

import 'support/p25_support.dart';

const _name = 'p25fix_round3.db';

class _Android implements HealthExportPlatform {
  const _Android();
  @override
  bool get isAndroid => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  late List<String> sleepCalls;
  late List<String> healthCalls;
  // Test hooks run INSIDE a platform call, before it answers.
  Future<bool> Function(int n)? onSleep; // n = 1-based call number; the answer
  Future<void> Function(int n)? onHealth;

  setUp(() async {
    db = await p21Fresh(_name);
    BundleStore.debugResetShared();
    SharedPreferences.setMockInitialValues({});
    sleepCalls = [];
    healthCalls = [];
    onSleep = null;
    onHealth = null;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    void on(String name, Future<Object?> Function(MethodCall c) handler) {
      messenger.setMockMethodCallHandler(MethodChannel(name), handler);
      addTearDown(() => messenger.setMockMethodCallHandler(MethodChannel(name), null));
    }

    on('openstrap/health_connect_sleep', (c) async {
      sleepCalls.add('${c.arguments}');
      return await onSleep?.call(sleepCalls.length) ?? true;
    });
    on('openstrap/health_connect_heart_rate', (c) async => true);
    on('flutter_health', (c) async {
      healthCalls.add(c.method);
      await onHealth?.call(healthCalls.length);
      return true;
    });
  });
  tearDown(() async {
    BundleStore.debugResetShared();
    await p21Drop(_name);
  });

  final days = [for (var i = 1; i <= 4; i++) '2025-03-0$i'];

  Future<void> seed(List<String> which) async {
    p22UseStore(p22Store(P22Lane()));
    for (var i = 0; i < which.length; i++) {
      await p22Seed(db, which[i], p22DayBundle(which[i], i: i), finalized: true, computedAt: 1000 + i);
    }
  }

  Future<int> export() => HealthExporter(platform: const _Android()).exportAll();
  Future<String> cursor(String name) async => await LocalDb.getCursor(name) ?? '';

  group('1: a wipe during a platform call', () {
    test('control: an uninterrupted pass leaves retry state behind (the mock '
        'store cannot write HRV)', () async {
      await seed(days);

      await export();

      expect(await cursor('health_export_retry_state'), isNotEmpty,
          reason: 'guard: the passes below have something to NOT write');
    });

    test('a wipe during a platform SUCCESS call on the final day: no cursor and '
        'no stamp in the new store', () async {
      await seed(days);
      await export();
      final total = healthCalls.length;
      await LocalDb.wipeAll();
      await seed(days);
      healthCalls.clear();
      sleepCalls.clear();
      onHealth = (n) async {
        if (n == total) await LocalDb.wipeAll(); // the very last platform call
      };

      final done = await export();

      expect(healthCalls.length, total, reason: 'guard: the wipe was at the end');
      expect(done, 0);
      expect(await cursor('health_export_retry_state'), isEmpty);
      expect(await cursor('health_export_through'), isEmpty);
    });

    test('a wipe during a platform FAILURE call: no retry state is recreated',
        () async {
      await seed(days);
      onSleep = (n) async {
        if (n != 1) return true;
        await LocalDb.wipeAll();
        return false; // the priority write fails
      };

      final done = await export();

      expect(done, 0);
      expect(await cursor('health_export_retry_state'), isEmpty);
      expect(healthCalls, isEmpty, reason: 'and the bulk pass never started');
    });

    test('a wipe mid-day stops that day: no later write goes out', () async {
      await seed(days);
      var wiped = -1;
      onHealth = (n) async {
        if (n == 3) {
          await LocalDb.wipeAll();
          wiped = healthCalls.length;
        }
      };

      await export();

      expect(wiped, 3);
      expect(healthCalls.length, 3, reason: 'nothing after the wipe');
    });
  });

  group('2: one pending night replaced or deleted during the priority write',
      () {
    test('replaced: the bulk pass exports the NEW night, never the old map',
        () async {
      await seed([days.first]);
      onSleep = (n) async {
        if (n == 1) {
          final b = p22DayBundle(days.first, i: 5, marker: 'rederived');
          final win = (((b['sleep'] as Map)['window'] as Map)['value'] as Map);
          win['onset_ms'] = 1577926800000.0;
          await p22Seed(db, days.first, b, finalized: true, computedAt: 9000);
        }
        return true;
      };

      await export();

      expect(sleepCalls, hasLength(2), reason: 'written again after the re-derive');
      expect(sleepCalls.last, contains('startTime: 1577926800000'));
      expect(sleepCalls.first, isNot(contains('startTime: 1577926800000')));
    });

    test('deleted: the bulk pass exports nothing for it', () async {
      await seed([days.first]);
      onSleep = (n) async {
        if (n == 1) {
          await db.delete('day_result', where: 'day_id = ?', whereArgs: [days.first]);
        }
        return true;
      };

      await export();

      expect(sleepCalls, hasLength(1), reason: 'only the priority write');
      expect(healthCalls, isEmpty, reason: 'the old map was not exported');
    });
  });
}
