// CLAIM strain-parallel-shape: today's wear estimate must not block the
// independent strain bundle. Completers prove ordering without wall-clock waits.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'support/as_of_recalc_fakes.dart';

class _HeldStrainRepo extends LocalRepository {
  final wear = Completer<Map<String, dynamic>>();
  final strain = Completer<Map<String, dynamic>>();
  bool strainStarted = false;
  @override
  Future<List<String>> availableDays() async => [todayId];
  @override
  Future<Map<String, dynamic>> getDayWear(String day) => wear.future;
  @override
  Future<Map<String, dynamic>> getDayStrain(String day) {
    strainStarted = true;
    return strain.future;
  }

  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
}

void main() {
  testWidgets('strain starts while the wear estimate is still pending', (
    t,
  ) async {
    final repo = _HeldStrainRepo();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    try {
      await t.pumpWidget(perfApp(app, const DayStrainDetail()));
      await t.pump();
      expect(repo.wear.isCompleted, isFalse);
      expect(repo.strainStarted, isTrue);
      repo.strain.complete({'strain': 8.4});
      repo.wear.complete({'worn_min': 400});
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(find.textContaining('8.4'), findsWidgets);
      expect(t.takeException(), isNull);
    } finally {
      if (!repo.strain.isCompleted) repo.strain.complete({});
      if (!repo.wear.isCompleted) repo.wear.complete({});
      await t.pumpWidget(const SizedBox());
    }
  });
}
