// 8Y/8Z: the pattern probe page, the transcriber the wearer taps. A header with
// the test, Play, a metronome dot and the A / B renditions, a wheel of note and
// rest entries with the cursor in the middle, and a footer (Note/Rest toggle,
// Delete, 1-4 length buttons) that stays on screen. Fake async time: the
// probe's real waits are pumped, not slept.
//
// Contracts these tests rely on that the spec leaves open:
//  - `pattern-metronome` is on the Semantics node labelled "metronome step N of
//    8" (N 1..8, step 1 = A); the dot is a DecoratedBox below it whose
//    BoxDecoration.color is a solid colour on odd steps and null/transparent
//    on even steps. The colour does not animate.
//  - `pattern-dynamic-tempo` is a Switch, or holds one.
//  - note/rest symbols (8Z, F): inside each length button and wheel row there
//    is one widget keyed `pattern-symbol` (a CustomPaint at its root) with a
//    Semantics label such as "quarter note" or "dotted quarter rest" (the row
//    label is swallowed by the row's own Semantics, so only the buttons are
//    read); the dashes are keyed `dash-1`..`dash-N` (one per unit) and hold a
//    DecoratedBox whose BoxDecoration.color is the dash colour.
//  - `pattern-kind` shows the text "Note" or "Rest".
//  - the march (8Z, G): the playhead is the widget keyed `pattern-playhead` on
//    the playing wheel row; the row's Semantics label says "playing entry N".
//    The march runs on timers from the first write's real landing time
//    (DateTime.now) plus the lead, so these tests sample the middle of each
//    entry's window rather than its edges.

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
      'pattern-kind',
      'pattern-delete',
      'pattern-metronome',
      'pattern-dynamic-tempo',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(find.textContaining('Pick Note or Rest, then a length.'), findsOneWidget);
    expect(
      find.textContaining('Scroll to an entry to change it.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Each play waits for the band to finish the last one; at most 160 '
        'commands per session; leaving this screen stops it.',
      ),
      findsOneWidget,
    );
    expect(find.text('Rest'), findsNothing, reason: 'the first entry is a note');
    expect(find.text('Gap'), findsNothing);
    expect(find.text('Buzz'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('pattern-kind')),
        matching: find.text('Note'),
      ),
      findsOneWidget,
    );
    expect(find.text('1 = 250 ms'), findsOneWidget);
    expect(find.text('Dynamic tempo'), findsOneWidget);
    r.closePattern();
  });

  testWidgets('length buttons append notes and rests, flipping the toggle', (
    t,
  ) async {
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-len-2');
    await _tapKey(t, 'pattern-len-1');
    await _tapKey(t, 'pattern-len-4');
    // Nothing repeats yet, the toggle alternates: note, rest, note.
    expect(r.pattern!.rendition(0, 0).code, 'N2 R1 N4');
    expect(r.pattern!.cursor, 3);
    expect(find.text('Note'), findsWidgets);
    expect(find.text('Rest'), findsWidgets);
    expect(find.text('Buzz'), findsNothing);
    expect(find.text('Gap'), findsNothing);
    // Delete at the empty slot removes the last entry.
    await _tapKey(t, 'pattern-delete');
    expect(r.pattern!.rendition(0, 0).code, 'N2 R1');
    r.closePattern();
  });

  testWidgets('the footer stays on screen when the list is long', (t) async {
    final r = await _open(t, DeviceLabLog(), size: const Size(360, 640));
    for (var i = 0; i < 32; i++) {
      r.patternTap(1 + i % 4);
    }
    await t.pump(const Duration(milliseconds: 600));
    expect(r.pattern!.rendition(0, 0).code.split(' '), hasLength(32));
    final screen = Offset.zero & const Size(360, 640);
    for (final k in [
      'pattern-len-1',
      'pattern-len-2',
      'pattern-len-3',
      'pattern-len-4',
      'pattern-kind',
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
    expect(r.pattern!.rendition(0, 0).code.split(' '), hasLength(31));
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
    expect(s.active.code, 'N1 R2 N3');

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
    final entries = s.rendition(0, 0).code.split(' ');
    expect(entries, hasLength(3), reason: 'replaced, not appended');
    expect(entries[c].substring(1), '4');
    expect(
      [
        for (var i = 0; i < 3; i++)
          if (i != c) entries[i],
      ],
      [
        for (var i = 0; i < 3; i++)
          if (i != c) ['N1', 'R2', 'N3'][i],
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
    expect(r.pattern!.rendition(0, 1).code, 'N3 R2');
    expect(r.pattern!.rendition(0, 0).code, 'N1');
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

  /// The text the Note/Rest toggle shows.
  String kindText(WidgetTester t) => t
      .widgetList<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('pattern-kind')),
          matching: find.byType(Text),
        ),
      )
      .map((w) => w.data)
      .whereType<String>()
      .join(' ');

  final note = ['Note 1', 'Note 2', 'Note 3', 'Note 4'];
  final rest = ['Rest 1', 'Rest 2', 'Rest 3', 'Rest 4'];

  testWidgets('the toggle flips after every tap and the labels follow', (
    t,
  ) async {
    final r = await _open(t, DeviceLabLog());
    expect(footerLabels(t), note, reason: 'the first entry is a note');
    expect(kindText(t), 'Note');
    await _tapKey(t, 'pattern-len-2');
    expect(footerLabels(t), rest, reason: 'after N1 the toggle shows Rest');
    expect(kindText(t), 'Rest');
    await _tapKey(t, 'pattern-len-1');
    expect(footerLabels(t), note);
    expect(kindText(t), 'Note');
    await _tapKey(t, 'pattern-len-3');
    expect(footerLabels(t), rest);
    expect(r.pattern!.nextIsNote, isFalse);
    expect(r.pattern!.active.code, 'N2 R1 N3');
    r.closePattern();
  });

  testWidgets('a repeating pattern does not change the toggle: it alternates '
      'whatever the lengths', (t) async {
    final r = await _open(t, DeviceLabLog());
    for (final n in [1, 1, 1, 1, 1]) {
      await _tapKey(t, 'pattern-len-$n');
    }
    expect(r.pattern!.active.code, 'N1 R1 N1 R1 N1');
    expect(kindText(t), 'Rest');
    r.closePattern();
  });

  testWidgets('the toggle sits left of Delete, below the length buttons', (
    t,
  ) async {
    final r = await _open(t, DeviceLabLog());
    final kind = t.getRect(find.byKey(const ValueKey('pattern-kind')));
    final del = t.getRect(find.byKey(const ValueKey('pattern-delete')));
    expect(kind.right, lessThanOrEqualTo(del.left), reason: '$kind $del');
    expect((kind.center.dy - del.center.dy).abs(), lessThan(8));
    final len1 = t.getRect(find.byKey(const ValueKey('pattern-len-1')));
    expect(len1.bottom, lessThanOrEqualTo(kind.top));
    r.closePattern();
  });

  testWidgets('overriding the toggle gives two rests in a row', (t) async {
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-len-1'); // N1, then the toggle says Rest
    await _tapKey(t, 'pattern-len-2'); // R2, then the toggle says Note
    expect(footerLabels(t), note);
    await _tapKey(t, 'pattern-kind');
    expect(footerLabels(t), rest);
    expect(kindText(t), 'Rest');
    expect(r.pattern!.nextIsNote, isFalse);
    await _tapKey(t, 'pattern-len-3'); // a second rest
    expect(r.pattern!.active.code, 'N1 R2 R3');
    expect(kindText(t), 'Note', reason: 'it alternates again after the tap');
    expect(footerLabels(t), note);
    r.closePattern();
  });

  testWidgets('overriding the toggle gives two notes in a row', (t) async {
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-len-1'); // N1, then the toggle says Rest
    expect(kindText(t), 'Rest');
    await _tapKey(t, 'pattern-kind'); // back to Note
    expect(footerLabels(t), note);
    await _tapKey(t, 'pattern-len-2');
    expect(r.pattern!.active.code, 'N1 N2');
    await _tapKey(t, 'pattern-kind');
    await _tapKey(t, 'pattern-kind');
    expect(kindText(t), 'Rest', reason: 'two flips cancel out');
    r.closePattern();
  });

  testWidgets('the footer has no suggested-length mark', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    for (final n in [1, 1, 1, 1]) {
      await _tapKey(t, 'pattern-len-$n');
    }
    for (var n = 1; n <= 4; n++) {
      expect(
        t.getSemantics(find.byKey(ValueKey('pattern-len-$n'))).label,
        isNot(contains('suggested')),
      );
    }
    r.closePattern();
    h.dispose();
  });

  testWidgets('moving the cursor sets the toggle opposite the entry before '
      'it', (t) async {
    final r = await _open(t, DeviceLabLog());
    for (final n in [1, 2, 3]) {
      await _tapKey(t, 'pattern-len-$n');
    }
    expect(r.pattern!.active.code, 'N1 R2 N3');
    final wheel = find.byKey(const ValueKey('pattern-wheel'));
    await t.drag(wheel, const Offset(0, 300));
    await t.pumpAndSettle();
    final c = r.pattern!.cursor;
    expect(c, lessThan(3));
    final before = c == 0 ? null : ['N', 'R', 'N'][c - 1];
    expect(
      kindText(t),
      before == 'N' ? 'Rest' : 'Note',
      reason: 'cursor at $c, entry before it $before',
    );
    r.closePattern();
  });

  /// The first DecoratedBox colour at or under [f].
  Color? colourOf(WidgetTester t, Finder f) => (t
          .widget<DecoratedBox>(
            find
                .descendant(
                  of: f,
                  matching: find.byType(DecoratedBox),
                  matchRoot: true,
                )
                .first,
          )
          .decoration as BoxDecoration)
      .color;

  /// The four metronome colours A, C, D, E, read off steps 1, 3, 5, 7 of the
  /// dot; the dashes must use these same colours.
  Future<List<Color>> metronomeColours(WidgetTester t) async {
    final key = find.byKey(const ValueKey('pattern-metronome'));
    final byStep = <int, Color>{};
    for (var i = 0; i < 20 && byStep.length < 4; i++) {
      final m = RegExp(r'metronome step (\d) of 8')
          .firstMatch(t.getSemantics(key).label);
      final step = int.parse(m!.group(1)!);
      final c = colourOf(t, key);
      if (step.isOdd && c != null && c.a > 0) byStep[step] = c;
      await t.pump(const Duration(milliseconds: 125));
    }
    expect(byStep.keys.toSet(), {1, 3, 5, 7});
    return [byStep[1]!, byStep[3]!, byStep[5]!, byStep[7]!];
  }

  testWidgets('each length button shows a music symbol: eighth, quarter, '
      'dotted quarter, half', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    const names = ['eighth', 'quarter', 'dotted quarter', 'half'];
    Future<void> check(String kind) async {
      for (var n = 1; n <= 4; n++) {
        final sym = find.descendant(
          of: find.byKey(ValueKey('pattern-len-$n')),
          matching: find.byKey(const ValueKey('pattern-symbol')),
        );
        expect(sym, findsOneWidget, reason: '$kind $n');
        expect(
          find.descendant(
            of: sym,
            matching: find.byType(CustomPaint),
            matchRoot: true,
          ),
          findsWidgets,
          reason: 'drawn, not a font glyph',
        );
        expect(
          t.getSemantics(sym).label,
          contains('${names[n - 1]} $kind'),
        );
      }
    }

    await check('note');
    await _tapKey(t, 'pattern-len-1');
    await check('rest');
    r.closePattern();
    h.dispose();
  });

  testWidgets('dashes use the metronome colours in order; rests are the same '
      'colours at one third of the saturation', (t) async {
    final r = await _open(t, DeviceLabLog());
    final c = await metronomeColours(t);
    expect(c.toSet(), hasLength(4));

    Finder dash(int n, int k) => find.descendant(
      of: find.byKey(ValueKey('pattern-len-$n')),
      matching: find.byKey(ValueKey('dash-$k')),
    );

    void check(bool note) {
      for (var n = 1; n <= 4; n++) {
        for (var k = 1; k <= n; k++) {
          expect(dash(n, k), findsOneWidget, reason: 'button $n dash $k');
          final got = colourOf(t, dash(n, k))!;
          final base = HSLColor.fromColor(c[k - 1]);
          final hsl = HSLColor.fromColor(got);
          if (note) {
            expect(got.toARGB32(), c[k - 1].toARGB32(), reason: 'note $n/$k');
          } else {
            expect(hsl.saturation, closeTo(base.saturation / 3, 0.03));
            expect(hsl.hue, closeTo(base.hue, 2));
            expect(hsl.lightness, closeTo(base.lightness, 0.03));
          }
        }
        expect(dash(n, n + 1), findsNothing, reason: 'one dash per unit');
      }
    }

    check(true);
    await _tapKey(t, 'pattern-len-2'); // N2; the buttons now write rests
    check(false);
    r.closePattern();
  });

  testWidgets('wheel rows carry the same symbols and dash colours', (t) async {
    final r = await _open(t, DeviceLabLog());
    final c = await metronomeColours(t);
    await _tapKey(t, 'pattern-len-2'); // N2
    await _tapKey(t, 'pattern-len-3'); // R3
    expect(r.pattern!.active.code, 'N2 R3');
    final wheel = find.byKey(const ValueKey('pattern-wheel'));
    expect(
      find.descendant(
        of: wheel,
        matching: find.byKey(const ValueKey('pattern-symbol')),
      ),
      findsAtLeastNWidgets(2),
    );
    Iterable<Color> dashes(int k) => [
      for (final e in find
          .descendant(of: wheel, matching: find.byKey(ValueKey('dash-$k')))
          .evaluate())
        colourOf(t, find.byElementPredicate((x) => x == e))!,
    ];
    // The note row (N2) has dashes 1 and 2 at full colour, the rest row (R3)
    // has dashes 1 to 3 at a third of the saturation.
    final full = c.map((x) => x.toARGB32()).toList();
    expect(dashes(2).map((x) => x.toARGB32()), contains(full[1]));
    for (var k = 1; k <= 3; k++) {
      final base = HSLColor.fromColor(c[k - 1]);
      expect(
        dashes(k).any(
          (x) =>
              (HSLColor.fromColor(x).saturation - base.saturation / 3).abs() <
              0.03,
        ),
        isTrue,
        reason: 'a rest dash $k at one third saturation',
      );
    }
    expect(dashes(3).map((x) => x.toARGB32()), contains(isNot(full[2])));
    r.closePattern();
  });

  testWidgets('the metronome steps every 250 ms through four colours with off '
      'between', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    final key = find.byKey(const ValueKey('pattern-metronome'));
    ({int step, Color? color}) dot() {
      final label = t.getSemantics(key).label;
      final m = RegExp(r'metronome step (\d) of 8').firstMatch(label);
      expect(m, isNotNull, reason: 'label: $label');
      final box = t.widget<DecoratedBox>(
        find.descendant(of: key, matching: find.byType(DecoratedBox)).first,
      );
      final c = (box.decoration as BoxDecoration).color;
      return (
        step: int.parse(m!.group(1)!),
        color: c == null || c.a == 0 ? null : c,
      );
    }

    await t.pump(const Duration(milliseconds: 10));
    var prev = dot().step;
    final colours = <Color>{};
    for (var i = 0; i < 17; i++) {
      await t.pump(const Duration(milliseconds: 250));
      final d = dot();
      expect(d.step, prev % 8 + 1, reason: 'one step per 250 ms, in a loop');
      if (d.step.isOdd) {
        expect(d.color, isNotNull, reason: 'step ${d.step} is coloured');
        colours.add(d.color!);
      } else {
        expect(d.color, isNull, reason: 'step ${d.step} is off');
      }
      prev = d.step;
    }
    expect(colours, hasLength(4), reason: 'A, C, D and E are four colours');
    r.closePattern();
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    h.dispose();
  });

  testWidgets('Play restarts the metronome at step 1', (t) async {
    final h = t.ensureSemantics();
    final hold = Completer<void>();
    final r = await _open(t, DeviceLabLog(), holdPattern: hold);
    final key = find.byKey(const ValueKey('pattern-metronome'));
    String label() => t.getSemantics(key).label;
    await t.pump(const Duration(milliseconds: 900));
    expect(label(), isNot('metronome step 1 of 8'), reason: 'mid-bar');
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    await t.pump(const Duration(milliseconds: 10));
    await t.pump(const Duration(milliseconds: 10));
    expect(r.patternPlaying, isTrue);
    expect(label(), 'metronome step 1 of 8');
    await t.pump(const Duration(milliseconds: 250));
    expect(label(), 'metronome step 2 of 8');
    await t.pump(const Duration(milliseconds: 250));
    expect(label(), 'metronome step 3 of 8');
    hold.complete();
    await t.pump(const Duration(seconds: 20));
    r.closePattern();
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    h.dispose();
  });

  testWidgets('the metronome sits next to Play', (t) async {
    final r = await _open(t, DeviceLabLog());
    final dot = t.getRect(find.byKey(const ValueKey('pattern-metronome')));
    final play = t.getRect(find.byKey(const ValueKey('pattern-play')));
    expect((dot.center - play.center).distance, lessThan(200));
    expect((Offset.zero & _tall).contains(dot.topLeft), isTrue);
    expect((Offset.zero & _tall).contains(dot.bottomRight), isTrue);
    expect(dot.width, lessThanOrEqualTo(24));
    r.closePattern();
  });

  testWidgets('Dynamic tempo is on by default, shows 1 = 250 ms, and the '
      'switch turns it off', (t) async {
    final r = await _open(t, DeviceLabLog());
    final f = find.byKey(const ValueKey('pattern-dynamic-tempo'));
    final sw = find.descendant(
      of: f,
      matching: find.byType(Switch),
      matchRoot: true,
    );
    expect(t.widget<Switch>(sw).value, isTrue);
    expect(r.pattern!.dynamicTempo, isTrue);
    expect(find.text('1 = 250 ms'), findsOneWidget);
    expect(find.textContaining('fitted'), findsNothing);
    await t.tap(sw);
    await t.pump(const Duration(milliseconds: 400));
    expect(r.pattern!.dynamicTempo, isFalse);
    expect(t.widget<Switch>(sw).value, isFalse);
    expect(find.text('1 = 250 ms'), findsOneWidget);
    r.closePattern();
  });

  testWidgets('a fitted tempo shows in the label while dynamic', (t) async {
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-len-1'); // test 1: N1
    r.patternTest(1);
    await t.pump(const Duration(milliseconds: 400));
    await _tapKey(t, 'pattern-len-1'); // test 2: N1
    r.pattern!.noteMeasured(0, 500);
    r.pattern!.noteMeasured(1, 500);
    r.patternDynamicTempo(true); // notifies the page
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('1 = 500 ms · fitted'), findsOneWidget);
    r.patternDynamicTempo(false);
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('1 = 250 ms'), findsOneWidget);
    r.closePattern();
  });

  testWidgets('the metronome timer stops when the page goes away', (t) async {
    final r = await _open(t, DeviceLabLog());
    await t.pump(const Duration(seconds: 1));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    expect(r.pattern, isNull);
    // testWidgets fails the test if a timer or ticker is still pending.
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

  // ---- 8Z G: a replay marches through the recorded sequence ----------------

  /// Fake time in small steps, so timers, the wheel animation and the frames
  /// between them all run (a metronome keeps frames coming, so pumpAndSettle
  /// would never settle).
  Future<void> advance(WidgetTester t, int ms) async {
    for (var i = 0; i < ms ~/ 25; i++) {
      await t.pump(const Duration(milliseconds: 25));
    }
  }

  final head = find.byKey(const ValueKey('pattern-playhead'));
  final wheelFinder = find.byKey(const ValueKey('pattern-wheel'));

  /// Types N1 R2 N1 on the open test (A); the cursor ends on the empty slot.
  Future<void> typeSequence(WidgetTester t, HardwareProbeRunner r) async {
    for (final n in [1, 2, 1]) {
      await _tapKey(t, 'pattern-len-$n');
    }
    expect(r.pattern!.active.code, 'N1 R2 N1');
  }

  void expectPlaying(WidgetTester t, int entry, {String? when}) {
    expect(head, findsOneWidget, reason: 'a playhead on entry $entry $when');
    expect(t.getSemantics(head).label, contains('playing entry $entry'));
    expect(
      (t.getCenter(head).dy - t.getCenter(wheelFinder).dy).abs(),
      lessThan(15),
      reason: 'the wheel follows the playhead to entry $entry',
    );
  }

  testWidgets('Play on a transcribed rendition marches a playhead through the '
      'entries at the default tempo, then the wheel returns to the cursor', (
    t,
  ) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await typeSequence(t, r);
    final s = r.pattern!;
    expect(head, findsNothing, reason: 'no march before Play');
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    await advance(t, 100);
    expect(r.patternPlaying, isTrue);
    expect(head, findsNothing, reason: 'the 300 ms lead has not passed');
    // Default: lead 300 ms, 250 ms per unit: N1 300-550, R2 550-1050, N1
    // 1050-1300.
    await advance(t, 400); // 500
    expectPlaying(t, 1);
    expect(s.cursor, 3, reason: 'the march never moves the cursor');
    await advance(t, 300); // 800
    expectPlaying(t, 2);
    expect(s.cursor, 3);
    await advance(t, 450); // 1250
    expectPlaying(t, 3);
    expect(s.cursor, 3);
    await advance(t, 400); // 1650
    expect(head, findsNothing, reason: 'the march is over');
    expect(s.cursor, 3);
    expect(s.active.code, 'N1 R2 N1', reason: 'the march edits nothing');
    expect(
      (t.getCenter(find.textContaining('Next entry')).dy -
              t.getCenter(wheelFinder).dy)
          .abs(),
      lessThan(15),
      reason: 'the wheel is back on the cursor',
    );
    r.closePattern();
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 30));
    h.dispose();
  });

  testWidgets('the march waits the measured lead and the metronome restarts '
      'at the same instant', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await typeSequence(t, r);
    r.pattern!.noteLead(1000);
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    await advance(t, 900);
    expect(head, findsNothing, reason: 'the lead is 1000 ms');
    final key = find.byKey(const ValueKey('pattern-metronome'));
    var waited = 0;
    while (head.evaluate().isEmpty && waited < 400) {
      await advance(t, 25);
      waited += 25;
    }
    expect(head, findsOneWidget, reason: 'the playhead starts at the lead');
    expect(waited, lessThanOrEqualTo(300), reason: 'about 1000 ms after Play');
    expect(
      t.getSemantics(key).label,
      'metronome step 1 of 8',
      reason: 'the dot restarts when the march starts',
    );
    r.closePattern();
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 30));
    h.dispose();
  });

  testWidgets('the march uses the fitted tempo', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await typeSequence(t, r);
    r.patternTest(1);
    await t.pump(const Duration(milliseconds: 400));
    await _tapKey(t, 'pattern-len-1'); // test 2: N1
    r.pattern!.noteMeasured(0, 2000); // 4 units: 500 ms each
    r.pattern!.noteMeasured(1, 500); // 1 unit: 500 ms
    r.patternTest(-1);
    await t.pump(const Duration(milliseconds: 400));
    expect(r.pattern!.unitMs, 500);
    expect(r.pattern!.active.code, 'N1 R2 N1');
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    // Lead 300 ms: N1 300-800, R2 800-1800, N1 1800-2300.
    await advance(t, 1300);
    expectPlaying(t, 2, when: 'at 1300 ms with 500 ms units');
    await advance(t, 800); // 2100
    expectPlaying(t, 3);
    r.closePattern();
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 30));
    h.dispose();
  });

  testWidgets('there is no march for an empty active rendition', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    for (var i = 0; i < 60; i++) {
      await advance(t, 50);
      expect(head, findsNothing, reason: 'first listen, nothing to march');
    }
    r.closePattern();
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 30));
    h.dispose();
  });

  testWidgets('only the active rendition counts: A has entries, B is empty', (
    t,
  ) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await typeSequence(t, r);
    await _tapKey(t, 'pattern-rendition-b');
    expect(r.pattern!.active.length, 0);
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    for (var i = 0; i < 40; i++) {
      await advance(t, 50);
      expect(head, findsNothing);
    }
    r.closePattern();
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 30));
    h.dispose();
  });

  testWidgets('tapping a length cancels the march and the wheel goes to the '
      'new cursor', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await typeSequence(t, r);
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    await advance(t, 800);
    expectPlaying(t, 2);
    await t.tap(find.byKey(const ValueKey('pattern-len-1')));
    await advance(t, 100);
    expect(head, findsNothing, reason: 'a tap cancels the march');
    expect(r.pattern!.active.code, 'N1 R2 N1 R1');
    await advance(t, 1500);
    expect(head, findsNothing, reason: 'it does not start again');
    expect(r.pattern!.cursor, 4);
    expect(
      (t.getCenter(find.textContaining('Next entry')).dy -
              t.getCenter(wheelFinder).dy)
          .abs(),
      lessThan(15),
      reason: 'the wheel follows the cursor after the edit',
    );
    r.closePattern();
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 30));
    h.dispose();
  });

  testWidgets('scrolling the wheel cancels the march', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await typeSequence(t, r);
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    await advance(t, 800);
    expectPlaying(t, 2);
    await t.drag(wheelFinder, const Offset(0, 60));
    await advance(t, 300);
    expect(head, findsNothing, reason: 'a scroll cancels the march');
    await advance(t, 1500);
    expect(head, findsNothing, reason: 'it does not start again');
    expect(r.pattern!.active.code, 'N1 R2 N1');
    r.closePattern();
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 30));
    h.dispose();
  });

  testWidgets('leaving the page mid-march leaves no timer behind', (t) async {
    final r = await _open(t, DeviceLabLog());
    await typeSequence(t, r);
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    await advance(t, 700);
    expect(head, findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 30));
    expect(r.pattern, isNull);
    // testWidgets fails the test if a timer is still pending.
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
