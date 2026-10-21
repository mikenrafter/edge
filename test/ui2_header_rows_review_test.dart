// Review round 1 of the shared header block (shared:header-rows):
//   1. the date is TODAY's, never the day Home is showing;
//   2. one calendar refresh (next LOCAL midnight + app resume) for all headers,
//      DST-safe;
//   4. "Synced through" is held ONCE in shared state, so a header built
//      mid-sync (unvisited tab, recreated) shows the same held edge as Home;
//   5. an unrelated AppState notification rebuilds nothing; a parked tab
//      (TickerMode off) runs no visual timer.
// (3, no height change between states, is test/layout_shift/screens/
// header_rows_states_shift_test.dart.) Time is a hand-driven fake clock.
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/app_shell.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/status_line.dart' show HeaderRows;
import 'package:openstrap_edge/ui2/sync_control.dart' show HomeSyncStatus;
import 'package:openstrap_edge/ui2/theme.dart';

import 'support/as_of_recalc_fakes.dart';
import 'support/bundled_fonts.dart';
import 'support/header_rows_fakes.dart';
import 'support/pin_tz.dart';
import 'support/shift_run.dart';
import 'support/tabs_consistency_fakes.dart';

const _rows = ValueKey('shared:header-rows');
Finder _in(Finder f) => find.descendant(of: find.byKey(_rows), matching: f);
Finder _text(String s) => _in(find.text(s));

/// A clock the test moves by hand (and by pump durations via [advance]).
class _Fake {
  _Fake(this.now);
  DateTime now;
  Clock get clock => Clock(() => now);
  Future<void> advance(WidgetTester t, Duration d, {Duration step = const Duration(minutes: 10)}) async {
    var left = d;
    while (left > Duration.zero) {
      final s = left < step ? left : step;
      now = now.add(s);
      await t.pump(s);
      left -= s;
    }
  }
}

