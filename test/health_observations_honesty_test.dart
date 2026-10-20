// Health honesty/latency pins (AGENTS.md 3.3, 4.1):
//  - Observations says "Nothing has stood out" only once the watch has run;
//    before that it says why there is nothing to say yet.
//  - A failed overview read shows the retry card, not an empty-data screen.
//  - The wearable read starts with the others (first paint waits for max()).
//  - Vitals with nothing measured keeps a "Sync the band" action in a slot
//    whose size does not depend on whether it is shown.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _quiet = 'Nothing has stood out';
const _notYet = 'Starts after your first scored night';

class _App extends AppState {
  _App() : super.forTesting();
  int syncs = 0;
  @override
  Future<void> syncNow() async => syncs++;
}

class _Throws extends LocalRepository {}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pump(WidgetTester t, Widget screen, {AppState? app}) async {
  t.view.physicalSize = const Size(390 * 3, 6000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  Widget home = Scaffold(body: screen);
  if (app != null) {
    home = ChangeNotifierProvider<AppState>.value(value: app, child: home);
  }
  await t.pumpWidget(
      MaterialApp(theme: buildTheme(Brightness.light), home: home));
  await _settle(t);
}

void main() {
  testWidgets('nothing checked yet is not "nothing stood out"', (t) async {
    await _pump(t, const HealthScreen(data: HealthData()));
    expect(find.text(_quiet), findsNothing);
    expect(find.text(_notYet), findsOneWidget);
    expect(find.byKey(const ValueKey('card:observations')), findsOneWidget);
  });

  testWidgets('the watch has run and found nothing keeps the sentence',
      (t) async {
    await _pump(
        t,
        const HealthScreen(
            data: HealthData(today: {
          'illness': {'state': 'green'}
        })));
    expect(find.text(_quiet), findsOneWidget);
    expect(find.text(_notYet), findsNothing);
    await _pump(t, const HealthScreen(data: HealthData(daysWithData: 4)));
    expect(find.text(_quiet), findsOneWidget);
  });

  testWidgets('both Observations states are the same size', (t) async {
    final key = find.byKey(const ValueKey('card:observations'));
    await _pump(t, const HealthScreen(data: HealthData()));
    final a = t.getSize(key);
    final topA = t.getTopLeft(find.byKey(const ValueKey('card:mind')));
    await _pump(t, const HealthScreen(data: HealthData(daysWithData: 4)));
    expect(t.getSize(key), a);
    expect(t.getTopLeft(find.byKey(const ValueKey('card:mind'))), topA);
  });

  testWidgets('a failed overview read shows retry, not empty data',
      (t) async {
    final app = _App();
    addTearDown(app.dispose);
    app.repo = _Throws();
    await _pump(t, const HealthScreen(), app: app);
    expect(find.text('Could not read your overview'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text(_quiet), findsNothing);
    expect(find.text(_notYet), findsNothing);
  });

  test('the wearable read starts before the others finish', () async {
    final gate = Completer<Map<String, dynamic>>();
    final repo = _Gated(gate);
    final f = HealthData.load(repo);
    await Future<void>.delayed(Duration.zero);
    expect(repo.wearableAsked, isTrue,
        reason: 'it waited for the whole load before starting');
    gate.complete(const {});
    await f.catchError((_) => const HealthData());
  });

  test('a failed wearable read is still null, not a failed load', () async {
    final repo = _Gated(Completer()..complete(const {}), wearableThrows: true);
    final d = await HealthData.load(repo);
    expect(d.wearable, isNull);
  });

  testWidgets('Vitals with nothing measured offers Sync the band', (t) async {
    final app = _App();
    addTearDown(app.dispose);
    await _pump(
        t,
        const HealthScreen(
            data: HealthData(), vitals: VitalsData(), tab: 3),
        app: app);
    final rows = find.byKey(const ValueKey('card:vitals-rows'));
    final slot = find.byKey(const ValueKey('card:vitals-sync'));
    expect(find.text('Sync the band'), findsOneWidget);
    final h = t.getSize(slot).height;
    await t.tap(find.text('Sync the band'));
    expect(app.syncs, 1);
    expect(rows, findsOneWidget);

    // Same slot size when the action is not offered (no AppState).
    await _pump(
        t, const HealthScreen(data: HealthData(), vitals: VitalsData(), tab: 3));
    expect(find.text('Sync the band'), findsNothing);
    expect(t.getSize(slot).height, h);
  });
}

class _Gated extends LocalRepository {
  _Gated(this.gate, {this.wearableThrows = false});
  final Completer<Map<String, dynamic>> gate;
  final bool wearableThrows;
  bool wearableAsked = false;

  @override
  Future<Map<String, dynamic>> getTodayStored() => gate.future;
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
  @override
  Future<List<String>> availableDays() async => const [];
  @override
  Future<Map<String, dynamic>> getChart(String metric, {int? from, int? to, Set<String> signals = const {}}) async => const {};
  @override
  Future<WearableDay?> wearableDay(String date) async {
    wearableAsked = true;
    if (wearableThrows) throw StateError('x');
    return null;
  }
}
