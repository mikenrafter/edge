// 8M — Home shows exactly ONE sync control. It used to show two: the persistent
// "Sync now" panel and, on a bare or stale day, a status card with its own
// "Sync the band" button reading a different busy flag (`syncingNow` plus a
// local tap latch). Both buttons now come from the one SyncCoordinator state.
// Oct 4: the one control is the status line in the greeting header
// (`HomeSyncStatus`); the card above the greeting is gone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Widget _home(AppState app, {HomeData? data}) => MaterialApp(
  theme: buildTheme(Brightness.light),
  home: ChangeNotifierProvider<AppState>.value(
    value: app,
    child: Scaffold(body: HomeScreen(data: data, hour: 9)),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState app;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    app = AppState.forTesting();
  });
  tearDown(() => app.dispose());

  void expectOne(WidgetTester t) {
    expect(find.text('Sync now'), findsOneWidget);
    expect(find.text('Sync the band'), findsNothing);
    expect(find.byType(HomeSyncStatus), findsOneWidget);
    expect(find.byType(SyncControl), findsNothing);
  }

  testWidgets('first run (nothing derived, nothing loaded)', (t) async {
    await t.pumpWidget(_home(app));
    await t.pump();
    expect(find.text('Nothing derived yet'), findsOneWidget);
    expectOne(t);
  });

  testWidgets('a bare day that has scored before', (t) async {
    await t.pumpWidget(
      _home(
        app,
        data: const HomeData(dayId: '2026-05-20', heldOverNight: '2026-05-16'),
      ),
    );
    await t.pump();
    expect(find.text('Nothing recorded for today'), findsOneWidget);
    expectOne(t);
  });

  testWidgets('a bare day on a fresh install', (t) async {
    await t.pumpWidget(_home(app, data: const HomeData(dayId: '2026-05-20')));
    await t.pump();
    expect(find.text('Nothing derived yet'), findsOneWidget);
    expectOne(t);
  });

  testWidgets('stale cross-day insights do not add a second button', (t) async {
    // Tall enough that the lazy list builds the notice below the rings.
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(800, 6000);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      _home(
        app,
        data: HomeData(
          dayId: '2026-05-20',
          // A scored day (not bare) is where the rollup notice renders.
          readiness: Metric.parse({
            'value': 70,
            'confidence': .8,
            'tier': 'HIGH',
          }),
          insightsStale: const {'kind': 'algo_version'},
        ),
      ),
    );
    await t.pump();
    expect(
      find.text('Your cross-day insights are being rebuilt'),
      findsOneWidget,
    );
    expectOne(t);
  });

  testWidgets('a sync that is running shows on Home, in the one control', (
    t,
  ) async {
    await t.pumpWidget(_home(app, data: const HomeData(dayId: '2026-05-20')));
    await t.pump();
    // Manual sync fails fast here (no band paired), which is itself a state
    // the single control must show with a Retry and, behind "Show details",
    // the reason.
    await t.runAsync(() => app.syncNow());
    await t.pump();
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Sync now'), findsNothing);
    expect(find.text('Sync the band'), findsNothing);
    expect(find.text('Sync failed'), findsOneWidget);
    await t.tap(find.text('Show details'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Pair a band before syncing'), findsWidgets);
  });
}
