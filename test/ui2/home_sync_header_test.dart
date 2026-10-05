// Oct 4: Home's sync UI lives in the greeting header, not in a card above it.
//
//   Good afternoon
//   Sunday, 4 October
//   Synced through 15:33          1 h ago [Sync now] (gear)   <- center line
//   59% · Connected
//
// While syncing the center line LEADS with the status sentence ("Downloading…"),
// then the timer, then "Show details"; "Synced through" is hidden while a status
// shows (it is one tap away in the sheet). The spinner replaces the settings
// button's gear icon (same button, same tap); Sync now is hidden meanwhile. A
// problem sentence leads "Show details". "Show details" opens a bottom sheet
// with the four steps. No percentages, no estimates: absent means nothing.
//
// The four lines keep the tight rhythm they had before the sync UI moved in:
// the center line's 44 pt hit target overhangs its neighbours, it does not
// grow the layout.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart' show MoreSettings;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../sources/support/fonts.dart';

class _App extends AppState {
  _App({
    this.pres = const SyncPresentationState(phase: 'idle'),
    String connection = 'connected',
    double? battery = 59,
    this.through,
  }) : _device = DeviceState(connection: connection)
         ..batteryPct = battery
         ..charging = battery == null ? null : false,
       super.forTesting();

  SyncPresentationState pres;
  final DeviceState _device;
  final DateTime? through;
  int syncs = 0;

  @override
  SyncPresentationState get syncPresentation => pres;
  @override
  DeviceState get device => _device;
  @override
  DateTime? get lastRecordAt => through;
  @override
  Future<void> syncNow() async => syncs++;
}

final _edge = DateTime(2026, 10, 4, 15, 33);

SyncStep _step(SyncStepId id, SyncStepStatus s, {DateTime? at}) =>
    SyncStep(id: id, status: s, startedAt: at, endedAt: null);

/// 42 s into a sync, steps part-way.
SyncPresentationState _syncing() {
  final start = DateTime.now().subtract(const Duration(seconds: 42));
  return SyncPresentationState(
    phase: 'downloading',
    busy: true,
    contactedBand: true,
    startedAt: start,
    lastSuccess: DateTime.now().subtract(const Duration(minutes: 61)),
    steps: [
      _step(SyncStepId.connect, SyncStepStatus.done, at: start),
      _step(SyncStepId.download, SyncStepStatus.running, at: start),
      _step(SyncStepId.calculate, SyncStepStatus.waiting),
      _step(SyncStepId.done, SyncStepStatus.waiting),
    ],
  );
}

SyncPresentationState _idle() => SyncPresentationState(
  phase: 'idle',
  lastSuccess: DateTime.now().subtract(const Duration(minutes: 61)),
);

SyncPresentationState _failed() => SyncPresentationState(
  phase: 'failed',
  failureReason: 'Pair a band before syncing',
  lastSuccess: DateTime.now().subtract(const Duration(minutes: 61)),
  startedAt: DateTime.now().subtract(const Duration(seconds: 50)),
  finishedAt: DateTime.now().subtract(const Duration(seconds: 9)),
  steps: [
    _step(SyncStepId.connect, SyncStepStatus.failed),
    _step(SyncStepId.download, SyncStepStatus.skipped),
    _step(SyncStepId.calculate, SyncStepStatus.skipped),
    _step(SyncStepId.done, SyncStepStatus.skipped),
  ],
);

// The controllers are for Settings, which the gear opens.
Widget _home(AppState app, {double scale = 1}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<AppState>.value(value: app),
    ChangeNotifierProvider(
      create: (_) => ThemeController.seed(AppThemeChoice.light, Brightness.light),
    ),
    ChangeNotifierProvider(create: (_) => UnitsController.seed(UnitSystem.metric)),
    ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light),
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: const Scaffold(
      body: HomeScreen(data: HomeData(dayId: '2026-10-04'), hour: 15),
    ),
  ),
);

