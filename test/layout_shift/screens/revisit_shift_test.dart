// Revisit consistency: leaving a screen and coming back shows the same layout
// as before, compared EVERYTHING, ALWAYS - even when new data arrived in
// between. Only content inside fixed boxes may change (a changed text in the
// same box is no finding). Settled frame of visit 1 vs settled frame of
// visit 2, every id, unkeyed elements tracked.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/app_shell.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import '../../support/as_of_recalc_fakes.dart';
import '../../support/shift_run.dart';
import '../../support/tabs_consistency_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const p = ShiftPolicy.standard;

  Map<String, dynamic> bundle(num readiness, int h, int m) => homeBundle(
      readiness: readiness, overnightAt: todayAtMs(h, m), activityAt: todayAtMs(h, m));

  void expectSame(String name, Frame a, Frame b) {
    expect(a.elements, isNotEmpty, reason: '$name: visit 1 captured nothing');
    final r = compareLayouts(a, b, p, viewport: shiftViewport);
    printOnFailure(top(name, r));
    expect(r.findings.where((f) => f.score >= p.warnAt), isEmpty,
        reason: worst(name, r, p));
  }

  /// Push MetricDetail over [screen], optionally run [whileAway], pop, settle.
  Future<void> awayAndBack(WidgetTester t, Type screen,
      {void Function()? whileAway}) async {
    final nav = Navigator.of(t.element(find.byType(screen)));
    nav.push(MaterialPageRoute<void>(
        builder: (_) => const MetricDetail('resting_hr')));
    await settleShell(t);
    whileAway?.call();
    nav.pop();
    await settleShell(t);
  }

  testWidgets('Home: push MetricDetail, pop - same layout', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()
      ..repo = TabsRepo(bundle(70, 8, 42));
    addTearDown(app.dispose);
    await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
    await settleShell(t);
    final before = captureFrame(t);
    await awayAndBack(t, HomeScreen);
    expectSame('home revisit', before, captureFrame(t));
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('Health: push MetricDetail, pop - same layout', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()
      ..repo = TabsRepo(bundle(70, 8, 42));
    addTearDown(app.dispose);
    await t.pumpWidget(perfApp(app, const HealthScreen()));
    await settleShell(t);
    final before = captureFrame(t);
    await awayAndBack(t, HealthScreen);
    expectSame('health revisit', before, captureFrame(t));
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('AppShell: Home -> Health -> Home - same layout', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()
      ..repo = TabsRepo(bundle(70, 8, 42));
    addTearDown(app.dispose);
    await t.pumpWidget(shellApp(app));
    await settleShell(t);
    final before = captureFrame(t);
    await goTab(t, ShellDomain.health);
    await goTab(t, ShellDomain.today);
    expectSame('shell home revisit', before, captureFrame(t));
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('AppShell: Health -> Home -> Health - same layout', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()
      ..repo = TabsRepo(bundle(70, 8, 42));
    addTearDown(app.dispose);
    await t.pumpWidget(shellApp(app, initial: ShellDomain.health));
    await settleShell(t);
    final before = captureFrame(t);
    await goTab(t, ShellDomain.today);
    await goTab(t, ShellDomain.health);
    expectSame('shell health revisit', before, captureFrame(t));
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('Home: new data landed while away - still the same layout',
      (t) async {
    phoneSurface(t);
    final repo = TabsRepo(bundle(70, 8, 42));
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
    await settleShell(t);
    final before = captureFrame(t);
    await awayAndBack(t, HomeScreen, whileAway: () {
      // A sync lands while the user is on the detail screen: new numbers,
      // fresher computed_at.
      repo.today = bundle(82, 9, 15);
      app.bumpInsights();
    });
    expectSame('home revisit after sync', before, captureFrame(t));
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('AppShell: new data landed while on another tab - Home same',
      (t) async {
    phoneSurface(t);
    final repo = TabsRepo(bundle(70, 8, 42));
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await t.pumpWidget(shellApp(app));
    await settleShell(t);
    final before = captureFrame(t);
    await goTab(t, ShellDomain.health);
    repo.today = bundle(82, 9, 15);
    app.bumpInsights();
    await settleShell(t);
    await goTab(t, ShellDomain.today);
    expectSame('shell home revisit after sync', before, captureFrame(t));
    await t.pump(const Duration(seconds: 5));
  });
}