Widget _home(AppState app, {required String dayId}) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(
            create: (_) => ThemeController.seed(AppThemeChoice.light, Brightness.light)),
        ChangeNotifierProvider(create: (_) => UnitsController.seed(UnitSystem.metric)),
        ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
        ChangeNotifierProvider(
            create: (_) => ClockFormatController.seed(ClockFormat.h24)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: HomeScreen(data: HomeData(dayId: dayId), hour: 15)),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  pinProcessTimeZone('America/New_York');
  setUpAll(() {
    loadFonts();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    h24();
  });
  tearDown(ClockFormatController.debugReset);

  Future<void> bare(WidgetTester t, Widget w) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(390, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(w);
    await t.pump();
  }

  Future<void> end(WidgetTester t) => t.pumpWidget(const SizedBox());

  group('1. the date is today, not the shown day', () {
    for (final (name, day) in [
      ('a historical Home day', '2026-09-20'),
      ('a cached bundle from yesterday, after midnight', '2026-10-03'),
    ]) {
      testWidgets('$name leaves the header date at today', (t) async {
        await withClock(Clock.fixed(headerNow), () async {
          final app = HeaderApp(pres: headerIdle(), through: headerEdge);
          addTearDown(app.dispose);
          await bare(t, _home(app, dayId: day));
          expect(_text(headerDate), findsOneWidget);
          expect(_in(find.textContaining('September')), findsNothing);
          expect(_in(find.textContaining('Saturday')), findsNothing);
          expect(_in(find.textContaining('3 October')), findsNothing);
          // And row 2 compares the edge against today: a clock time, not a date.
          expect(_text('Synced through 15:33'), findsOneWidget);
          await end(t);
        });
      });
    }
  });

  group('2. one calendar refresh for every header', () {
    testWidgets('rolls over at local midnight with no other event', (t) async {
      final f = _Fake(DateTime(2026, 10, 4, 23, 59, 30));
      await withClock(f.clock, () async {
        final app = HeaderApp(
            pres: headerIdle(), through: DateTime(2026, 10, 4, 23, 50));
        addTearDown(app.dispose);
        await bare(t, titleOnly(app, 'Sleep'));
        expect(_text('Sunday, 4 October'), findsOneWidget);
        expect(_text('Synced through 23:50'), findsOneWidget);
        await f.advance(t, const Duration(seconds: 45), step: const Duration(seconds: 15));
        expect(_text('Monday, 5 October'), findsOneWidget);
        expect(_text('Sunday, 4 October'), findsNothing);
        expect(_text('Synced through 23:50'), findsNothing,
            reason: 'yesterday\'s edge now reads with its day');
        expect(_in(find.textContaining('Synced through')), findsOneWidget);
        await end(t);
      });
    });

    testWidgets('app resume refreshes a stale date at once', (t) async {
      final f = _Fake(DateTime(2026, 10, 4, 22, 0));
      await withClock(f.clock, () async {
        final app = HeaderApp(pres: headerIdle(), through: headerEdge);
        addTearDown(app.dispose);
        await bare(t, titleOnly(app, 'Sleep'));
        expect(_text('Sunday, 4 October'), findsOneWidget);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        f.now = DateTime(2026, 10, 6, 7, 0); // slept through two midnights
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await t.pump();
        expect(_text('Tuesday, 6 October'), findsOneWidget);
        await end(t);
      });
    });

    testWidgets('fall-back day (25 h): rolls at midnight, not 24 h after arming',
        (t) async {
      // 2026-11-01 01:00-02:00 repeats in New_York.
      final f = _Fake(DateTime(2026, 11, 1, 0, 30));
      await withClock(f.clock, () async {
        final app = HeaderApp(pres: headerIdle(), through: DateTime(2026, 11, 1, 0, 10));
        addTearDown(app.dispose);
        await bare(t, titleOnly(app, 'Sleep'));
        expect(_text('Sunday, 1 November'), findsOneWidget);
        // 24 h 20 m later is 23:50 local (the day had 25 h).
        await f.advance(t, const Duration(hours: 24, minutes: 20));
        expect(f.now, DateTime(2026, 11, 1, 23, 50));
        expect(_text('Sunday, 1 November'), findsOneWidget);
        await f.advance(t, const Duration(minutes: 20));
        expect(f.now, DateTime(2026, 11, 2, 0, 10));
        expect(_text('Monday, 2 November'), findsOneWidget);
        await end(t);
      });
    });

    testWidgets('spring-forward day (23 h): rolls at midnight', (t) async {
      final f = _Fake(DateTime(2026, 3, 8, 0, 30));
      await withClock(f.clock, () async {
        final app = HeaderApp(pres: headerIdle(), through: DateTime(2026, 3, 8, 0, 10));
        addTearDown(app.dispose);
        await bare(t, titleOnly(app, 'Sleep'));
        expect(_text('Sunday, 8 March'), findsOneWidget);
        await f.advance(t, const Duration(hours: 22, minutes: 40));
        expect(f.now, DateTime(2026, 3, 9, 0, 10));
        expect(_text('Monday, 9 March'), findsOneWidget);
        await end(t);
      });
    });

    testWidgets('two headers (two tabs) share one refresh', (t) async {
      final f = _Fake(DateTime(2026, 10, 4, 23, 59, 30));
      await withClock(f.clock, () async {
        final app = HeaderApp(pres: headerIdle(), through: headerEdge);
        addTearDown(app.dispose);
        phoneSurface(t);
        await t.pumpWidget(shellApp(app));
        await settleShell(t);
        await goTab(t, ShellDomain.sleep);
        await f.advance(t, const Duration(seconds: 45), step: const Duration(seconds: 15));
        await settleShell(t);
        // Sleep is on screen; Home is parked but must already be right on return.
        expect(_text('Monday, 5 October'), findsOneWidget);
        await goTab(t, ShellDomain.today);
        expect(_text('Monday, 5 October'), findsOneWidget);
        await t.pumpWidget(const SizedBox());
      });
    });
  });

  group('4. the held "Synced through" is shared state', () {
    testWidgets('first visit to another tab mid-sync shows the held edge',
        (t) async {
      await withClock(Clock.fixed(headerNow), () async {
        phoneSurface(t);
        final at = headerNow.millisecondsSinceEpoch;
        final app = HeaderApp(pres: headerIdle(), through: headerEdge)
          ..repo = TabsRepo(_pinned(
              homeBundle(readiness: 70, overnightAt: at, activityAt: at)));
        addTearDown(app.dispose);
        await t.pumpWidget(shellApp(app));
        await settleShell(t);
        expect(_text('Synced through 15:33'), findsOneWidget);
        app.setPres(headerSyncing());
        app.setThrough(DateTime(2026, 10, 4, 15, 38)); // a batch lands mid-sync
        await t.pump();
        expect(_text('Synced through 15:33'), findsOneWidget, reason: 'Home holds');
        await goTab(t, ShellDomain.sleep); // first visit, mid-sync
        expect(_text('Synced through 15:33'), findsOneWidget,
            reason: 'Sleep built mid-sync shows the same held edge');
        expect(_text('Synced through 15:38'), findsNothing);
        app.setPres(headerIdle());
        await t.pump();
        expect(_text('Synced through 15:38'), findsOneWidget,
            reason: 'advances when the sync ends');
        await t.pumpWidget(const SizedBox());
      });
    });

    testWidgets('a header recreated mid-sync shows the held edge', (t) async {
      await withClock(Clock.fixed(headerNow), () async {
        final app = HeaderApp(pres: headerIdle(), through: headerEdge);
        addTearDown(app.dispose);
        await bare(t, titleOnly(app, 'Sleep'));
        app.setPres(headerSyncing());
        app.setThrough(DateTime(2026, 10, 4, 15, 38));
        await t.pump();
        await t.pumpWidget(const SizedBox()); // scrolled out / disposed
        await t.pumpWidget(titleOnly(app, 'Sleep')); // rebuilt, still syncing
        await t.pump();
        expect(_text('Synced through 15:33'), findsOneWidget);
        expect(_text('Synced through 15:38'), findsNothing);
        app.setPres(headerIdle());
        await t.pump();
        expect(_text('Synced through 15:38'), findsOneWidget);
        await end(t);
      });
    });
  });

  group('5. quiet when nothing relevant changed', () {
    testWidgets('an unrelated AppState notification rebuilds neither the '
        'header nor the sync row', (t) async {
      await withClock(Clock.fixed(headerNow), () async {
        final app = HeaderApp(pres: headerIdle(), through: headerEdge);
        addTearDown(app.dispose);
        await bare(t, titleOnly(app, 'Sleep'));
        final rows = HeaderRows.debugBuilds, sync = HomeSyncStatus.debugBuilds;
        for (var i = 0; i < 5; i++) {
          app.poke();
          await t.pump();
        }
        expect(HeaderRows.debugBuilds, rows, reason: 'HeaderRows rebuilt');
        expect(HomeSyncStatus.debugBuilds, sync, reason: 'sync row rebuilt');
        await end(t);
      });
    });

    testWidgets('a relevant change still rebuilds (the guard is not vacuous)',
        (t) async {
      await withClock(Clock.fixed(headerNow), () async {
        final app = HeaderApp(pres: headerIdle(), through: headerEdge);
        addTearDown(app.dispose);
        await bare(t, titleOnly(app, 'Sleep'));
        final sync = HomeSyncStatus.debugBuilds;
        app.setPres(headerFailed());
        await t.pump();
        expect(HomeSyncStatus.debugBuilds, greaterThan(sync));
        expect(_in(find.textContaining('Pair a band')), findsOneWidget);
        await end(t);
      });
    });

    testWidgets('a parked tab (TickerMode off) runs no visual timer, and '
        'catches up when shown', (t) async {
      final f = _Fake(headerNow);
      await withClock(f.clock, () async {
        final app = HeaderApp(pres: headerSyncing(), through: headerEdge);
        addTearDown(app.dispose);
        final enabled = ValueNotifier(false);
        addTearDown(enabled.dispose);
        t.view.physicalSize = const Size(390, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (c, on, _) => TickerMode(
            enabled: on,
            child: titleOnly(app, 'Sleep'),
          ),
        ));
        await t.pump();
        final before = HomeSyncStatus.debugBuilds;
        await f.advance(t, const Duration(seconds: 10), step: const Duration(seconds: 1));
        expect(HomeSyncStatus.debugBuilds, before,
            reason: 'a hidden header must not tick');
        enabled.value = true;
        await t.pump();
        await t.pump(const Duration(seconds: 1));
        expect(HomeSyncStatus.debugBuilds, greaterThan(before));
        expect(_in(find.text('0:52')), findsOneWidget,
            reason: '42 s + 10 s hidden, current when shown');
        await end(t);
      });
    });
  });
}

/// Shell fixtures take their day ids from the real clock; pin them.
Map<String, dynamic> _pinned(Map<String, dynamic> b) {
  final st = Map<String, dynamic>.from(b['status'] as Map);
  for (final k in ['today_day', 'activity_day', 'overnight_day']) {
    st[k] = '2026-10-04';
  }
  return {...b, 'status': st};
}
