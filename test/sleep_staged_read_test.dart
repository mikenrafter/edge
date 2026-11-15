// CLAIM sleep-staged: the visible night and its shape cannot wait for 28-night
// history. A blocked chart read must not prevent the primary night publishing.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'support/as_of_recalc_fakes.dart';
import 'support/skeleton_fixture.dart';

class StagedSleepRepo extends SleepRepo {
  final history = Completer<void>();
  @override
  Future<Map<String, dynamic>> getChart(String key, {int? from, int? to, Set<String> signals = const {}}) async {
    await history.future;
    return {'points': []};
  }
}
void main() {
  testWidgets('Sleep publishes night before the history read and withholds an unfinished verdict', (t) async {
    skTallView(t);
    final repo = StagedSleepRepo();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await t.pumpWidget(perfApp(app, const SleepDetail()));
    for (var i = 0; i < 12; i++) { await t.pump(const Duration(milliseconds: 20)); }
    expect(find.textContaining('7h 23'), findsWidgets);
    expect(find.text('Nothing stood out.'), findsNothing);
    repo.history.complete();
    await t.pump();
    await t.pumpWidget(const SizedBox());
  });
}
