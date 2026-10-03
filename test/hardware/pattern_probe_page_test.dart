// 8Y: the pattern probe page, the transcriber the wearer taps. A header with
// the test and Play, the A / B renditions, a wheel of entries with the cursor
// in the middle, and a footer of 1-4 length buttons that stays on screen.
// Fake async time: the probe's real waits are pumped, not slept.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/ui2/profile/pattern_probe_page.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

HardwareProbeRunner _runner(
  DeviceLabLog lab, {
  List<List<int>>? sent,
  Completer<void>? holdPattern,
}) => HardwareProbeRunner(
  lab: lab,
  sendBuzz: (onReply) async {
    onReply('pending', 40);
    return true;
  },
  sendPattern: (effects, loop, onReply) async {
    sent?.add(List.of(effects));
    await holdPattern?.future;
    onReply('pending', 40);
    return true;
  },
  isConnected: () => true,
  ecgSupported: () => true,
  ecgBusy: () => false,
  beginEcg: () async => false,
  endEcg: () async {},
  isEcgAlive: () => false,
);

const _tall = Size(390, 844);

Future<HardwareProbeRunner> _open(
  WidgetTester t,
  DeviceLabLog lab, {
  Size size = _tall,
  List<List<int>>? sent,
  Completer<void>? holdPattern,
}) async {
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final r = _runner(lab, sent: sent, holdPattern: holdPattern);
  await r.openPattern();
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: PatternProbePage(runner: r),
    ),
  );
  await t.pump(const Duration(milliseconds: 300));
  return r;
}

