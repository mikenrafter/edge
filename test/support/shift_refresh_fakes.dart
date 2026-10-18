// Fake repo for the "stored row first, freshness refresh after paint" shape.
//
// Stands in for LocalRepositoryImpl: getTodayStored answers the persisted row
// (here: another day's, so today's figures are absent and
// status.refresh_pending is true); refreshTodayFreshness swaps in the
// refreshed row after a fake-clock delay. Every read answers after a fixed
// fake-clock delay. Nothing reads a real clock.
import 'package:openstrap_edge/data/day_label.dart';

import 'as_of_recalc_fakes.dart';

class RefreshRepo extends HomeRepo {
  RefreshRepo(this.stored, Map<String, dynamic> fresh, {this.delayMs = 100})
      : super(fresh);
  Map<String, dynamic> stored;
  int delayMs;
  bool refreshed = false;
  int refreshCalls = 0;

  Map<String, dynamic> get fresh => today;

  @override
  Future<Map<String, dynamic>> getTodayStored() async {
    await Future<void>.delayed(Duration(milliseconds: delayMs));
    return refreshed ? fresh : stored;
  }

  @override
  Future<Map<String, dynamic>> getToday() async {
    await Future<void>.delayed(Duration(milliseconds: delayMs));
    return fresh;
  }

  @override
  Future<void> refreshTodayFreshness() async {
    refreshCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    refreshed = true;
  }

  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) async {
    final n = DateTime.now();
    return {
      'points': [
        for (var back = 6; back >= 0; back--)
          {
            't': DateTime(n.year, n.month, n.day - back, 12)
                    .millisecondsSinceEpoch ~/
                1000,
            'v': 54.0 + back,
          },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getDayBlock(String day, List<String> keys) async =>
      const {};

  @override
  Future<List<String>> availableDays() async => [
        for (var back = 0; back < 10; back++)
          dayLabelOf(DateTime(DateTime.now().year, DateTime.now().month,
              DateTime.now().day - back)),
      ];
}

/// The stored row naming another day: nothing of today's, refresh owed.
Map<String, dynamic> storedElsewhere() {
  final b = homeBundle(withDaily: false);
  (b['status'] as Map<String, dynamic>)['refresh_pending'] = true;
  return b;
}
