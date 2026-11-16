// Renders of the day-timeline pilot's screens in every state (dark theme,
// bundled fonts) for review against the mock-ups. Not a golden: it writes
// PNGs to $DT_SHOTS_DIR and asserts nothing about pixels. Skipped unless
// DT_SHOTS=1.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:openstrap_edge/gestures/moment_review_service.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/day_timeline/activities_timeline.dart';
import 'package:openstrap_edge/ui2/day_timeline/night_card.dart';
import 'package:openstrap_edge/ui2/day_timeline/pilot_flags.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_timeline_editor.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_chart.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_model.dart';
import 'package:openstrap_edge/ui2/screens/day_review.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';

import '../support/apk2_review_harness.dart';
import '../support/as_of_recalc_fakes.dart' show settle;
import '../support/bundled_fonts.dart';
import '../support/day_timeline_fixtures.dart';

final _on = Platform.environment['DT_SHOTS'] == '1';
final _dir = Directory(Platform.environment['DT_SHOTS_DIR'] ?? 'build/dt-shots');
const _shotKey = ValueKey('dt-shot');

Future<void> frames(WidgetTester t, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> shot(WidgetTester t, String name) async {
  await t.pump();
  final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
  await t.runAsync(() async {
    final ui.Image img = await boundary.toImage(pixelRatio: 2);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    _dir.createSync(recursive: true);
    File('${_dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> filterKinds(WidgetTester t,Set<String> kinds)async{
 await apk2Tap(t,find.byKey(ActivitiesTimeline.filterButtonKey));await t.pumpAndSettle();
 for(final kind in [...kinds,...{'pending','saved','discarded'}.difference(kinds)]){
  final f=find.byKey(ValueKey('activity-kind:$kind'));
  if(t.widget<CheckboxListTile>(f).value!=kinds.contains(kind)){await t.tap(f);await t.pumpAndSettle();}
 }
 Navigator.of(t.element(find.text('Show activities'))).pop();await t.pumpAndSettle();
}

class _NoCard implements NightCardListener {
  @override
  void recalculate() {}
  @override
  void notSleep() {}
  @override
  void backToAutomatic() {}
  @override
  void setEnd(BlockEnd which, DateTime to) {}
  @override
  void openTimeline() {}
  @override
  void openNaps() {}
}

class _Never implements SleepEditSaver {
  @override
  ({Future<void> written, Future<SleepOperationResult> done}) save(SleepEditPlan plan) =>
      (written: Completer<void>().future, done: Completer<SleepOperationResult>().future);
}

class _Quiet implements TimelineHaptics {
  @override
  void tick(HapticTier tier) {}
  @override
  void fineMode() {}
}

Widget _frame(Widget child) => RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark),
        builder: (c, w) => MediaQuery(
            data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: false), child: w!),
        home: child,
      ),
    );

