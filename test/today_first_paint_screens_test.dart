// The remaining screens' loaders must not wait for getToday's freshness
// refresh, and the shared latch that asks for it after the first paint is
// single-flight and clears on a throw. Fakes only; no clock decides a result.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/screens/beats.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/health_screen.dart';
import 'package:openstrap_edge/ui2/screens/investigate.dart';
import 'package:openstrap_edge/ui2/screens/readiness_detail.dart';
import 'package:openstrap_edge/ui2/screens/what_changed.dart';
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
          {int? limit, String? from, String? to}) async =>
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

void main() {
  group('loaders do not wait for the refresh', () {
    test('what_changed', () async {
      final d = await _within(WhatChangedData.load(_Hang()));
      expect(d.day, isNull);
    });
    test('investigate', () async {
      final d = await _within(InvestigateData.load(_Hang(), 'hrv'));
      expect(d.day, isNull);
    });
    test('vitals', () async {
      final d = await _within(VitalsData.load(_Hang()));
      expect(d.day, isNull);
    });
    test('day timeline', () async {
      final d = await _within(TimelineData.load(_Hang()));
      expect(d.day, isNull);
    });
    test('beats', () async {
      final n = await _within(BeatsData.pickNight(_Hang()));
      expect(n.day, isNull);
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
    test('asks once while a refresh is in flight, then reloads once', () async {
      final repo = _Hang()..gate = Completer<void>();
      final latch = TodayRefreshLatch();
      var reloads = 0;
      final a = latch.afterPaint(repo, true, () => true, () => reloads++);
      final b = latch.afterPaint(repo, true, () => true, () => reloads++);
      repo.gate!.complete();
      await Future.wait([a, b]);
      expect(repo.refreshes, 1);
      expect(reloads, 1);
    });

    test('a throw clears the latch: the next load asks again, no reload',
        () async {
      final repo = _Hang()..refreshError = StateError('boom');
      final latch = TodayRefreshLatch();
      var reloads = 0;
      await latch.afterPaint(repo, true, () => true, () => reloads++);
      expect(reloads, 0);
      repo.refreshError = null;
      await latch.afterPaint(repo, true, () => true, () => reloads++);
      expect(repo.refreshes, 2);
      expect(reloads, 1);
    });

    test('a read right after a landing that is still pending is not re-asked',
        () async {
      final repo = _Hang();
      final latch = TodayRefreshLatch();
      await latch.afterPaint(repo, true, () => true, () {});
      await latch.afterPaint(repo, true, () => true, () {});
      expect(repo.refreshes, 1);
      latch.reset();
      await latch.afterPaint(repo, true, () => true, () {});
      expect(repo.refreshes, 2);
    });

    test('not pending asks nothing; unmounted does not reload', () async {
      final repo = _Hang();
      final latch = TodayRefreshLatch();
      var reloads = 0;
      await latch.afterPaint(repo, false, () => true, () => reloads++);
      expect(repo.refreshes, 0);
      await latch.afterPaint(repo, true, () => false, () => reloads++);
      expect(repo.refreshes, 1);
      expect(reloads, 0);
    });
  });
}
