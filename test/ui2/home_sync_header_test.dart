// Oct 4: Home's sync UI lives in the greeting header, not in a card above it.
//
//   Good afternoon
//   Sunday, 4 October
//   Synced through 15:33          1 h ago [Sync now] (gear)   <- center line
//   59% · Connected
//
// While syncing the timer sits LEFT of "Show details" on the center line and a
// spinner takes the button's place. A problem sentence leads "Show details".
// "Show details" opens a bottom sheet with the four steps; Home no longer
// expands them inline. No percentages, no estimates: absent means nothing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/state/app_state.dart';
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

Widget _home(AppState app, {double scale = 1}) => MaterialApp(
  theme: buildTheme(Brightness.light),
  builder: (c, child) => MediaQuery(
    data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: ChangeNotifierProvider<AppState>.value(
    value: app,
    child: const Scaffold(
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
    testWidgets('timer sits left of Show details; a spinner replaces the button',
        (t) async {
      final app = _App(pres: _syncing(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);

      final through = _through;
      final timer = _text(_clockRe);
      final details = find.text('Show details');
      expect(through, findsOneWidget);
      expect(timer, findsOneWidget);
      expect(details, findsOneWidget);
      expect(_x(t, through), lessThan(_x(t, timer)));
      expect(_x(t, timer), lessThan(_x(t, details)));
      expect((_y(t, through) - _y(t, timer)).abs(), lessThan(2));
      expect((_y(t, through) - _y(t, details)).abs(), lessThan(2));

      // Spinner in the button's place: right of the details link, left of the
      // gear, and no button text and no "N h ago" competing with the timer.
      expect(_spinner, findsOneWidget);
      expect(_x(t, details), lessThan(_x(t, _spinner)));
      expect(t.getTopRight(_spinner).dx, lessThan(t.getTopLeft(_gear).dx));
      expect(find.text('Sync now'), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('1 h ago'), findsNothing);
      // The connection line is unchanged.
      expect(find.text('59% · Connected'), findsOneWidget);
      await _end(t);
    });

    testWidgets('the spinner is not a second button', (t) async {
      final app = _App(pres: _syncing(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      await t.tap(_spinner);
      await t.pump();
      expect(app.syncs, 0);
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

    testWidgets('tapping the status text does not expand anything inline',
        (t) async {
      final app = _App(pres: _syncing(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      await t.tap(_through);
      await t.pump();
      expect(find.text('Connect'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      await _end(t);
    });
  });

  group('a problem', () {
    testWidgets('a failed sync leads Show details, with Retry in the button slot',
        (t) async {
      final app = _App(pres: _failed(), through: _edge);
      addTearDown(app.dispose);
      await _pump(t, app);
      expect(find.text('Sync failed'), findsOneWidget);
      expect(find.text('Show details'), findsOneWidget);
      expect(_x(t, find.text('Sync failed')),
          lessThan(_x(t, find.text('Show details'))));
      expect((_y(t, find.text('Sync failed')) - _y(t, find.text('Show details'))).abs(),
          lessThan(2));
      // Retry is in the slot, on the center line's block, left of the gear.
      expect(_y(t, find.text('Retry')),
          inInclusiveRange(t.getTopLeft(_through).dy,
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
        expect(_text('Through 15:33'), findsOneWidget,
            reason: '"Synced through" gives way before anything overflows');
        expect(_text('Synced through 15:33'), findsNothing);
        // Everything on the center line is inside the screen.
        for (final f in [
          find.text('Sync now'),
          find.text('Retry'),
          find.text('Show details'),
          _spinner,
        ]) {
          if (f.evaluate().isEmpty) continue;
          expect(t.getTopRight(f.first).dx, lessThanOrEqualTo(360));
        }
        expect(t.getTopRight(_gear).dx, lessThanOrEqualTo(360));
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