void main() {
  setUpAll(() async {
    if (_on) {
      await loadFonts();
      // The time wheel's own font is not bundled: draw it in the app's.
      for (final family in ['CupertinoSystemText', 'CupertinoSystemDisplay']) {
        final loader = FontLoader(family);
        for (final f in Directory('assets/fonts/Manrope').listSync().whereType<File>()) {
          if (f.path.endsWith('.ttf')) {
            loader.addFont(f.readAsBytes().then((b) => ByteData.sublistView(b)));
          }
        }
        await loader.load();
      }
    }
  });

  testWidgets('night card, every state', (t) async {
    t.view.physicalSize = const Size(412 * 2, 420 * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final onset = DateTime(2026, 11, 13, 23), wake = DateTime(2026, 11, 14, 7, 6);
    final states = {
      'auto': NightCardModel(source: NightSource.auto, onset: onset, wake: wake,
          coveredMin: 470, inBedMin: 486),
      'guessed': NightCardModel(source: NightSource.fallback, onset: onset, wake: wake),
      'you-set-it': NightCardModel(source: NightSource.mine, onset: onset, wake: wake,
          changedAt: DateTime(2026, 11, 14, 8, 12)),
      'not-sleep': NightCardModel(source: NightSource.rejected, onset: onset, wake: wake),
      'recalculating': NightCardModel(source: NightSource.auto, recalculating: true,
          onset: onset, wake: wake),
    };
    for (final e in states.entries) {
      await t.pumpWidget(_frame(Scaffold(body: Padding(padding: const EdgeInsets.all(16),
          child: Column(children: [
            NightCard(key: ValueKey(e.key), model: e.value, listener: _NoCard()),
          ])))));
      await t.pump(const Duration(milliseconds: 800));
      await shot(t, 'sleep-card-${e.key}');
      if (e.key == 'auto') {
        await t.tap(find.byKey(NightCard.recalcKey));
        await frames(t);
        await shot(t, 'sleep-card-dialog-recalculate');
        await t.tap(find.text('Cancel'));
        await frames(t);
        await t.tap(find.byKey(NightCard.notSleepKey));
        await frames(t);
        await shot(t, 'sleep-card-dialog-not-sleep');
        await t.tap(find.text('Cancel'));
        await frames(t);
        t.view.physicalSize = const Size(412 * 2, 600 * 2);
        await t.pump();
        await t.tap(find.byKey(NightCard.chipKey(BlockEnd.end)));
        await frames(t);
        await shot(t, 'sleep-card-wheel-woke');
        await t.tap(find.text('Cancel'));
        await frames(t);
        t.view.physicalSize = const Size(412 * 2, 420 * 2);
      }
    }
  }, skip: !_on);

  testWidgets('sleep timeline editor, every state', (t) async {
    t.view.physicalSize = const Size(412 * 2, 1180 * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(_frame(SleepTimelineEditor(data: dtNight(), save: _Never(), haptics: _Quiet())));
    await t.pump();
    final s = t.state<SleepTimelineEditorState>(find.byType(SleepTimelineEditor));
    await shot(t, 'sleep-editor-main-active');
    Offset at(double ts, {double dy = 130}) {
      final r = t.getRect(find.byKey(DayTimelineChart.chartKey));
      return Offset(r.left + 44 + s.controller.view.fraction(ts) * (r.width - 52), r.top + dy);
    }
    // Scrub: the readout shows that moment.
    var g = await t.startGesture(at(dtAt(300).toDouble()));
    await g.moveBy(const Offset(30, 0));
    await t.pump();
    await g.up();
    await t.pump(const Duration(milliseconds: 500));
    await shot(t, 'sleep-editor-scrubbed');
    // Drag the wake end: coarse, then held still for 1-minute steps.
    g = await t.startGesture(at(s.blocks.first.end.toDouble()));
    await g.moveBy(const Offset(24, 0));
    await t.pump();
    await shot(t, 'sleep-editor-magnifier-5min');
    await t.pump(const Duration(milliseconds: 700));
    await g.moveBy(const Offset(3, 0));
    await t.pump();
    await shot(t, 'sleep-editor-magnifier-1min');
    await g.up();
    await t.pump(const Duration(seconds: 1));
    // Add sleep block: the side question, then the new nap active.
    await t.tap(find.byKey(SleepTimelineEditor.addKey));
    await t.pump();
    await shot(t, 'sleep-editor-add-ask-side');
    await t.tap(find.byKey(const ValueKey('sleep-editor-banner:After')));
    await t.pump();
    await t.pump(const Duration(seconds: 3));
    await shot(t, 'sleep-editor-nap-active');
    await t.tap(find.byKey(const ValueKey('sleep-editor-banner:Done')));
    await t.pump();
    await t.pump(const Duration(seconds: 3));
    // Double tap zooms in around the tap; Reset zoom appears.
    await t.tapAt(at(dtAt(400).toDouble()));
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(at(dtAt(400).toDouble()));
    await t.pump();
    await t.pump(const Duration(milliseconds: 800));
    await shot(t, 'sleep-editor-zoom-gliding');
    await t.pump(const Duration(seconds: 2));
    await shot(t, 'sleep-editor-zoomed');
    // ignore: avoid_print
    print('preview stager last update: ${s.lastStageMicros} µs');
  }, skip: !_on);

  testWidgets('unsupported sleep previews', (t) async {
    t.view.physicalSize = const Size(412 * 2, 1100 * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final d = dtNight();
    for (final gap in [false, true]) {
      final missing = SleepEditorData(day: d.day, domainStart: d.domainStart,
          hr: [for (var i = 0; i < 1440; i++) gap && (i < 360 || i >= 420) ? d.hr[i] : null],
          movement: [for (var i = 0; i < 1440; i++) gap && (i < 360 || i >= 420) ? d.movement[i] : null],
          main: d.main);
      await t.pumpWidget(_frame(SleepTimelineEditor(key: ValueKey(gap),
          data: missing, save: _Never(), haptics: _Quiet())));
      await t.pump();
      await shot(t, gap ? 'sleep-editor-partial-gap' : 'sleep-editor-no-signals');
      if (gap) {
        final s = t.state<SleepTimelineEditorState>(find.byType(SleepTimelineEditor));
        s.controller.setScrub(dtAt(390).toDouble());
        s.scrubbed(dtAt(390).toDouble());
        await t.pump();
        await shot(t, 'sleep-editor-gap-scrubbed');
      }
    }
  }, skip: !_on);

  group('activities', () {
    setUp(() {
      DayTimelinePilot.debugOverride[DayTimelinePilot.activities] = true;
      DayReviewController.debugClearDrafts();
    });
    tearDown(() {
      DayTimelinePilot.debugOverride.clear();
      DayReviewController.debugClearDrafts();
    });

    Future<Apk2Rig> mountDark(WidgetTester t) async {
      final rig = await Apk2Rig.create(t);
      t.view.physicalSize = const Size(412 * 2, 900 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final theme = ThemeController.seed(AppThemeChoice.dark, Brightness.dark);
      addTearDown(theme.dispose);
      final service = MomentReviewService();
      addTearDown(service.dispose);
      await t.pumpWidget(MultiProvider(providers: [
        ChangeNotifierProvider<AppState>.value(value: rig.app),
        ChangeNotifierProvider<ThemeController>.value(value: theme),
      ], child: RepaintBoundary(key: _shotKey, child: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: rig.navigator,
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: Center(child: TextButton(
            onPressed: () => rig.navigator.currentState!.push(MaterialPageRoute<void>(
                builder: (_) => const DayTimelineScreen(day: apk2Day))),
            child: const Text('Open breakdown')))),
      ))));
      await t.tap(find.text('Open breakdown'));
      await settle(t);
      return rig;
    }

    testWidgets('every state', (t) async {
      final rig = await mountDark(t);
      final s = t.state<ActivitiesTimelineState>(find.byType(ActivitiesTimeline));
      await shot(t, 'activities-review-emphasis');
      // Scrub to the evening workout: the list follows.
      final r = t.getRect(find.byKey(DayTimelineChart.chartKey));
      Offset at(int ts) => Offset(r.left + 44 + s.controller.view.fraction(ts.toDouble()) * (r.width - 52), r.top + 100);
      final g = await t.startGesture(at(apk2At(16)));
      await g.moveTo(at(apk2At(18, 10)));
      await t.pump();
      await g.up();
      await settle(t);
      await shot(t, 'activities-scrubbed-list-synced');
      // Stage decisions.
      await apk2Tap(t, apk2Keep(apk2WorkoutB));
      await apk2Tap(t, apk2Discard(apk2NapB));
      await shot(t, 'activities-staged-unsaved');
      await apk2Tap(t, apk2Key('day-row-edit:$apk2Answered'));
      await t.enterText(apk2Key('moment-note:2026-10-06 20:45'), 'Edited in the Activities draft');
      await shot(t, 'activities-saved-moment-editor');
      await apk2Tap(t, apk2Key('moment-edit-save'));
      await shot(t, 'activities-saved-edit-staged');

      // ⌕ zoom: handles, then glide.
      await t.tap(find.byKey(ActivitiesTimeline.zoomKey));
      await t.pump();
      await shot(t, 'activities-zoom-handles');
      await t.tap(find.byKey(ActivitiesTimeline.zoomKey));
      await t.pump();
      await t.pump(const Duration(seconds: 3));
      await shot(t, 'activities-zoomed');
      // Cancel's dialog.
      await t.tap(find.byKey(ActivitiesSaveBar.cancelKey));
      await frames(t);
      await shot(t, 'activities-cancel-dialog');
      await t.tap(find.text('Keep editing'));
      await frames(t);
      // Leave and come back: the draft.
      await rig.navigator.currentState!.maybePop();
      await settle(t);
      await t.tap(find.text('Open breakdown'));
      await settle(t);
      await shot(t, 'activities-draft-on-return');
      // Save, then the discarded filter with Restore.
      await apk2Tap(t, find.byKey(ActivitiesSaveBar.saveKey));
      await settle(t);
      await filterKinds(t,{'discarded'});
      await settle(t);
      await shot(t, 'activities-only-discarded');
      await apk2Tap(t, find.byKey(ActivitiesTimeline.restoreKey('discarded:activity:apk2-nap-b')));
      await shot(t, 'activities-restore-staged');
      await filterKinds(t,{'pending','saved','discarded'});
      await shot(t, 'activities-filter-all');
      await apk2Tap(t, find.byKey(ActivitiesSaveBar.cancelKey));
      await t.pump(const Duration(milliseconds: 400));
      await apk2Tap(t, find.byKey(const ValueKey('activities-cancel-confirm')));
      await filterKinds(t,{'pending','saved'});
      // Everything answered: annotations back to normal.
      for (final id in apk2MixedIds) {
        if (find.byKey(ValueKey('apk2-review-keep:$id')).evaluate().isEmpty) continue;
        await apk2Tap(t, apk2Keep(id));
      }
      await shot(t, 'activities-all-answered-no-emphasis');
    }, skip: !_on);
  });
}
