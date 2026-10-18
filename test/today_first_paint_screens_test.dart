// The remaining screens' loaders must not wait for getToday's freshness
// refresh, and the shared latch that asks for it after the first paint is
// single-flight and clears on a throw. Fakes only; no clock decides a result.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/today_refresh.dart';

/// getToday and the refresh never answer; the stored read does, with a row
/// that named another day (status says so, nothing of it is today's).
class _Hang extends LocalRepository {
  int refreshes = 0;
  Completer<void>? gate;
  Object? refreshError;
  @override
  Future<Map<String, dynamic>> getToday() =>
      Completer<Map<String, dynamic>>().future;
  @override
  Future<Map<String, dynamic>> getTodayStored() async => {
        'status': {
          'today_day': '2026-08-05',
          'refresh_pending': true,
          'overnight_state': 'building',
          'activity_state': 'building',
          'overnight_day': '2026-08-04',
          'showing_prior_overnight': true,
        },
      };
  @override
  Future<void> refreshTodayFreshness() async {
    refreshes++;
    await gate?.future;
    if (refreshError != null) throw refreshError!;
  }

  @override
  Future<List<String>> availableDays() async => const [];
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
  @override
  Future<Map<String, dynamic>> getChart(String key,
          {int? from, Set<String> signals = const {}, int? to}) async =>
      const {};
  @override
  Future<Map<String, dynamic>> getDayBlock(
          String day, List<String> keys) async =>
      const {};
  @override
  Future<Map<String, dynamic>> getDayWear(String day) async => const {};
  @override
  Future<Map<String, dynamic>> getDayNaps(String day) async => const {};
}

Future<T> _within<T>(Future<T> f) =>
    f.timeout(const Duration(seconds: 3), onTimeout: () {
      throw StateError('waited on the freshness refresh');
    });

/// The loader got past its today read (it may then stop at a read this fake
/// does not implement; that is not what is under test).
Future<void> _gotPastToday(Future<Object?> f) async {
  try {
    await _within(f);
  } on UnimplementedError {/* reached a later read */}
}

void main() {
  group('loaders do not wait for the refresh', () {
    test('what_changed', () async {
      await _gotPastToday(WhatChangedData.load(_Hang()));
    });
    test('investigate', () async {
      await _gotPastToday(InvestigateData.load(_Hang(), 'hrv'));
    });
    test('vitals', () async {
      await _gotPastToday(VitalsData.load(_Hang()));
    });
    test('day timeline', () async {
      await _gotPastToday(TimelineData.load(_Hang()));
    });
    test('beats', () async {
      final n = await _within(BeatsData.pickNight(_Hang()));
      expect(n.day, '2026-08-05');
    });
    test('readiness: another-day row is absent, not today\'s, and pending',
        () async {
      final d = await _within(ReadinessData.load(_Hang()));
      expect(d.readiness.value, isNull);
      expect(d.refreshPending, isTrue);
    });
    test('health: pending is carried', () async {
      final d = await _within(HealthData.load(_Hang()));
      expect(d.refreshPending, isTrue);
    });
  });

  group('TodayRefreshLatch', () {
    test('asks once while a refresh is in flight; one caller reads again',
        () async {
      final repo = _Hang()..gate = Completer<void>();
      final latch = TodayRefreshLatch();
      final a = latch.afterPaint(repo, true);
      final b = latch.afterPaint(repo, true);
      repo.gate!.complete();
      expect(await Future.wait([a, b]), [true, false]);
      expect(repo.refreshes, 1);
    });

    test('a throw clears the latch: the next load asks again', () async {
      final repo = _Hang()..refreshError = StateError('boom');
      final latch = TodayRefreshLatch();
      expect(await latch.afterPaint(repo, true), isFalse);
      repo.refreshError = null;
      expect(await latch.afterPaint(repo, true), isTrue);
      expect(repo.refreshes, 2);
    });

    test('a read right after a landing that is still pending is not re-asked',
        () async {
      final repo = _Hang();
      final latch = TodayRefreshLatch();
      expect(await latch.afterPaint(repo, true), isTrue);
      expect(await latch.afterPaint(repo, true), isFalse);
      expect(repo.refreshes, 1);
      latch.reset();
      expect(await latch.afterPaint(repo, true), isTrue);
      expect(repo.refreshes, 2);
    });

    test('not pending asks nothing', () async {
      final repo = _Hang();
      expect(await TodayRefreshLatch().afterPaint(repo, false), isFalse);
      expect(repo.refreshes, 0);
    });
  });
}
