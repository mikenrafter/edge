// Owner request: the date, "Synced through" and battery text that used to sit
// under Home's greeting come back, on all four tab roots (Home, Sleep,
// Activity, Health). One shared block keyed `shared:header-rows`:
//
//   row 1  today's date (idle) | status sentence while sync/import/recalc is
//          busy; "1 h ago [Sync now]" / "Show details" on the right
//   row 2  "Synced through 15:33" - always its own row, held while a sync runs
//   row 3  "59% · Connected" / "Not connected"; no battery number when the
//          level is unknown (never fabricated)
//
// Pushed/detail screens (NavBar) do not carry it. Time is pinned with
// package:clock; no test reads the real clock for an assertion.
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/app_shell.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show NavBar;
import 'package:openstrap_edge/ui2/status_line.dart' show StatusLine;

import 'support/as_of_recalc_fakes.dart';
import 'support/bundled_fonts.dart';
import 'support/header_rows_fakes.dart';
import 'support/shift_run.dart';
import 'support/tabs_consistency_fakes.dart';

const _rows = ValueKey('shared:header-rows');
const _statusLine = ValueKey('shared:status-line');

Finder _in(Finder f) =>
    find.descendant(of: find.byKey(_rows), matching: f);
Finder _text(String s) => _in(find.text(s));

