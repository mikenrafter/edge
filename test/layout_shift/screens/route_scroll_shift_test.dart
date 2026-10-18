// Layout shift of a route push (MetricDetail from a tap) and of a data reload
// on a Home scrolled one screen down. Measurement tests (fake pumps only).
//
// The route transition is the framework's own movement: it is declared as an
// AnimationSpan (tap -> the theme's transition duration) so it is discounted,
// and what remains is scored.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import '../../support/as_of_recalc_fakes.dart';
import '../../support/shift_run.dart';

class _SlowMetricRepo extends MetricRepo {
  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return super.getChart(metric, from: from, to: to, signals: signals);
  }
}

class _Home extends HomeRepo {
  _Home(super.today);
  int delayMs = 0;
  @override
  Future<Map<String, dynamic>> getToday() async {
    await Future<void>.delayed(Duration(milliseconds: delayMs));
    return super.getToday();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Route push: tap -> MetricDetail (transition discounted)',
      (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()..repo = _SlowMetricRepo();
    addTearDown(app.dispose);
    late Duration transition;
    final page = Builder(builder: (ctx) {
      final th = Theme.of(ctx);
      transition = th.pageTransitionsTheme
              .builders[th.platform]
              ?.transitionDuration ??
          const Duration(milliseconds: 300);
      return Center(
        child: TextButton(
          onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: MetricDetail('resting_hr')))),
          child: const Text('open detail'),
        ),
      );
    });
    await t.pumpWidget(perfApp(app, page));
    final run = ShiftRun(t, skipCoveredRoutes: true);
    run.now = 0;
    final tapAt = run.now;
    run.probe.animations.add(AnimationSpan(
        tapAt, tapAt + transition.inMilliseconds + 16, chainId: 'route-push'));
    await run.tap(find.text('open detail'));
    await t.pump(const Duration(seconds: 3));
    expect(find.byType(MetricDetail), findsOneWidget);
    run.expectNoErrors('route push to metric detail');
  });

  testWidgets('Home scrolled one screen, then a data reload', (t) async {
    phoneSurface(t);
    final repo = _Home(homeBundle(
        readiness: 70, overnightAt: todayAtMs(8, 42), activityAt: todayAtMs(8, 42)));
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
    await t.pump(const Duration(seconds: 1));
    final scroll = find.byType(Scrollable).first;
    await t.drag(scroll, const Offset(0, -844));
    await t.pump(const Duration(seconds: 2)); // fling settles
    expect(t.state<ScrollableState>(scroll).position.pixels, greaterThan(0),
        reason: 'Home must really be scrolled down before the reload');
    run.now = 0;
    run.snap();
    repo.today = homeBundle(
        readiness: 82, overnightAt: todayAtMs(9, 15), activityAt: todayAtMs(9, 15));
    repo.delayMs = 150;
    app.bumpInsights();
    await run.frames();
    await t.pump(const Duration(seconds: 3));
    run.expectNoErrors('home scrolled, data reload');
  });
}
