// Pilot day-timeline, spec Tests §4 (night card) and the sleep editor's parts
// of §2-§3: single/double tap on a band, Add sleep block, Save acknowledged at
// the durable write without waiting for (or locking on) the recalculation,
// Cancel writes nothing.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:openstrap_edge/state/control_operations.dart' show SleepOperationResult;
import 'package:openstrap_edge/ui2/day_timeline/night_card.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_timeline_editor.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_chart.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_model.dart';
import 'package:openstrap_edge/ui2/theme.dart';

import '../support/day_timeline_fixtures.dart';

class _Card implements NightCardListener {
  final calls = <String>[];
  @override
  void recalculate() => calls.add('recalculate');
  @override
  void notSleep() => calls.add('notSleep');
  @override
  void backToAutomatic() => calls.add('back');
  @override
  void setEnd(BlockEnd which, DateTime to) => calls.add('set:${which.name}');
  @override
  void openTimeline() => calls.add('timeline');
  @override
  void openNaps() => calls.add('naps');
}

class _Saver implements SleepEditSaver {
  _Saver(this.saved, this.written, this.done);
  final List<SleepEditPlan> saved;
  final Completer<void> written;
  final Completer<SleepOperationResult> done;
  @override
  ({Future<void> written, Future<SleepOperationResult> done}) save(SleepEditPlan plan) {
    saved.add(plan);
    return (written: written.future, done: done.future);
  }
}

class _Quiet implements TimelineHaptics {
  @override
  void tick(HapticTier tier) {}
  @override
  void fineMode() {}
}

Widget _app(Widget home) => MaterialApp(theme: buildTheme(Brightness.dark), home: home);