Future<void> _pump(
  WidgetTester t,
  AppState app, {
  double width = 390,
  double scale = 1,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(width, 900);
  addTearDown(t.view.reset);
  await t.pumpWidget(_home(app, scale: scale));
  await t.pump();
}

/// A busy sync holds a 1 s ticker: take the tree down before the test ends.
Future<void> _end(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
}

Finder _text(Pattern p) => find.byWidgetPredicate(
  (w) =>
      w is Text &&
      (w.data != null &&
          (p is RegExp ? p.hasMatch(w.data!) : w.data == p)),
);

/// The data-edge text, whichever width it was given.
Finder get _through => find.byWidgetPredicate(
  (w) =>
      w is Text &&
      (w.data == 'Synced through 15:33' || w.data == 'Through 15:33'),
);

Finder get _gear => find.byIcon(LucideIcons.settings);
Finder get _spinner => find.byType(CircularProgressIndicator);

/// The settings button: the Pressable that carries the "Profile and settings"
/// label (the gear when idle, the spinner while syncing).
Finder get _settingsButton => find.byWidgetPredicate(
  (w) =>
      w is Pressable &&
      (w.semanticLabel ?? '').startsWith('Profile and settings'),
);

/// The status sentence a running sync leads with.
Finder get _status => find.text('Downloading…');

/// The one clock-looking readout, "0:42".
final _clockRe = RegExp(r'^\d+:\d\d$');

double _x(WidgetTester t, Finder f) => t.getCenter(f.first).dx;
double _y(WidgetTester t, Finder f) => t.getCenter(f.first).dy;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The real type: the test font is a full em wide per glyph, which would force
  // the short label at every width and prove nothing about the real fit.
  setUpAll(loadFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('idle', () {
    testWidgets('center line: through, time since sync, Sync now, then the gear',
        (t) async {
      final app = _App(pres: _idle(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);

      expect(_text('Synced through 15:33'), findsOneWidget);
      expect(find.text('1 h ago'), findsOneWidget);
      expect(find.text('Sync now'), findsOneWidget);
      expect(find.text('Show details'), findsNothing);
      expect(_spinner, findsNothing);

      // Left to right, all on the one line.
      final through = _text('Synced through 15:33');
      expect(_x(t, through), lessThan(_x(t, find.text('1 h ago'))));
      expect(_x(t, find.text('1 h ago')), lessThan(_x(t, find.text('Sync now'))));
      expect(t.getTopRight(find.text('Sync now')).dx,
          lessThan(t.getTopLeft(_gear).dx),
          reason: 'the button sits just left of the settings gear');
      expect((_y(t, through) - _y(t, find.text('1 h ago'))).abs(), lessThan(2));
      expect((_y(t, through) - _y(t, find.text('Sync now'))).abs(), lessThan(2));
      await _end(t);
    });

    testWidgets('the battery line keeps the connection, under the center line',
        (t) async {
      final app = _App(pres: _idle(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      expect(find.text('59% · Connected'), findsOneWidget);
      expect(_y(t, find.text('59% · Connected')),
          greaterThan(_y(t, _text('Synced through 15:33'))));
      // Connection is said once: not in the center line.
      expect(find.textContaining('Band not connected'), findsNothing);
      await _end(t);
    });

    testWidgets('idle: the settings button shows the gear, no spinner anywhere',
        (t) async {
      final app = _App(pres: _idle(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      expect(_settingsButton, findsOneWidget);
      expect(
        find.descendant(of: _settingsButton, matching: _gear),
        findsOneWidget,
      );
      expect(_spinner, findsNothing);
      await _end(t);
    });

    testWidgets('the four lines keep the tight pre-sync-UI rhythm', (t) async {
      final app = _App(pres: _idle(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      final date = find.text('Sunday, 4 October');
      final center = _text('Synced through 15:33');
      final battery = find.text('59% · Connected');
      final line = t.getSize(center).height;
      // Before the sync UI moved in: date, center line, 2 pt, battery. The
      // center line's 44 pt hit target must not add its own height.
      expect(t.getTopLeft(center).dy - t.getBottomLeft(date).dy, lessThan(2));
      expect(
        t.getTopLeft(battery).dy - t.getBottomLeft(date).dy,
        lessThanOrEqualTo(line + 2 + 1),
        reason: 'date bottom to battery top is one text line and a 2 pt gap',
      );
      await _end(t);
    });

    testWidgets('the settings button stays centred on the header block',
        (t) async {
      final app = _App(pres: _idle(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      final top = t.getTopLeft(find.textContaining('Good afternoon')).dy;
      final bottom = t.getBottomLeft(find.text('59% · Connected')).dy;
      expect(t.getCenter(_gear).dy, closeTo((top + bottom) / 2, 2));
      await _end(t);
    });

    testWidgets('the 44 pt hit target is kept: a tap 20 pt off the text lands',
        (t) async {
      final app = _App(pres: _idle(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      final c = t.getCenter(find.text('Sync now'));
      expect(t.getSize(find.text('Sync now')).height, lessThan(30));
      await t.tapAt(c + const Offset(0, 20));
      await t.pump();
      expect(app.syncs, 1);
      await t.tapAt(c - const Offset(0, 20));
      await t.pump();
      expect(app.syncs, 2);
      await _end(t);
    });

    testWidgets('Sync now starts one sync', (t) async {
      final app = _App(pres: _idle(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      await t.tap(find.text('Sync now'));
      await t.pump();
      expect(app.syncs, 1);
      await _end(t);
    });

    testWidgets('the old card is gone: no SyncControl, no "Synced 1 h ago"',
        (t) async {
      final app = _App(pres: _idle(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      expect(find.byType(SyncControl), findsNothing);
      expect(find.text('Synced 1 h ago'), findsNothing);
      final greetingY = _y(t, find.textContaining('Good afternoon'));
      for (final card in find.byType(Surface).evaluate()) {
        expect(t.getCenter(find.byWidget(card.widget)).dy, greaterThan(greetingY),
            reason: 'nothing above the greeting is a card any more');
      }
      // The status is below the greeting now, not above it.
      expect(_y(t, find.textContaining('Good afternoon')),
          lessThan(_y(t, _text('Synced through 15:33'))));
      await _end(t);
    });

    testWidgets('never synced and no data: honest absence, nothing invented',
        (t) async {
      final app = _App(battery: null);
      addTearDown(app.dispose);
      await _pump(t, app);
      expect(find.text('No band data yet'), findsOneWidget);
      expect(find.textContaining(' ago'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      expect(find.text('Connected'), findsOneWidget,
          reason: 'no battery reading: the connection alone, no placeholder');
      expect(find.text('Sync now'), findsOneWidget);
      await _end(t);
    });
  });

  group('syncing', () {
    testWidgets('the status sentence leads, then the timer, then Show details',
        (t) async {
      final app = _App(pres: _syncing(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);

      final timer = _text(_clockRe);
      final details = find.text('Show details');
      expect(_status, findsOneWidget);
      expect(timer, findsOneWidget);
      expect(details, findsOneWidget);
      expect(_x(t, _status), lessThan(_x(t, timer)));
      expect(_x(t, timer), lessThan(_x(t, details)));
      expect((_y(t, _status) - _y(t, timer)).abs(), lessThan(2));
      expect((_y(t, _status) - _y(t, details)).abs(), lessThan(2));
      // No percentage, no estimate on the line.
      expect(find.textContaining('%'), findsOneWidget,
          reason: 'only the battery level');
      expect(find.textContaining('to go'), findsNothing);

      // "Synced through" takes a back seat by getting out of the way: it is in
      // the sheet, not on the line, while a status shows.
      expect(_through, findsNothing);
      expect(find.textContaining('Synced through'), findsNothing);

      // Sync now and the old trailing spinner are gone; the connection line
      // is unchanged.
      expect(find.text('Sync now'), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('1 h ago'), findsNothing);
      expect(find.text('59% · Connected'), findsOneWidget);
      await _end(t);
    });

    testWidgets('the spinner lives in the settings button, in its on-colour',
        (t) async {
      final app = _App(pres: _syncing(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);

      // The one spinner is inside the settings button; the gear icon is gone.
      expect(_spinner, findsOneWidget);
      expect(find.descendant(of: _settingsButton, matching: _spinner),
          findsOneWidget);
      expect(_gear, findsNothing);

      // Same place as the gear was: far right, centred on the header block.
      final top = t.getTopLeft(find.textContaining('Good afternoon')).dy;
      final bottom = t.getBottomLeft(find.text('59% · Connected')).dy;
      expect(t.getCenter(_spinner).dy, closeTo((top + bottom) / 2, 2));
      expect(t.getTopRight(_settingsButton).dx, lessThanOrEqualTo(390));
      expect(t.getTopLeft(_settingsButton).dx, greaterThan(300));

      // Contrast: the spinner is drawn in the colour the gear icon uses on this
      // fill (inkOnFill), and that colour reads against the fill.
      final p = P.of(t.element(find.byType(HomeScreen)));
      final spinner = t.widget<CircularProgressIndicator>(_spinner);
      expect(spinner.color, p.inkOnFill);
      final fill = p.fill(C.domHome);
      final (hi, lo) = p.inkOnFill.computeLuminance() > fill.computeLuminance()
          ? (p.inkOnFill, fill)
          : (fill, p.inkOnFill);
      expect(
        (hi.computeLuminance() + .05) / (lo.computeLuminance() + .05),
        greaterThanOrEqualTo(4.5),
      );

      // The button keeps its label, with "syncing" added.
      final label = t.widget<Pressable>(_settingsButton).semanticLabel!;
      expect(label, startsWith('Profile and settings'));
      expect(label, contains('syncing'));
      await _end(t);
    });

    testWidgets('the settings button still opens Settings while syncing',
        (t) async {
      final app = _App(pres: _syncing(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      expect(find.byType(MoreSettings), findsNothing);
      await t.tap(_spinner);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(MoreSettings), findsOneWidget);
      expect(app.syncs, 0, reason: 'the spinner is not a second sync button');
      await _end(t);
    });

    testWidgets('the center line is not taller while syncing', (t) async {
      final idle = _App(pres: _idle(), through: _edge);
      addTearDown(idle.dispose);
      await _pump(t, idle);
      final idleGap = t.getTopLeft(find.text('59% · Connected')).dy -
          t.getBottomLeft(find.text('Sunday, 4 October')).dy;
      await _end(t);

      final app = _App(pres: _syncing(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      final gap = t.getTopLeft(find.text('59% · Connected')).dy -
          t.getBottomLeft(find.text('Sunday, 4 October')).dy;
      expect(gap, closeTo(idleGap, 2));
      await _end(t);
    });

    testWidgets('Show details opens a bottom sheet with the four steps',
        (t) async {
      final app = _App(pres: _syncing(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      expect(find.byType(BottomSheet), findsNothing);
      for (final s in const ['Connect', 'Download', 'Calculate', 'Done']) {
        expect(find.text(s), findsNothing, reason: '$s is not inline on Home');
      }
      await t.tap(find.text('Show details'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(BottomSheet), findsOneWidget);
      for (final s in const ['Connect', 'Download', 'Calculate', 'Done']) {
        expect(
          find.descendant(of: find.byType(BottomSheet), matching: find.text(s)),
          findsOneWidget,
          reason: s,
        );
      }
      expect(
        find.descendant(
            of: find.byType(BottomSheet), matching: _text(_clockRe)),
        findsOneWidget,
        reason: 'the sheet carries the running time too',
      );
      await _end(t);
    });

    testWidgets('Show details keeps its 44 pt target: a tap 20 pt below lands',
        (t) async {
      final app = _App(pres: _syncing(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      await t.tapAt(t.getCenter(find.text('Show details')) + const Offset(0, 20));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(BottomSheet), findsOneWidget);
      await _end(t);
    });

    testWidgets('tapping the status text does not expand anything inline',
        (t) async {
      final app = _App(pres: _syncing(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      await t.tap(_status);
      await t.pump();
      expect(find.text('Connect'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      await _end(t);
    });
  });

  group('a problem', () {
    testWidgets('a failed sync leads the line, with Retry in the button slot',
        (t) async {
      final app = _App(pres: _failed(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      expect(find.text('Sync failed'), findsOneWidget);
      // The problem is the status: "Synced through" gives way to it.
      expect(_through, findsNothing);
      expect(find.text('Show details'), findsOneWidget);
      expect(_x(t, find.text('Sync failed')),
          lessThan(_x(t, find.text('Show details'))));
      expect((_y(t, find.text('Sync failed')) - _y(t, find.text('Show details'))).abs(),
          lessThan(2));
      // Retry is in the slot, on the center line's block, left of the gear.
      expect(_y(t, find.text('Retry')),
          inInclusiveRange(t.getTopLeft(find.text('Sync failed')).dy,
              t.getBottomLeft(find.text('Show details')).dy));
      expect(t.getTopRight(find.text('Retry')).dx,
          lessThan(t.getTopLeft(_gear).dx));
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Sync now'), findsNothing);
      expect(find.text('1 h ago'), findsOneWidget);
      // The reason is the sheet's, not the line's.
      expect(find.textContaining('Pair a band before syncing'), findsNothing);
      await _end(t);
    });

    testWidgets('it still opens the sheet, which says why', (t) async {
      final app = _App(pres: _failed(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      await t.tap(find.text('Show details'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.textContaining('Pair a band before syncing'), findsWidgets);
      expect(find.text('Connect'), findsOneWidget);
      await _end(t);
    });

    testWidgets('a sync that left days for another pass is a problem too',
        (t) async {
      final app = _App(
        pres: SyncPresentationState(
          phase: 'completed',
          partial: true,
          lastSuccess: DateTime.now().subtract(const Duration(minutes: 61)),
          steps: [_step(SyncStepId.connect, SyncStepStatus.done)],
        ),
        through: _edge,
      );
      addTearDown(app.dispose);
      await _pump(t, app);
      expect(find.text('Needs another pass'), findsOneWidget);
      expect(find.text('Show details'), findsOneWidget);
      await _end(t);
    });
  });

  group('not connected', () {
    testWidgets('the battery line says so; the center line is unchanged',
        (t) async {
      final app = _App(
        pres: SyncPresentationState(
          phase: 'offline',
          lastSuccess: DateTime.now().subtract(const Duration(minutes: 61)),
        ),
        connection: 'disconnected',
        through: _edge,
      );
      addTearDown(app.dispose);
      await _pump(t, app);
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.textContaining('Connected'), findsNothing);
      expect(_text('Synced through 15:33'), findsOneWidget);
      expect(find.text('1 h ago'), findsOneWidget);
      expect(find.text('Sync now'), findsOneWidget);
      expect(find.text('Show details'), findsNothing);
      await _end(t);
    });
  });

  group('360 pt at 1.3x text', () {
    for (final (name, make) in <(String, SyncPresentationState Function())>[
      ('idle', _idle),
      ('syncing', _syncing),
      ('failed', _failed),
    ]) {
      testWidgets('$name: nothing overflows, the label shortens', (t) async {
        final app = _App(pres: make(), through: _edge);
        addTearDown(app.dispose);
        await _pump(t, app, width: 360, scale: 1.3);
        expect(t.takeException(), isNull);
        if (name == 'idle') {
          expect(_text('Through 15:33'), findsOneWidget,
              reason: '"Synced through" gives way before anything overflows');
          expect(_text('Synced through 15:33'), findsNothing);
        } else {
          expect(_through, findsNothing, reason: 'a status leads instead');
        }
        // Everything on the center line is inside the screen.
        for (final f in [
          find.text('Sync now'),
          find.text('Retry'),
          find.text('Show details'),
          _status,
          _spinner,
        ]) {
          if (f.evaluate().isEmpty) continue;
          expect(t.getTopRight(f.first).dx, lessThanOrEqualTo(360));
        }
        expect(t.getTopRight(_settingsButton).dx, lessThanOrEqualTo(360));
        await _end(t);
      });
    }

    testWidgets('the sheet fits too', (t) async {
      final app = _App(pres: _syncing(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app, width: 360, scale: 1.3);
      await t.tap(find.text('Show details'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(t.takeException(), isNull);
      expect(find.byType(BottomSheet), findsOneWidget);
      await _end(t);
    });
  });

  testWidgets('with no AppState (a golden) the line is just the data edge',
      (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(390, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: const Scaffold(
        body: HomeScreen(data: HomeData(dayId: '2026-10-04'), hour: 15),
      ),
    ));
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.text('No band data yet'), findsOneWidget);
    expect(find.text('Sync now'), findsNothing);
    expect(find.textContaining('onnected'), findsNothing);
  });
}
