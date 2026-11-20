import 'dart:io';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/derive_progress.dart';
import 'package:openstrap_edge/ui2/app_shell.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Pressable;
import 'package:openstrap_edge/ui2/home_header.dart';
import 'package:openstrap_edge/ui2/profile/home_header_settings.dart';
import 'package:openstrap_edge/ui2/theme.dart';

import 'support/bundled_fonts.dart';
import 'support/header_rows_fakes.dart';
import 'support/home_header_pilot_fakes.dart';

const _header = ValueKey('home-header');
const _settings = ValueKey('header-choice');

Future<void> _save(WidgetTester t, GlobalKey boundary, String path,
    {Key crop = _header}) async {
  final canvasBox = t.renderObject<RenderRepaintBoundary>(find.byKey(boundary));
  final box = canvasBox.size;
  final cropBounds = t.getRect(find.byKey(crop));
  final relativeTop = cropBounds.top - canvasBox.localToGlobal(Offset.zero).dy;
  const ratio = 3.0;
  final width = (box.width * ratio).round();
  final height = ((cropBounds.height + 38) * ratio).round();
  await t.runAsync(() async {
    final full = await canvasBox.toImage(pixelRatio: ratio);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawColor(const P(true).bg, ui.BlendMode.src);
    final source = Rect.fromLTWH(0, relativeTop * ratio,
      width.toDouble(), cropBounds.height * ratio);
    canvas.drawImageRect(
      full, source, Rect.fromLTWH(0, 19 * ratio, source.width, source.height),
      Paint(),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File(path).writeAsBytes(data.buffer.asUint8List());
    } finally {
      full.dispose();
      image.dispose();
      picture.dispose();
    }
  });
}

typedef _Frame = ({
  String id,
  String phase,
  bool compact,
  bool expanded,
  bool opening,
  bool connected,
});

void main() {
  final out = Platform.environment['HOME_HEADER_PILOT_SHOTS'];
  setUpAll(() async {
    if (out == null) return;
    await loadFonts();
    Directory(out).createSync(recursive: true);
  });
  setUp(h24);
  tearDown(ClockFormatController.debugReset);

  const frames = <_Frame>[
    (id: '1', phase: 'downloading', compact: false, expanded: false, opening: true, connected: true),
    (id: '2', phase: 'deriving', compact: false, expanded: false, opening: false, connected: true),
    (id: '3', phase: 'idle', compact: false, expanded: false, opening: false, connected: true),
    (id: '3b', phase: 'idle', compact: false, expanded: false, opening: false, connected: false),
    (id: '4', phase: 'deriving', compact: false, expanded: true, opening: false, connected: true),
    (id: '4b', phase: 'failed', compact: false, expanded: true, opening: false, connected: false),
    (id: 'C1', phase: 'downloading', compact: true, expanded: false, opening: false, connected: true),
    (id: 'C2', phase: 'deriving', compact: true, expanded: false, opening: false, connected: true),
    (id: 'C3', phase: 'idle', compact: true, expanded: false, opening: false, connected: true),
    (id: 'E1', phase: 'deriving', compact: true, expanded: true, opening: false, connected: true),
  ];

  for (final frame in frames) {
    testWidgets('capture ${frame.id}', (t) async {
      pilotSurface(t, width: 340);
      final failed = frame.phase == 'failed';
      await pilotPrefs(compact: frame.compact, alertAt: failed ? 30 : null);
      final synced = frame.phase == 'idle'
          ? DateTime(2026, 11, 19, 22, 58) : DateTime(2026, 11, 19, 22, 31);
      final app = PilotHeaderApp(
        pres: switch (frame.phase) {
          'idle' => pilotIdle(lastSync: synced),
          'failed' => pilotSync('downloading', records: 301,
            lastSync: synced, dayIndex: 0, dayTotal: 3),
          _ => pilotSync(frame.phase, lastSync: synced),
        },
        startEdge: pilotStartEdge,
        connection: frame.connected ? 'connected' : 'disconnected',
        battery: failed ? 25 : 50,
      );
      if (frame.phase == 'deriving') {
        app.derive.value = const DeriveProgress(dayIndex: 2, dayTotal: 3);
      }
      addTearDown(app.dispose);
      await withClock(Clock.fixed(pilotNow), () async {
        final key = GlobalKey();
        await t.pumpWidget(pilotApp(app, RepaintBoundary(
          key: key,
          child: HomeHeaderOpening(play: frame.opening,
            child: Scaffold(body: pilotTab(ShellDomain.today))),
        )));
        await t.pump();
        if (failed) {
          app.setPres(pilotSync('failed', records: 301, lastSync: synced,
            dayIndex: 0, dayTotal: 3,
            syncedThrough: DateTime(2026, 11, 19, 19, 14)));
          await t.pump();
        }
        if (frame.expanded) {
          if (frame.compact) {
            await t.longPress(find.byKey(const ValueKey('day-nav-choose')));
          } else {
            final pill = t.getTopLeft(find.byKey(const ValueKey('home-header-pill')));
            await t.tapAt(pill + const Offset(65, 22));
          }
          await t.pump();
          await t.pump(Motion.syncDetails);
        }
        expect(t.takeException(), isNull);
        await _save(t, key, '$out/${frame.id}-build.png');
        await t.pumpWidget(const SizedBox());
      });
    }, skip: out == null);
  }

  testWidgets('capture the same instant on the three tabs', (t) async {
    pilotSurface(t, width: 340);
    await pilotPrefs();
    final app = PilotHeaderApp(
      pres: pilotSync('deriving'), startEdge: pilotStartEdge,
    )..derive.value = const DeriveProgress(dayIndex: 2, dayTotal: 3);
    addTearDown(app.dispose);
    await withClock(Clock.fixed(pilotNow), () async {
      final key = GlobalKey();
      await t.pumpWidget(pilotApp(app, RepaintBoundary(
        key: key,
        child: HomeHeaderOpening(play: false, child: AppShell(
          builder: (_, tab) => pilotTab(tab),
        )),
      )));
      for (final tab in [ShellDomain.today, ShellDomain.sleep, ShellDomain.activity]) {
        if (tab != ShellDomain.today) {
          await t.tap(find.widgetWithText(Pressable, tab.label).last);
          await t.pump();
        }
        expect(t.takeException(), isNull);
        await _save(t, key, '$out/${tab.label}-build.png');
      }
      await t.pumpWidget(const SizedBox());
    });
  }, skip: out == null);

  testWidgets('capture the persisted header choice', (t) async {
    pilotSurface(t, width: 360);
    await pilotPrefs(compact: true);
    final app = PilotHeaderApp();
    addTearDown(app.dispose);
    final key = GlobalKey();
    await t.pumpWidget(pilotApp(app, RepaintBoundary(
      key: key,
      child: const Scaffold(body: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: HomeHeaderChoice(key: _settings),
      )),
    )));
    await t.pump();
    expect(t.takeException(), isNull);
    await _save(t, key, '$out/S1-build.png', crop: _settings);
    await t.pumpWidget(const SizedBox());
  }, skip: out == null);
}
