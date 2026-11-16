// Pilot day-timeline, spec Tests §1-§2 through the widget: the chart turns
// the finger into the rules of timeline_model.dart. A small host plays the
// screen's part (it keeps the blocks and the active block).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_chart.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_model.dart';
import 'package:openstrap_edge/ui2/theme.dart';

// A night from 20:00 (t0) for 24 hours, as epoch seconds of a fixed instant.
final t0 = DateTime(2026, 11, 13, 20).millisecondsSinceEpoch ~/ 1000;
const width = 404.0; // plot = 404 - 44 - 8 = 352 px

class _Haptics implements TimelineHaptics {
  final ticks = <HapticTier>[];
  int fine = 0;
  @override
  void tick(HapticTier tier) => ticks.add(tier);
  @override
  void fineMode() => fine++;
}

class _Host extends StatefulWidget {
  const _Host(this.controller, this.haptics, {this.blocks = const []});
  final TimelineController controller;
  final _Haptics haptics;
  final List<SleepBlock> blocks;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> implements TimelineListener {
  late List<SleepBlock> blocks = widget.blocks;
  String? active = 'main';
  final selected = <(String, bool)>[];
  @override
  void blocksChanged(List<SleepBlock> b) => setState(() => blocks = b);
  @override
  void blockSelected(String id, {required bool zoom}) {
    selected.add((id, zoom));
    setState(() => active = id);
  }
  @override
  void scrubbed(double t) {}
  @override
  void dragEnded() {}
  @override
  Widget build(BuildContext context) => MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: DayTimelineChart(
                controller: widget.controller,
                hr: List.filled(1440, 60.0),
                movement: List.filled(1440, .1),
                stages: List.filled(288, null),
                blocks: blocks,
                activeBlock: blocks.isEmpty ? null : active,
                listener: this,
                haptics: widget.haptics,
              ),
            ),
          ),
        ),
      );
}

