// 8AF.7 section F (red first): "Pull down to sync", a preference.
//
//   key `pull_to_sync`, default ON (nobody else sees a change), in
//   Settings > You & preferences next to Units / Appearance.
//   OFF: Home renders without its RefreshIndicator and an overscroll syncs
//   nothing; syncing stays one tap away on the status line's "Sync now".
//
// Contracts these tests pin that the spec leaves open:
//  - The row title is exactly "Pull down to sync". It may be a SetRow (value
//    "On"/"Off", tap the row) or a SwitchRow (tap the Switch); the helpers
//    below handle both.
//  - "Pull triggers sync" is observed as AppState.refreshData(), which is what
//    Home's pull-to-refresh already calls (a connected band makes that a real
//    sync; see SyncCoordinator.refresh).
//  - The key is read from the shared SharedPreferences instance (Prefs reads
//    it synchronously), so a Home built after the write sees it.
//  - Tests that rely on the key being ABSENT run first in their group; Prefs
//    caches its instance for the life of the process.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/sections.dart';

const _key = 'pull_to_sync';
const _title = 'Pull down to sync';

class _Spy extends AppState {
  _Spy() : super.forTesting();
  int refreshes = 0, syncs = 0;

  @override
  Future<void> refreshData() async => refreshes++;

  @override
  Future<void> syncNow() async => syncs++;
}

Future<void> _wait(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    await t.pump();
  }
}

Future<void> _pumpHome(WidgetTester t, AppState app) async {
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: ChangeNotifierProvider<AppState>.value(
      value: app,
      child: Scaffold(
        body: HomeScreen(
          data: HomeData(dayId: '2026-05-20'),
          hour: 9,
        ),
      ),
    ),
  ));
  await t.pump();
}

Future<void> _pumpSettings(WidgetTester t, AppState app) async {
  t.view.physicalSize = const Size(1170, 24000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider(
          create: (_) => UnitsController.seed(UnitSystem.metric)),
      ChangeNotifierProvider(
          create: (_) =>
              ThemeController.seed(AppThemeChoice.light, Brightness.light)),
      ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
      Provider<Capabilities>.value(value: app.capabilities),
    ],
    child: MaterialApp(
        theme: buildTheme(Brightness.light), home: const MoreSettings()),
  ));
  await _wait(t);
}

/// The row's own switch state, whichever widget draws it.
bool? _rowOn(WidgetTester t) {
  final title = find.text(_title);
  final sw = find.ancestor(of: title, matching: find.byType(SwitchRow));
  if (sw.evaluate().isNotEmpty) return t.widget<SwitchRow>(sw.first).value;
  final row = find.ancestor(of: title, matching: find.byType(SetRow));
  if (row.evaluate().isNotEmpty) {
    final v = t.widget<SetRow>(row.first).value;
    return v == 'On' ? true : v == 'Off' ? false : null;
  }
  return null;
}

Future<void> _tapRow(WidgetTester t) async {
  final title = find.text(_title);
  final sw = find.descendant(
      of: find.ancestor(of: title, matching: find.byType(SwitchRow)),
      matching: find.byType(Switch));
  await t.tap(sw.evaluate().isNotEmpty ? sw.first : title);
  await _wait(t);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_pull_to_sync_test.db';
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  // One SharedPreferences instance for the whole file (Prefs caches it), so
  // "absent" is restored by clearing it, never by replacing the mock store.
  setUp(() async => (await SharedPreferences.getInstance()).clear());

  group('default on: nothing changes for anyone else', () {
    testWidgets('Home has its RefreshIndicator and a pull syncs', (t) async {
      final app = _Spy();
      addTearDown(app.dispose);
      await _pumpHome(t, app);
      expect(find.byType(RefreshIndicator), findsOneWidget);
      await t.fling(find.byType(ListView).first, const Offset(0, 400), 1000);
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      await t.pumpAndSettle();
      expect(app.refreshes, 1, reason: 'a pull asks for a sync');
    });

    testWidgets('Settings > You & preferences has the row, reading ON',
        (t) async {
      final app = _Spy();
      addTearDown(app.dispose);
      await _pumpSettings(t, app);
      expect(
          find.descendant(
              of: section('You & preferences'), matching: find.text(_title)),
          findsOneWidget,
          reason: 'next to Units and Appearance, in You & preferences');
      expect(_rowOn(t), isTrue, reason: 'default is on');
      expect(Prefs.getBool(_key, true), isTrue);
    });

    testWidgets('it sits among the other preference rows, not at the end of '
        'another group', (t) async {
      final app = _Spy();
      addTearDown(app.dispose);
      await _pumpSettings(t, app);
      final units = t.getTopLeft(find.text('Units')).dy;
      final appearance = t.getTopLeft(find.text('Appearance')).dy;
      final pull = t.getTopLeft(find.text(_title)).dy;
      expect(pull, greaterThan(units - 1));
      expect(pull,
          lessThan(t.getTopLeft(find.text('Data & privacy')).dy),
          reason: 'inside You & preferences');
      expect((pull - appearance).abs(), lessThan(400),
          reason: 'near Units / Appearance');
    });
  });

  group('the toggle persists', () {
    testWidgets('off, then on again, under the key pull_to_sync', (t) async {
      final app = _Spy();
      addTearDown(app.dispose);
      await _pumpSettings(t, app);
      expect(find.text(_title), findsOneWidget);

      await _tapRow(t);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool(_key), isFalse, reason: 'written to storage');
      expect(Prefs.getBool(_key, true), isFalse, reason: 'and readable now');
      expect(_rowOn(t), isFalse, reason: 'the row shows it');

      await _tapRow(t);
      expect(sp.getBool(_key), isTrue);
      expect(Prefs.getBool(_key, false), isTrue);
      expect(_rowOn(t), isTrue);
    });

    testWidgets('a stored OFF is what the row shows on the next visit',
        (t) async {
      (await SharedPreferences.getInstance()).setBool(_key, false);
      final app = _Spy();
      addTearDown(app.dispose);
      await _pumpSettings(t, app);
      expect(_rowOn(t), isFalse);
    });
  });

  group('off: Home does not pull', () {
    setUp(() async =>
        (await SharedPreferences.getInstance()).setBool(_key, false));

    testWidgets('no RefreshIndicator, and an overscroll syncs nothing',
        (t) async {
      final app = _Spy();
      addTearDown(app.dispose);
      await _pumpHome(t, app);
      expect(find.byType(RefreshIndicator), findsNothing);
      await t.fling(find.byType(ListView).first, const Offset(0, 400), 1000);
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      await t.pumpAndSettle();
      expect(app.refreshes, 0);
      expect(app.syncs, 0);
    });

    testWidgets('the status line is still one tap from a sync', (t) async {
      final app = _Spy();
      addTearDown(app.dispose);
      await _pumpHome(t, app);
      expect(find.byType(HomeSyncStatus), findsOneWidget);
      await t.tap(find.text('Sync now'));
      await t.pump();
      expect(app.syncs, 1);
    });

    testWidgets('Home still scrolls and is still the same list', (t) async {
      final app = _Spy();
      addTearDown(app.dispose);
      await _pumpHome(t, app);
      expect(find.byType(ListView), findsWidgets);
      expect(find.byType(HomeSyncStatus), findsOneWidget);
    });
  });
}
