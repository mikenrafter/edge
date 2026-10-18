import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'support/controls_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  dynamic sync({
    required Future<void> Function(void Function(String)) run,
    required bool Function() connected,
    Future<void> Function()? reload,
    Duration timeout = const Duration(seconds: 30),
  }) {
    final dynamic app = AppState.forTesting();
    return contract(
      'shared sync operation with injected transport',
      () => app.debugSyncCoordinator(
        run: run,
        isConnected: connected,
        reloadLocal: reload ?? () async {},
        timeout: timeout,
      ),
    );
  }

  dynamic sleep({
    required Future<void> Function(String, int, int) persist,
    required Future<Map<String, Object?>> Function(String) derive,
    Future<void> Function(Map<String, Object?>)? saveSchedule,
  }) {
    final dynamic app = AppState.forTesting();
    return contract(
      'sleep edit coordinator with typed results',
      () => app.debugSleepCoordinator(
        persist: persist,
        derive: derive,
        saveSchedule: saveSchedule ?? (_) async {},
      ),
    );
  }

  test(
    'sync progresses through connect/download/derive then last success',
    () async {
      final phases = <String>[];
      final c = sync(
        connected: () => true,
        run: (progress) async {
          for (final phase in ['connecting', 'downloading', 'deriving']) {
            progress(phase);
            await flushOperations();
          }
        },
      );
      c.addListener(() => phases.add(c.presentation.phase as String));
      await c.syncNow();
      expect(
        phases,
        containsAllInOrder([
          'connecting',
          'downloading',
          'deriving',
          'completed',
        ]),
      );
      expect(c.presentation.busy, isFalse);
      expect(c.presentation.lastSuccess, isNotNull);
    },
  );
  test(
    'offline refresh reloads locally and explicitly reports no band contact',
    () async {
      var contacts = 0, reloads = 0;
      final c = sync(
        connected: () => false,
        run: (_) async {
          contacts++;
        },
        reload: () async {
          reloads++;
        },
      );
      await c.refresh();
      expect(contacts, 0);
      expect(reloads, 1);
      expect(c.presentation.phase, 'offline');
      expect(c.presentation.contactedBand, isFalse);
      expect(c.presentation.lastSuccess, isNull);
    },
  );
  test('connected refresh calls the same sync operation', () async {
    var contacts = 0;
    final c = sync(
      connected: () => true,
      run: (_) async {
        contacts++;
      },
    );
    await c.refresh();
    expect(contacts, 1);
    expect(c.presentation.phase, 'completed');
  });
  test('repeated sync taps share one download and derive', () async {
    final gate = Completer<void>();
    var contacts = 0;
    final c = sync(
      connected: () => true,
      run: (_) async {
        contacts++;
        await gate.future;
      },
    );
    final a = c.syncNow(), b = c.syncNow(), d = c.refresh();
    await flushOperations();
    expect(contacts, 1);
    gate.complete();
    await Future.wait<dynamic>([a, b, d]);
    expect(c.presentation.busy, isFalse);
  });
  for (final error in [
    TimeoutException('download'),
    StateError('disconnect'),
  ]) {
    test('$error clears busy and allows retry without false success', () async {
      var attempt = 0;
      final c = sync(
        connected: () => true,
        run: (_) async {
          if (attempt++ == 0) throw error;
        },
      );
      final result = await c.syncNow();
      expect(result.success, isFalse);
      expect(c.presentation.phase, 'failed');
      expect(c.presentation.busy, isFalse);
      expect(c.presentation.lastSuccess, isNull);
      await c.syncNow();
      expect(attempt, 2);
      expect(c.presentation.phase, 'completed');
    });
  }
  test(
    'hanging transport times out, clears busy and ignores late progress',
    () async {
      final gate = Completer<void>();
      void Function(String)? lateProgress;
      final c = sync(
        connected: () => true,
        timeout: const Duration(milliseconds: 5),
        run: (progress) async {
          lateProgress = progress;
          await gate.future;
        },
      );
      final result = await c.syncNow();
      expect(result.success, isFalse);
      expect(c.presentation.busy, isFalse);
      gate.complete();
      lateProgress!('completed');
      await flushOperations();
      expect(c.presentation.phase, 'failed');
      expect(c.presentation.lastSuccess, isNull);
    },
  );

  test('asserted atypical interval extends automatic loader on both sides', () {
    final dynamic engine = DerivationEngine();
    final normal = engine.debugTargetDayWindow('2026-09-30') as (int, int);
    final widened = contract(
      '(normal union override) sleep loader',
      () =>
          engine.debugTargetDayWindow(
                '2026-09-30',
                overrideOnsetSec: normal.$1 - 8 * 3600,
                overrideOffsetSec: normal.$2 + 10 * 3600,
              )
              as (int, int),
    );
    expect(widened.$1, lessThanOrEqualTo(normal.$1 - 8 * 3600));
    expect(widened.$2, greaterThanOrEqualTo(normal.$2 + 10 * 3600));
    expect(
      normal.$1 - widened.$1,
      lessThanOrEqualTo(14 * 3600),
      reason: 'bounded margin',
    );
    expect(widened.$2 - normal.$2, lessThanOrEqualTo(16 * 3600));
  });
  test('override inside automatic range never narrows the load', () {
    final dynamic engine = DerivationEngine();
    final normal = engine.debugTargetDayWindow('2026-09-30') as (int, int);
    final range = contract(
      'sleep loader accepts an asserted interval',
      () =>
          engine.debugTargetDayWindow(
                '2026-09-30',
                overrideOnsetSec: normal.$1 + 3600,
                overrideOffsetSec: normal.$2 - 3600,
              )
              as (int, int),
    );
    expect(range.$1, lessThanOrEqualTo(normal.$1));
    expect(range.$2, greaterThanOrEqualTo(normal.$2));
  });
  for (final bounds in [
    (DateTime(2026, 9, 29, 10), DateTime(2026, 9, 29, 18)),
    (DateTime(2026, 9, 29, 22), DateTime(2026, 9, 30, 9)),
  ]) {
    test(
      'manual window $bounds persists and succeeds with absent metrics',
      () async {
        final writes = <(String, int, int)>[];
        final c = sleep(
          persist: (d, s, e) async {
            writes.add((d, s, e));
          },
          derive: (_) async => {'sleep_source': 'manual', 'duration_min': null},
        );
        final result = await c.setOverride(
          '2026-09-30',
          bounds.$1,
          bounds.$2,
          useSchedule: false,
        );
        expect(result.success, isTrue);
        expect(result.metricsAvailable, isFalse);
        expect(writes, [
          (
            '2026-09-30',
            bounds.$1.millisecondsSinceEpoch ~/ 1000,
            bounds.$2.millisecondsSinceEpoch ~/ 1000,
          ),
        ]);
      },
    );
  }
  test(
    'manual-to-manual edit success follows persisted bounds, not source change',
    () async {
      final writes = <int>[];
      final c = sleep(
        persist: (_, s, _) async {
          writes.add(s);
        },
        derive: (_) async => {'sleep_source': 'manual', 'duration_min': 420},
      );
      for (final hour in [22, 23]) {
        final result = await c.setOverride(
          '2026-09-30',
          DateTime(2026, 9, 29, hour),
          DateTime(2026, 9, 30, 7),
          useSchedule: false,
        );
        expect(result.success, isTrue);
      }
      expect(writes.toSet().length, 2);
    },
  );
  test(
    'edit during derive is queued, last boundaries get re-derived',
    () async {
      final gate = Completer<void>();
      final writes = <int>[];
      var derives = 0;
      final c = sleep(
        persist: (_, s, _) async {
          writes.add(s);
        },
        derive: (_) async {
          if (++derives == 1) await gate.future;
          return {'duration_min': null};
        },
      );
      final first = c.setOverride(
        '2026-09-30',
        DateTime(2026, 9, 29, 22),
        DateTime(2026, 9, 30, 7),
        useSchedule: false,
      );
      await flushOperations();
      final second = c.setOverride(
        '2026-09-30',
        DateTime(2026, 9, 29, 23),
        DateTime(2026, 9, 30, 7),
        useSchedule: false,
      );
      gate.complete();
      final results = await Future.wait<dynamic>([first, second]);
      expect(results.every((dynamic r) => r.success == true), isTrue);
      expect(derives, 2);
      expect(
        writes.last,
        DateTime(2026, 9, 29, 23).millisecondsSinceEpoch ~/ 1000,
      );
      expect(c.busy, isFalse);
    },
  );
  for (final failure in ['persist', 'derive']) {
    test(
      '$failure error is visible, preserves assertion where banked, permits retry',
      () async {
        var failOnce = true, persisted = false;
        final c = sleep(
          persist: (_, _, _) async {
            if (failure == 'persist' && failOnce) {
              failOnce = false;
              throw StateError('disk');
            }
            persisted = true;
          },
          derive: (_) async {
            if (failure == 'derive' && failOnce) {
              failOnce = false;
              throw StateError('worker');
            }
            return {'duration_min': null};
          },
        );
        final result = await c.setOverride(
          '2026-09-30',
          DateTime(2026, 9, 29, 23),
          DateTime(2026, 9, 30, 7),
          useSchedule: false,
        );
        expect(result.success, isFalse);
        expect(result.error, isNotNull);
        expect(c.busy, isFalse);
        expect(persisted, failure == 'derive');
        final retried = await c.setOverride(
          '2026-09-30',
          DateTime(2026, 9, 29, 23),
          DateTime(2026, 9, 30, 7),
          useSchedule: false,
        );
        expect(retried.success, isTrue);
      },
    );
  }
  test(
    'one-night edit leaves schedule alone; going-forward saves local wall-clock',
    () async {
      final schedules = <Map<String, Object?>>[];
      final c = sleep(
        persist: (_, _, _) async {},
        derive: (_) async => {},
        saveSchedule: (s) async {
          schedules.add(s);
        },
      );
      await c.setOverride(
        '2026-09-30',
        DateTime(2026, 9, 29, 23, 30),
        DateTime(2026, 9, 30, 7, 15),
        useSchedule: false,
      );
      expect(schedules, isEmpty);
      await c.setOverride(
        '2026-09-30',
        DateTime(2026, 9, 29, 23, 30),
        DateTime(2026, 9, 30, 7, 15),
        useSchedule: true,
      );
      expect(schedules.single['onsetMinute'], 1410);
      expect(schedules.single['wakeMinute'], 435);
      for (final day in [DateTime(2026, 3, 8), DateTime(2026, 11, 1)]) {
        final (DateTime onset, DateTime wake) = c.expectedWindowFor(day);
        expect((onset.hour, onset.minute), (23, 30));
        expect((wake.hour, wake.minute), (7, 15));
        expect(onset.day, DateTime(day.year, day.month, day.day - 1).day);
      }
    },
  );
}
