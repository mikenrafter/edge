// CLAIM sleep-staged: the visible night and its shape cannot wait for 28-night
// history. A blocked chart read must not prevent the primary night publishing.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/wake/wake_timeline.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'support/as_of_recalc_fakes.dart';
import 'support/skeleton_fixture.dart';

class StagedSleepRepo extends SleepRepo {
  final history = Completer<void>();
  @override
  Future<SleepPrimaryRead?> getSleepDetailPrimary(String day) async =>
      SleepPrimaryRead(
        bundle: SleepDetailBundle(
          night: await getDaySleepV2(day),
          timeline: const {},
          insights: const {},
          charts: const {},
          windows: const [],
        ),
        wake: const WakeNightTimeline(),
        historyCount: 20,
      );
  @override
  Future<Map<String, dynamic>> getChart(
    String key, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async {
    await history.future;
    return {'points': []};
  }
}

void main() {
  // CLAIM sleep-primary-rough: rough-night SQL starts at primary publish,
  // independently of the blocked history charts, and is not restarted afterward.
  testWidgets('rough-night read starts before history completes', (t) async {
    skTallView(t);
    final repo = StagedSleepRepo();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    final before = LocalDb.debugHandleRequests;
    try {
      await t.pumpWidget(perfApp(app, const SleepDetail()));
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(find.textContaining('7h 23'), findsWidgets);
      // This fake's primary/history paths use no SQL. The rough-night read's
      // imported-date query is the only database entry before history lands.
      expect(LocalDb.debugHandleRequests, greaterThan(before));
      final started = LocalDb.debugHandleRequests;
      repo.history.complete();
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(LocalDb.debugHandleRequests, started,
          reason: 'history must not restart the independent rough-night read');
    } finally {
      if (!repo.history.isCompleted) repo.history.complete();
      await t.pumpWidget(const SizedBox());
    }
  });
  testWidgets(
    'Sleep publishes night before the history read and withholds an unfinished verdict',
    (t) async {
      skTallView(t);
      final repo = StagedSleepRepo();
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      await t.pumpWidget(perfApp(app, const SleepDetail()));
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(find.textContaining('7h 23'), findsWidgets);
      expect(find.text('Nothing stood out.'), findsNothing);
      repo.history.complete();
      await t.pump();
      await t.pumpWidget(const SizedBox());
    },
  );
}