void main() {
  late TimelineController c;
  late _Haptics h;
  const main = 'main';
  // Main sleep 23:00-07:00, a nap 13:30-14:30 (both inside the 24 h domain).
  final mainBlock = SleepBlock(main, BlockKind.main, t0 + 3 * 3600, t0 + 11 * 3600);
  final napBlock = SleepBlock('nap', BlockKind.nap, t0 + 17 * 3600 + 1800, t0 + 18 * 3600 + 1800);

  setUp(() {
    h = _Haptics();
    c = TimelineController(
        domainStart: t0.toDouble(),
        domainEnd: (t0 + 86400).toDouble(),
        home: TimelineView(t0.toDouble(), (t0 + 86400).toDouble()));
  });

  Future<_HostState> pump(WidgetTester tester, {List<SleepBlock>? blocks}) async {
    tester.view.physicalSize = const Size(width, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_Host(c, h, blocks: blocks ?? const []));
    return tester.state<_HostState>(find.byType(_Host));
  }

  Offset at(WidgetTester tester, double t, {double dy = 120}) {
    final box = tester.getTopLeft(find.byKey(DayTimelineChart.chartKey));
    return box + Offset(44 + c.view.fraction(t) * 352, dy);
  }

  testWidgets('the scrub persists after release', (tester) async {
    await pump(tester);
    final g = await tester.startGesture(at(tester, t0 + 3600.0 * 5));
    await g.moveBy(const Offset(40, 0));
    await g.moveBy(const Offset(40, 0));
    await tester.pump();
    final during = c.scrub!;
    await g.up();
    await tester.pump(const Duration(seconds: 2));
    expect(c.scrub, during, reason: 'released, the line stays where it was');
    expect(during, closeTo(t0 + 3600.0 * 5 + 80 * 86400 / 352, 300));
  });

  testWidgets('single tap selects; double tap selects with the same zoom as the day view',
      (tester) async {
    final host = await pump(tester, blocks: [mainBlock, napBlock]);
    await tester.tapAt(at(tester, napBlock.start + 900.0));
    await tester.pump(const Duration(milliseconds: 400)); // past the double-tap window
    expect(host.selected, [('nap', false)]);
    expect(host.active, 'nap');
    expect(c.lastGlide, isNull, reason: 'a single tap does not zoom');

    await tester.tapAt(at(tester, mainBlock.start + 3600.0));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(at(tester, mainBlock.start + 3600.0));
    await tester.pump();
    expect(host.selected.last, (main, true));
    expect(host.active, main);
    expect(c.lastGlide!.inMilliseconds, inInclusiveRange(1500, 2000));
    await tester.pump(c.lastGlide! + const Duration(milliseconds: 50));
    // Round 2: block selection must not substitute block-framing zoom.
    // 24 h × .7, centred on the tapped 00:00 instant, clamped at 20:00.
    final want = TimelineView(t0.toDouble(), t0 + 86400 * .7);
    expect(c.view.start, closeTo(want.start, 1));
    expect(c.view.end, closeTo(want.end, 1));
  });

  testWidgets('double tap on empty space zooms in 30% around the tap, gliding', (tester) async {
    await pump(tester);
    final t = t0 + 6 * 3600.0;
    await tester.tapAt(at(tester, t));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(at(tester, t));
    await tester.pump();
    expect(c.animating, isTrue);
    await tester.pump(const Duration(milliseconds: 750));
    expect(c.view.span, inExclusiveRange(86400 * .7, 86400), reason: 'mid-glide');
    await tester.pump(const Duration(seconds: 2));
    expect(c.view.span, closeTo(86400 * .7, 1));
    // The day edge shifts the window, but the scale is the asked one.
    expect(c.view.start, t0);
    expect(c.zoomed, isTrue);
    c.reset();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(c.view, c.home);
  });

  testWidgets('only the active block has handles', (tester) async {
    final host = await pump(tester, blocks: [mainBlock, napBlock]);
    // Dragging the nap's (inactive) edge scrubs; it never moves the nap.
    final g = await tester.startGesture(at(tester, napBlock.end.toDouble()));
    await g.moveBy(const Offset(-30, 0));
    await tester.pump();
    expect(find.byKey(DayTimelineChart.magnifierKey), findsNothing);
    await g.up();
    expect(host.blocks.last, napBlock);
    expect(c.scrub, isNotNull);
    // The active (main) block's end has a handle: the magnifier opens.
    final g2 = await tester.startGesture(at(tester, mainBlock.end.toDouble()));
    await g2.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(find.byKey(DayTimelineChart.magnifierKey), findsOneWidget);
    await g2.up();
    await tester.pump();
    expect(find.byKey(DayTimelineChart.magnifierKey), findsNothing);
    expect(host.blocks.first.end, isNot(mainBlock.end));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a dragged end stops at the neighbouring block', (tester) async {
    final host = await pump(tester, blocks: [mainBlock, napBlock]);
    final g = await tester.startGesture(at(tester, mainBlock.end.toDouble()));
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(20, 0));
    }
    await tester.pump();
    await g.up();
    expect(host.blocks.first.end, napBlock.start);
    expect(blocksOverlap(host.blocks), isFalse);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the magnifier switches to 1-minute steps after a hold; haptic tiers',
      (tester) async {
    final host = await pump(tester, blocks: [mainBlock]);
    final g = await tester.startGesture(at(tester, mainBlock.end.toDouble()));
    await g.moveBy(const Offset(24, 0));
    await tester.pump();
    expect(find.text('5-minute steps. Hold for single minutes.'), findsOneWidget);
    expect(host.blocks.single.end % 300, 0);
    await tester.pump(const Duration(milliseconds: 650)); // held still
    expect(find.text('1-minute steps'), findsOneWidget);
    expect(h.fine, 1);
    final before = host.blocks.single.end;
    h.ticks.clear();
    // 4 px at 245 s/px is 980 s of finger, a quarter is ~4 minutes.
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(1, 0));
      await tester.pump();
    }
    final moved = host.blocks.single.end - before;
    expect(moved % 60, 0);
    expect(moved, inInclusiveRange(180, 300));
    // One tick per minute value landed on, by its tier.
    expect(h.ticks, isNotEmpty);
    final local = DateTime.fromMillisecondsSinceEpoch(host.blocks.single.end * 1000);
    expect(h.ticks.last, hapticTier(local.hour * 60 + local.minute));
    await g.up();
    await tester.pump(const Duration(seconds: 1));
  });
}