void main() {
  final onset = DateTime(2026, 11, 13, 23), wake = DateTime(2026, 11, 14, 7, 6);
  final states = <String, NightCardModel>{
    'auto': NightCardModel(source: NightSource.auto, onset: onset, wake: wake,
        coveredMin: 470, inBedMin: 486),
    'fallback': NightCardModel(source: NightSource.fallback, onset: onset, wake: wake),
    'mine': NightCardModel(source: NightSource.mine, onset: onset, wake: wake,
        changedAt: DateTime(2026, 11, 14, 8, 12)),
    'rejected': NightCardModel(source: NightSource.rejected, onset: onset, wake: wake),
    'recalculating': NightCardModel(source: NightSource.auto, recalculating: true,
        onset: onset, wake: wake),
  };

  Future<_Card> card(WidgetTester t, NightCardModel m) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final l = _Card();
    await t.pumpWidget(_app(Scaffold(body: Align(alignment: Alignment.topCenter,
        child: SizedBox(width: 380, child: NightCard(model: m, listener: l))))));
    await t.pump();
    return l;
  }

  group('§4 night card', () {
    // WHY: spec "the layout is identical in every state; changing state never
    // changes the card's height".
    testWidgets('the same height in every state', (t) async {
      final heights = <String, double>{};
      for (final e in states.entries) {
        await card(t, e.value);
        heights[e.key] = t.getSize(find.byKey(NightCard.cardKey)).height;
      }
      expect(heights.values.toSet(), hasLength(1), reason: '$heights');
    });

    testWidgets('both confirmations appear, and only a confirm acts', (t) async {
      final l = await card(t, states['auto']!);
      await t.tap(find.byKey(NightCard.recalcKey));
      await t.pumpAndSettle();
      expect(find.text('Recalculate this night?'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(l.calls, isEmpty);
      await t.tap(find.byKey(NightCard.recalcKey));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('night-card-confirm:Recalculate')));
      await t.pumpAndSettle();
      expect(l.calls, ['recalculate']);

      await t.tap(find.byKey(NightCard.notSleepKey));
      await t.pumpAndSettle();
      expect(find.text('Mark this as not sleep?'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('night-card-confirm:Not sleep')));
      await t.pumpAndSettle();
      expect(l.calls, ['recalculate', 'notSleep']);
    });

    testWidgets('the recalculating dot replaces the icon; nothing is disabled', (t) async {
      await card(t, states['auto']!);
      expect(find.byKey(NightCard.iconKey), findsOneWidget);
      expect(find.byKey(NightCard.dotKey), findsNothing);
      final l = await card(t, states['recalculating']!);
      expect(find.byKey(NightCard.dotKey), findsOneWidget);
      expect(find.byKey(NightCard.iconKey), findsNothing);
      expect(find.text('You can keep using the app'), findsOneWidget);
      // Still usable while it runs.
      await t.tap(find.byKey(NightCard.askKey));
      await t.tap(find.byKey(NightCard.chipKey(BlockEnd.end)));
      await t.pump();
      expect(find.byKey(const ValueKey('night-card-wheel:end')), findsOneWidget);
      expect(l.calls, ['timeline']);
    });

    test('every state has a subheading', () {
      for (final m in states.values) {
        expect(nightStatusText(m).sub, isNotEmpty);
      }
      expect(nightStatusText(states['auto']!).sub,
          'Band covered 7h 50m of 8h 06m in bed');
    });
  });

  group('sleep timeline editor', () {
    late List<SleepEditPlan> saved;
    late Completer<void> written;
    late Completer<SleepOperationResult> done;
    Object? popped;

    Future<SleepTimelineEditorState> open(WidgetTester t, {SleepEditorData? data}) async {
      t.view.physicalSize = const Size(412, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      saved = [];
      written = Completer();
      done = Completer();
      popped = null;
      await t.pumpWidget(_app(Builder(builder: (c) => Scaffold(body: TextButton(
          onPressed: () async {
            popped = await Navigator.of(c).push(MaterialPageRoute(
                builder: (_) => SleepTimelineEditor(
                    data: data ?? dtNight(),
                    haptics: _Quiet(),
                    save: _Saver(saved, written, done))));
          },
          child: const Text('open'))))));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      return t.state<SleepTimelineEditorState>(find.byType(SleepTimelineEditor));
    }

    Offset at(WidgetTester t, SleepTimelineEditorState s, double ts) {
      final box = t.getRect(find.byKey(DayTimelineChart.chartKey));
      return Offset(box.left + 44 + s.controller.view.fraction(ts) * (box.width - 52),
          box.top + 120);
    }

    Future<void> dragMainEnd(WidgetTester t, SleepTimelineEditorState s) async {
      final g = await t.startGesture(at(t, s, s.blocks.first.end.toDouble()));
      for (var i = 0; i < 4; i++) {
        await g.moveBy(const Offset(10, 0));
      }
      await g.up();
      await t.pump(const Duration(seconds: 1));
    }

    // WHY: CLAIM(sleep-editor-home). The default is this night's exact window,
    // even after panning; zooming out cannot return to a generic clock range.
    // catches: retaining the pilot's fixed 20:00-to-noon home.
    testWidgets('default, zoom out and reset frame exactly the stored night', (t) async {
      final s = await open(t);
      final main = s.blocks.first;
      final home = TimelineView(main.start.toDouble(), main.end.toDouble());
      expect(s.controller.view, home);
      expect(find.byKey(const ValueKey('sleep-editor-zoom-in')), findsOneWidget);
      expect(find.byKey(const ValueKey('sleep-editor-zoom-out')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('sleep-editor-zoom-in')));
      await t.pumpAndSettle();
      expect(s.controller.view.span, closeTo(home.span * .7, .001));
      s.controller.glideTo(TimelineView(main.start + 1200.0, main.start + 4800.0));
      await t.pumpAndSettle();
      await t.tap(find.byKey(SleepTimelineEditor.resetKey));
      await t.pumpAndSettle();
      expect(s.controller.view, home);
      await t.tap(find.byKey(const ValueKey('sleep-editor-zoom-in')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('sleep-editor-zoom-out')));
      await t.pumpAndSettle();
      expect(s.controller.view, home);
    });

    testWidgets('a single tap selects a band without zooming; Done returns to the main sleep',
        (t) async {
      final s = await open(t);
      expect(s.active, 'main');
      final nap = s.blocks.last;
      // The nap is in the afternoon, past the default 8 PM -> 12 PM view.
      s.controller.glideTo(TimelineView(s.controller.domainStart, s.controller.domainEnd));
      await t.pump();
      await t.pump(const Duration(seconds: 3));
      s.controller.lastGlide = null;
      // The nap's band: a single tap selects it, no zoom.
      await t.tapAt(at(t, s, nap.start + 600.0));
      await t.pump(const Duration(milliseconds: 400));
      expect(s.active, nap.id);
      expect(s.controller.lastGlide, isNull);
      expect(find.text('Adjusting nap: drag its ends'), findsOneWidget);
      // Done goes back to the main sleep.
      await t.tap(find.byKey(const ValueKey('sleep-editor-banner:Done')));
      await t.pump(const Duration(seconds: 3));
      expect(s.active, 'main');
    });

    testWidgets('Add sleep block asks the side, adds an active nap clear of the main sleep',
        (t) async {
      final s = await open(t, data: dtNight(withNap: false));
      await t.tap(find.byKey(SleepTimelineEditor.addKey));
      await t.pump();
      expect(find.text('Before or after the main sleep?'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('sleep-editor-banner:After')));
      await t.pump();
      await t.pump(const Duration(seconds: 3));
      expect(s.blocks, hasLength(2));
      final nap = s.blocks.last;
      expect(nap.kind, BlockKind.nap);
      expect(s.active, nap.id);
      expect(nap.start, greaterThanOrEqualTo(s.blocks.first.end));
      expect(blocksOverlap(s.blocks), isFalse);
      expect(s.controller.view.start, greaterThan(s.controller.home.start),
          reason: 'the view glided to that side');
    });

    // WHY (§3 data safety): "Save writes durably and returns immediately; the
    // night recalculates in the background" and "never locks the UI".
    testWidgets('Save returns at the durable write, not at the recalculation', (t) async {
      final s = await open(t);
      await dragMainEnd(t, s);
      final edited = s.blocks.first;
      await t.tap(find.byKey(SleepTimelineEditor.saveKey));
      await t.pump();
      expect(saved.single.window, (edited.start, edited.end));
      // Not written yet: still on screen, still usable.
      expect(find.byType(SleepTimelineEditor), findsOneWidget);
      await t.tap(find.byKey(SleepTimelineEditor.addKey));
      await t.pump();
      expect(find.text('Before or after the main sleep?'), findsOneWidget);
      written.complete();
      await t.pumpAndSettle();
      // Gone at the write, with the recalculation still running.
      expect(find.byType(SleepTimelineEditor), findsNothing);
      expect(popped, isA<SleepEditorResult>());
      expect(done.isCompleted, isFalse);
    });

    testWidgets('a write that fails keeps the edits on screen', (t) async {
      final s = await open(t);
      await dragMainEnd(t, s);
      await t.tap(find.byKey(SleepTimelineEditor.saveKey));
      await t.pump();
      written.completeError(const SleepEditInvalid('Sleep blocks cannot overlap.'));
      done.complete(const SleepOperationResult(success: false));
      await t.pumpAndSettle();
      expect(find.byType(SleepTimelineEditor), findsOneWidget);
      expect(find.byKey(const ValueKey('sleep-editor-save-error')), findsOneWidget);
    });

    testWidgets('Cancel writes nothing', (t) async {
      final s = await open(t);
      await dragMainEnd(t, s);
      expect(s.blocks.first, isNot(dtNight().main));
      await t.tap(find.byKey(SleepTimelineEditor.cancelKey));
      await t.pumpAndSettle();
      expect(find.byType(SleepTimelineEditor), findsNothing);
      expect(saved, isEmpty);
      expect(popped, isNull);
    });

    testWidgets('the stage wave and totals are labelled PREVIEW and update while dragging',
        (t) async {
      final s = await open(t);
      expect(find.byKey(const ValueKey('preview-label')), findsOneWidget);
      final before = s.stages.where((x) => x != null).length;
      await dragMainEnd(t, s);
      expect(s.stages.where((x) => x != null).length, isNot(before));
      expect(s.lastStageMicros, lessThan(16000));
    });

    test('the plan holds only what moved', () {
      final d = dtNight();
      final nap = d.naps.single;
      expect(planOf(d, [d.main, nap]).isEmpty, isTrue);
      final moved = planOf(d, [d.main.copyWith(end: d.main.end + 600), nap]);
      expect(moved.window, (d.main.start, d.main.end + 600));
      expect(moved.naps, isEmpty);
      final p = planOf(d, [d.main, nap.copyWith(start: nap.start - 300),
        SleepBlock('new:0', BlockKind.nap, dtAt(1200), dtAt(1260))]);
      expect(p.window, isNull);
      expect([for (final n in p.naps) (n.start, n.fromStart)],
          [(nap.start - 300, nap.start), (dtAt(1200), null)]);
    });
  });
}