/// The bundle's day ids come from the real clock in the shared fixtures; pin
/// them to the fixed day so Home's "today" is [headerNow]'s.
Map<String, dynamic> _fixedDay(Map<String, dynamic> b) {
  final st = Map<String, dynamic>.from(b['status'] as Map);
  for (final k in ['today_day', 'activity_day', 'overnight_day']) {
    st[k] = '2026-10-04';
  }
  return {...b, 'status': st};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  Future<void> pumpTitle(WidgetTester t, HeaderApp app) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(390, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(titleOnly(app, 'Sleep'));
    await t.pump();
  }

  Future<void> end(WidgetTester t) => t.pumpWidget(const SizedBox());

  testWidgets('the block is one keyed element holding the status line',
      (t) async {
    await withClock(Clock.fixed(headerNow), () async {
      final app = HeaderApp(pres: headerIdle(), through: headerEdge);
      addTearDown(app.dispose);
      await pumpTitle(t, app);
      expect(find.byKey(_rows), findsOneWidget);
      expect(_in(find.byKey(_statusLine)), findsOneWidget,
          reason: 'row 1 stays shared:status-line');
      await end(t);
    });
  });

  testWidgets('idle: row 1 is today\'s date plus Sync now; row 2 is '
      '"Synced through 15:33"; row 3 is "59% · Connected", top to bottom',
      (t) async {
    await withClock(Clock.fixed(headerNow), () async {
      final app = HeaderApp(pres: headerIdle(), through: headerEdge);
      addTearDown(app.dispose);
      await pumpTitle(t, app);
      expect(_text(headerDate), findsOneWidget);
      expect(_text('Synced through 15:33'), findsOneWidget);
      expect(_text('59% · Connected'), findsOneWidget);
      expect(_text('Sync now'), findsOneWidget);
      expect(_text('Show details'), findsNothing);
      double y(Finder f) => t.getCenter(f).dy;
      expect(y(_text(headerDate)), lessThan(y(_text('Synced through 15:33'))));
      expect(y(_text('Synced through 15:33')),
          lessThan(y(_text('59% · Connected'))));
      expect(y(_text('Sync now')), closeTo(y(_text(headerDate)), 2),
          reason: 'the sync cluster is on the date row');
      await end(t);
    });
  });

  testWidgets('"Synced through" is never replaced: it is its own row even '
      'when the status line shows a sentence', (t) async {
    await withClock(Clock.fixed(headerNow), () async {
      final app = HeaderApp(pres: headerSyncing(), through: headerEdge);
      addTearDown(app.dispose);
      await pumpTitle(t, app);
      expect(_text('Downloading…'), findsOneWidget);
      expect(_text('Synced through 15:33'), findsOneWidget);
      expect(_text(headerDate), findsNothing,
          reason: 'the status sentence takes the date\'s place');
      await end(t);
    });
  });

  testWidgets('syncing: Show details replaces Sync now (the same control, '
      'no second one)', (t) async {
    await withClock(Clock.fixed(headerNow), () async {
      final app = HeaderApp(pres: headerSyncing(), through: headerEdge);
      addTearDown(app.dispose);
      await pumpTitle(t, app);
      expect(_text('Show details'), findsOneWidget);
      expect(_text('Sync now'), findsNothing);
      await end(t);
    });
  });

  testWidgets('"Synced through" is held while a sync runs, then moves when it '
      'ends', (t) async {
    await withClock(Clock.fixed(headerNow), () async {
      final app = HeaderApp(pres: headerIdle(), through: headerEdge);
      addTearDown(app.dispose);
      await pumpTitle(t, app);
      expect(_text('Synced through 15:33'), findsOneWidget);
      app.setPres(headerSyncing());
      app.through = DateTime(2026, 10, 4, 15, 38); // records land mid-sync
      await t.pump();
      expect(_text('Synced through 15:33'), findsOneWidget,
          reason: 'held while busy');
      expect(_text('Synced through 15:38'), findsNothing);
      app.setPres(headerIdle());
      await t.pump();
      expect(_text('Synced through 15:38'), findsOneWidget);
      await end(t);
    });
  });

  testWidgets('a failed sync puts the problem sentence in row 1; row 2 and '
      'row 3 stay', (t) async {
    await withClock(Clock.fixed(headerNow), () async {
      final app = HeaderApp(pres: headerFailed(), through: headerEdge);
      addTearDown(app.dispose);
      await pumpTitle(t, app);
      expect(_in(find.textContaining('Pair a band before syncing')),
          findsOneWidget);
      expect(_text(headerDate), findsNothing);
      expect(_text('Synced through 15:33'), findsOneWidget);
      expect(_text('59% · Connected'), findsOneWidget);
      await end(t);
    });
  });

  testWidgets('import progress takes row 1, same priority as the status line '
      'today; actions go; rows 2 and 3 stay', (t) async {
    await withClock(Clock.fixed(headerNow), () async {
      final app = HeaderApp(pres: headerIdle(), through: headerEdge);
      addTearDown(app.dispose);
      await pumpTitle(t, app);
      const imp = ImportRebuilding(2, 9, null);
      app.importProgress.value = imp;
      await t.pump();
      expect(_text(StatusLine.importLine(null, imp)), findsOneWidget);
      expect(_text(headerDate), findsNothing);
      expect(_text('Sync now'), findsNothing);
      expect(_text('Synced through 15:33'), findsOneWidget);
      expect(_text('59% · Connected'), findsOneWidget);
      await end(t);
    });
  });

  testWidgets('absent battery: connection text only, no number, no "0%"',
      (t) async {
    await withClock(Clock.fixed(headerNow), () async {
      final app =
          HeaderApp(pres: headerIdle(), through: headerEdge, battery: null);
      addTearDown(app.dispose);
      await pumpTitle(t, app);
      expect(_text('Connected'), findsOneWidget);
      expect(_in(find.textContaining('%')), findsNothing);
      await end(t);
    });
  });

  testWidgets('not connected: "Not connected", never a battery number',
      (t) async {
    await withClock(Clock.fixed(headerNow), () async {
      final app = HeaderApp(
          pres: headerIdle(), through: headerEdge, connection: 'disconnected');
      addTearDown(app.dispose);
      await pumpTitle(t, app);
      expect(_text('Not connected'), findsOneWidget);
      expect(_in(find.textContaining('%')), findsNothing,
          reason: 'the level is the strap\'s last report; shown only linked');
      await end(t);
    });
  });

  testWidgets('no data edge: row 2 says so, it does not invent a time',
      (t) async {
    await withClock(Clock.fixed(headerNow), () async {
      final app = HeaderApp(pres: headerIdle());
      addTearDown(app.dispose);
      await pumpTitle(t, app);
      expect(_text('No band data yet'), findsOneWidget);
      expect(_in(find.textContaining('Synced through')), findsNothing);
      await end(t);
    });
  });

  testWidgets('Sync now starts a sync from the shared block', (t) async {
    await withClock(Clock.fixed(headerNow), () async {
      final app = HeaderApp(pres: headerIdle(), through: headerEdge);
      addTearDown(app.dispose);
      await pumpTitle(t, app);
      await t.tap(_text('Sync now'));
      await t.pump();
      expect(app.syncs, 1);
      await end(t);
    });
  });

  // The four real tab roots, through the real shell.
  group('per tab', () {
    for (final d in [
      ShellDomain.today,
      ShellDomain.sleep,
      ShellDomain.activity,
      ShellDomain.health,
    ]) {
      testWidgets('${d.label}: carries the three rows', (t) async {
        await withClock(Clock.fixed(headerNow), () async {
          phoneSurface(t);
          final at = headerNow.millisecondsSinceEpoch;
          final app = HeaderApp(pres: headerIdle(), through: headerEdge)
            ..repo = TabsRepo(_fixedDay(
                homeBundle(readiness: 70, overnightAt: at, activityAt: at)));
          addTearDown(app.dispose);
          await t.pumpWidget(shellApp(app));
          await settleShell(t);
          if (d != ShellDomain.today) await goTab(t, d);
          expect(find.byKey(_rows), findsOneWidget,
              reason: '${d.label} lacks shared:header-rows');
          expect(_text('Synced through 15:33'), findsOneWidget);
          expect(_text('59% · Connected'), findsOneWidget);
          expect(_text('Sync now'), findsOneWidget);
          expect(_text(headerDate), findsOneWidget);
          await t.pumpWidget(const SizedBox());
        });
      });
    }
  });

  testWidgets('a pushed detail screen (NavBar) does not carry the block',
      (t) async {
    await withClock(Clock.fixed(headerNow), () async {
      final app = HeaderApp(pres: headerIdle(), through: headerEdge);
      addTearDown(app.dispose);
      t.view.physicalSize = const Size(390, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: Column(children: [NavBar('Detail')])),
      ));
      await t.pump();
      expect(find.byKey(_rows), findsNothing);
    });
  });
}