Future<void> _tapKey(WidgetTester t, String key) async {
  await t.tap(find.byKey(ValueKey(key)));
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('shows the test, Play, the renditions, the hint and the footer', (
    t,
  ) async {
    final r = await _open(t, DeviceLabLog());
    expect(find.text('Test 1 of 40'), findsOneWidget);
    expect(
      find.textContaining('band pair 47+152, 2 commands 1.8 s apart'),
      findsWidgets,
    );
    expect(find.text('Played 0×'), findsOneWidget);
    for (final k in [
      'pattern-prev',
      'pattern-next',
      'pattern-play',
      'pattern-rendition-a',
      'pattern-rendition-b',
      'pattern-wheel',
      'pattern-len-1',
      'pattern-len-2',
      'pattern-len-3',
      'pattern-len-4',
      'pattern-delete',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(
      find.text(
        'Buzzes and gaps alternate; the first entry is a buzz. Scroll to an '
        'entry to change it.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Each play waits for the band to finish the last one; at most 160 '
        'commands per session; leaving this screen stops it.',
      ),
      findsOneWidget,
    );
    expect(find.text('Gap'), findsNothing, reason: 'the first entry is a buzz');
    r.closePattern();
  });

  testWidgets('length buttons append alternating Buzz and Gap entries', (
    t,
  ) async {
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-len-2');
    await _tapKey(t, 'pattern-len-1');
    await _tapKey(t, 'pattern-len-4');
    expect(r.pattern!.rendition(0, 0).lengths, [2, 1, 4]);
    expect(r.pattern!.cursor, 3);
    expect(find.text('Buzz'), findsWidgets);
    expect(find.text('Gap'), findsWidgets);
    // Delete at the empty slot removes the last entry.
    await _tapKey(t, 'pattern-delete');
    expect(r.pattern!.rendition(0, 0).lengths, [2, 1]);
    r.closePattern();
  });

  testWidgets('the footer stays on screen when the list is long', (t) async {
    final r = await _open(t, DeviceLabLog(), size: const Size(360, 640));
    for (var i = 0; i < 24; i++) {
      r.patternTap(1 + i % 4);
    }
    await t.pump(const Duration(milliseconds: 600));
    expect(r.pattern!.rendition(0, 0).lengths, hasLength(24));
    final screen = Offset.zero & const Size(360, 640);
    for (final k in [
      'pattern-len-1',
      'pattern-len-2',
      'pattern-len-3',
      'pattern-len-4',
      'pattern-delete',
    ]) {
      final f = find.byKey(ValueKey(k));
      expect(f.hitTestable(), findsOneWidget, reason: '$k can be tapped');
      final rect = t.getRect(f);
      expect(
        screen.contains(rect.topLeft) && screen.contains(rect.bottomRight),
        isTrue,
        reason: '$k is fully on screen: $rect',
      );
    }
    // The wheel is still there and the footer still works.
    expect(find.byKey(const ValueKey('pattern-wheel')), findsOneWidget);
    await _tapKey(t, 'pattern-delete');
    expect(r.pattern!.rendition(0, 0).lengths, hasLength(23));
    r.closePattern();
  });

  testWidgets('scrolling the wheel moves the cursor; a length then replaces '
      'that entry', (t) async {
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-len-1');
    await _tapKey(t, 'pattern-len-2');
    await _tapKey(t, 'pattern-len-3');
    final s = r.pattern!;
    expect(s.cursor, 3, reason: 'on the empty next slot');

    final wheel = find.byKey(const ValueKey('pattern-wheel'));
    await t.drag(wheel, const Offset(0, 300));
    await t.pumpAndSettle();
    final c = s.cursor;
    expect(
      c,
      lessThan(3),
      reason: 'dragging down goes back to earlier entries',
    );

    await _tapKey(t, 'pattern-len-4');
    final lengths = s.rendition(0, 0).lengths;
    expect(lengths, hasLength(3), reason: 'replaced, not appended');
    expect(lengths[c], 4);
    expect(
      [
        for (var i = 0; i < 3; i++)
          if (i != c) lengths[i],
      ],
      [
        for (var i = 0; i < 3; i++)
          if (i != c) [1, 2, 3][i],
      ],
      reason: 'the other entries are untouched',
    );

    await t.drag(wheel, const Offset(0, -600));
    await t.pumpAndSettle();
    expect(s.cursor, 3, reason: 'dragging up reaches the next slot again');
    r.closePattern();
  });

  testWidgets('the rendition switch keeps A and B apart', (t) async {
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-len-1');
    await _tapKey(t, 'pattern-rendition-b');
    expect(r.pattern!.activeRendition, 1);
    await _tapKey(t, 'pattern-len-3');
    await _tapKey(t, 'pattern-len-2');
    expect(r.pattern!.rendition(0, 1).lengths, [3, 2]);
    expect(r.pattern!.rendition(0, 0).lengths, [1]);
    await _tapKey(t, 'pattern-rendition-a');
    expect(r.pattern!.activeRendition, 0);
    r.closePattern();
  });

  testWidgets('previous and next move between the tests', (t) async {
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-next');
    expect(r.pattern!.testIndex, 1);
    expect(find.text('Test 2 of 40'), findsOneWidget);
    expect(
      find.textContaining('effect 47 alone, 2 commands 1.8 s apart'),
      findsWidgets,
    );
    await _tapKey(t, 'pattern-prev');
    expect(r.pattern!.testIndex, 0);
    expect(find.text('Test 1 of 40'), findsOneWidget);
    r.closePattern();
  });

  testWidgets('the gap tests are at the end and say how long they wait', (
    t,
  ) async {
    final r = await _open(t, DeviceLabLog());
    r.patternTest(34);
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Test 35 of 40'), findsOneWidget);
    expect(
      find.textContaining(
        'effect 14, 2 commands, the second 300 ms after the first ends',
      ),
      findsWidgets,
    );
    r.closePattern();
  });

  /// The label each length button shows now.
  List<String> footerLabels(WidgetTester t) => [
    for (var n = 1; n <= 4; n++)
      t
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(ValueKey('pattern-len-$n')),
              matching: find.byType(Text),
            ),
          )
          .map((w) => w.data)
          .whereType<String>()
          .join(' '),
  ];

  testWidgets('the length buttons read Buzz or Gap for the entry they '
      'write', (t) async {
    final r = await _open(t, DeviceLabLog());
    final buzz = ['Buzz 1', 'Buzz 2', 'Buzz 3', 'Buzz 4'];
    final gap = ['Gap 1', 'Gap 2', 'Gap 3', 'Gap 4'];
    expect(footerLabels(t), buzz, reason: 'the first entry is a buzz');
    await _tapKey(t, 'pattern-len-2');
    expect(footerLabels(t), gap, reason: 'the next entry is a gap');
    await _tapKey(t, 'pattern-len-1');
    expect(footerLabels(t), buzz);
    await _tapKey(t, 'pattern-len-3');
    expect(footerLabels(t), gap);

    // Moving the wheel to an entry switches the buttons to that entry's kind.
    final wheel = find.byKey(const ValueKey('pattern-wheel'));
    await t.drag(wheel, const Offset(0, 300));
    await t.pumpAndSettle();
    final c = r.pattern!.cursor;
    expect(c, lessThan(3));
    expect(footerLabels(t), c.isEven ? buzz : gap, reason: 'cursor at $c');
    // Replacing keeps the kind of the entry it replaced, then moves on.
    await _tapKey(t, 'pattern-len-4');
    expect(r.pattern!.cursor, c + 1);
    expect(footerLabels(t), (c + 1).isEven ? buzz : gap);
    r.closePattern();
  });

  testWidgets('Play buzzes the band, is disabled while playing, and counts', (
    t,
  ) async {
    final hold = Completer<void>();
    final sent = <List<int>>[];
    final r = await _open(t, DeviceLabLog(), sent: sent, holdPattern: hold);
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    await t.pump(const Duration(milliseconds: 300));
    expect(r.patternPlaying, isTrue);
    expect(sent, hasLength(1));
    expect(find.text('Playing…'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    await t.pump(const Duration(milliseconds: 300));
    expect(sent, hasLength(1), reason: 'a second tap does nothing');

    hold.complete();
    await t.pump(const Duration(seconds: 20));
    expect(r.patternPlaying, isFalse);
    expect(find.text('Playing…'), findsNothing);
    expect(find.text('Played 1×'), findsOneWidget);
    r.closePattern();
    await t.pump();
  });

  testWidgets('leaving the page closes the session and logs what was heard', (
    t,
  ) async {
    final lab = DeviceLabLog();
    final r = await _open(t, lab);
    await _tapKey(t, 'pattern-len-2');
    await _tapKey(t, 'pattern-len-2');
    await _tapKey(t, 'pattern-len-2');
    expect(r.running, ProbeKind.pattern);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    expect(r.running, isNull);
    expect(r.pattern, isNull);
    expect(lab.steps.join('\n'), contains('Pattern probe heard 1/40'));
    expect(
      lab.sessionSummaries.single,
      contains('1 of 40 tests transcribed, 0 plays'),
    );
  });
}
