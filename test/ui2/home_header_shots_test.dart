// Screenshot script for Home's greeting-header sync layout. Not a regression
// test: it is skipped unless HOME_HEADER_SHOTS=1, and then writes PNGs of the
// header so a layout change can be judged by eye:
//
//   HOME_HEADER_SHOTS=1 nix develop -c flutter test test/ui2/home_header_shots_test.dart
//
// It pumps the real HomeScreen with the app theme (dark and light), the real
// Manrope type, at device pixel ratio 3, in five states, and writes
// date-first-<theme>-<state>.png plus one contact sheet per theme to
// ../edge.research/shots/home-header/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../sources/support/fonts.dart';

final _enabled = Platform.environment['HOME_HEADER_SHOTS'] == '1';
const _outDir = '/home/v0id/Documents/repos/edge.research/shots/home-header';

class _App extends AppState {
  _App(this.pres) : super.forTesting();

  final SyncPresentationState pres;

  @override
  SyncPresentationState get syncPresentation => pres;
  @override
  DeviceState get device => DeviceState(connection: 'connected')
    ..batteryPct = 56
    ..charging = false;
  @override
  DateTime? get lastRecordAt => DateTime(2026, 10, 4, 15, 33);
}

SyncStep _step(SyncStepId id, SyncStepStatus s, {DateTime? at}) =>
    SyncStep(id: id, status: s, startedAt: at, endedAt: null);

SyncPresentationState _idle() => SyncPresentationState(
  phase: 'idle',
  lastSuccess: DateTime.now().subtract(const Duration(minutes: 61)),
);

/// 22 s into a sync, in the calculate step: "Calculating…  0:22".
SyncPresentationState _calculating() {
  final start = DateTime.now().subtract(const Duration(seconds: 22));
  return SyncPresentationState(
    phase: 'deriving',
    busy: true,
    contactedBand: true,
    startedAt: start,
    lastSuccess: DateTime.now().subtract(const Duration(minutes: 61)),
    steps: [
      _step(SyncStepId.connect, SyncStepStatus.done, at: start),
      _step(SyncStepId.download, SyncStepStatus.done, at: start),
      _step(SyncStepId.calculate, SyncStepStatus.running, at: start),
      _step(SyncStepId.done, SyncStepStatus.waiting),
    ],
  );
}

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

typedef _Shot = ({
  String name,
  SyncPresentationState Function() pres,
  double width,
  double scale,
});

final _shots = <_Shot>[
  (name: 'idle', pres: _idle, width: 390, scale: 1),
  (name: 'syncing', pres: _calculating, width: 390, scale: 1),
  (name: 'syncing-360-large', pres: _calculating, width: 360, scale: 1.3),
  (name: 'problem', pres: _failed, width: 390, scale: 1),
  (name: 'problem-360-large', pres: _failed, width: 360, scale: 1.3),
];

const _height = 260.0;
const _layout = 'date-first';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'write the Home header screenshots',
    (t) async {
      Directory(_outDir).createSync(recursive: true);
      for (final dark in [true, false]) {
        final theme = dark ? 'dark' : 'light';
        final images = <String, ui.Image>{};
        for (final shot in _shots) {
          final app = _App(shot.pres());
          addTearDown(app.dispose);
          const dpr = 3.0;
          t.view.devicePixelRatio = dpr;
          t.view.physicalSize = Size(shot.width * dpr, _height * dpr);
          final key = GlobalKey();
          final brightness = dark ? Brightness.dark : Brightness.light;
          await t.pumpWidget(MultiProvider(
            providers: [
              ChangeNotifierProvider<AppState>.value(value: app),
              ChangeNotifierProvider(
                create: (_) => ThemeController.seed(
                  dark ? AppThemeChoice.dark : AppThemeChoice.light,
                  brightness,
                ),
              ),
              ChangeNotifierProvider(
                create: (_) => UnitsController.seed(UnitSystem.metric),
              ),
              ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
            ],
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(brightness),
              builder: (c, child) => MediaQuery(
                data: MediaQuery.of(c)
                    .copyWith(textScaler: TextScaler.linear(shot.scale)),
                child: child!,
              ),
              home: RepaintBoundary(
                key: key,
                child: Scaffold(
                  body: HomeScreen(
                    data: const HomeData(dayId: '2026-10-04'),
                    hour: 20,
                  ),
                ),
              ),
            ),
          ));
          await t.pump();
          expect(t.takeException(), isNull);

          final boundary =
              t.renderObject(find.byKey(key)) as RenderRepaintBoundary;
          final name = '$_layout-$theme-${shot.name}';
          await t.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: dpr);
            final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
            File('$_outDir/$name.png')
                .writeAsBytesSync(bytes!.buffer.asUint8List());
            images[name] = image;
          });
          // A running sync holds a 1 s ticker: take the tree down first.
          await t.pumpWidget(const SizedBox());
        }
        await t.runAsync(() => _contactSheet(theme, dark, images));
        t.view.reset();
      }
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

/// One sheet per theme: a row per state, each cell labelled. The cells are the captured images, so nothing is redrawn.
Future<void> _contactSheet(
    String theme, bool dark, Map<String, ui.Image> images) async {
  const dpr = 3.0;
  const pad = 24.0 * dpr, label = 28.0 * dpr;
  const cellW = 390.0 * dpr, cellH = _height * dpr;
  final rows = _shots.length;
  final w = pad + cellW + pad;
  final h = pad + rows * (label + cellH + pad);
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  canvas.drawRect(Rect.fromLTWH(0, 0, w, h),
      Paint()..color = dark ? const Color(0xFF2A2A2A) : const Color(0xFFD8D8D8));
  final ink = dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
  for (var row = 0; row < rows; row++) {
    final shot = _shots[row];
    const x = pad;
    final y = pad + row * (label + cellH + pad);
    final tp = TextPainter(
      text: TextSpan(
        text: '$_layout / ${shot.name}',
        style: TextStyle(fontFamily: 'Manrope', fontSize: 14 * dpr, color: ink),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x, y));
    tp.dispose();
    final image = images['$_layout-$theme-${shot.name}']!;
    canvas.drawImage(image, Offset(x, y + label), Paint());
  }
  final sheet = await rec.endRecording().toImage(w.round(), h.round());
  final bytes = await sheet.toByteData(format: ui.ImageByteFormat.png);
  File('$_outDir/contact-$theme.png')
      .writeAsBytesSync(bytes!.buffer.asUint8List());
}
