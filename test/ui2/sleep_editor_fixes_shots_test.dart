// Captures actual Flutter editor states for owner inspection. These are
// evidence, not pixel goldens; the behavior assertions live beside this file.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_timeline_editor.dart';
import 'package:openstrap_edge/ui2/theme.dart';

import '../support/bundled_fonts.dart';
import '../support/day_timeline_fixtures.dart';

class _Never implements SleepEditSaver {
  @override
  ({Future<void> written, Future<SleepOperationResult> done}) save(SleepEditPlan plan) =>
    (written: Completer<void>().future, done: Completer<SleepOperationResult>().future);
}

void main() {
  testWidgets('dark default, zoomed and selected nap renders', (t) async {
    t.view.physicalSize = const Size(412, 1300);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await loadFonts();
    const shotKey = ValueKey('editor-fixes-shot');
    Future<void> shot(String name) async {
      expect(t.takeException(), isNull);
      final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
      await t.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('build/editor-fixes-shots')..createSync(recursive: true);
        File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await t.pumpWidget(RepaintBoundary(key: shotKey, child: MaterialApp(
      debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.dark),
      home: SleepTimelineEditor(data: dtNight(withNap: false), save: _Never()),
    )));
    await t.pumpAndSettle();
    await shot('editor-default');
    await t.tap(find.byKey(const ValueKey('sleep-editor-zoom-in')));
    await t.pumpAndSettle();
    await shot('editor-zoomed');
    await t.pumpWidget(RepaintBoundary(key: shotKey, child: MaterialApp(
      debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.dark),
      home: SleepTimelineEditor(key: const ValueKey('nap-state'), data: dtNight(), save: _Never()),
    )));
    await t.pumpAndSettle();
    final state = t.state<SleepTimelineEditorState>(find.byType(SleepTimelineEditor));
    state.blockSelected(state.blocks.last.id, zoom: false);
    await t.pumpAndSettle();
    await shot('editor-with-nap');
  }, skip: Platform.environment['EDITOR_FIXES_SHOTS'] != '1');
}
