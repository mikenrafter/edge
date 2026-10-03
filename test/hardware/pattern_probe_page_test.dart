// 8Y/8Z/8AA: the pattern probe page, the transcriber the wearer taps. A header
// with the test, Play, a metronome dot and the A / B renditions, a wheel of note
// and rest entries with the cursor in the middle, and a footer (dynamics row,
// five length buttons, Note/Rest toggle, Delete) that stays on screen. The unit
// is a sixteenth (125 ms). Fake async time: the probe's real waits are pumped,
// not slept.
//
// Contracts these tests rely on that the spec leaves open:
//  - the length buttons are keyed `pattern-len-1`, `-2`, `-4`, `-6`, `-8` by
//    their 16th count; the dynamics buttons `pattern-dyn-ff`, `-mf`, `-mp`,
//    `-pp`. A dynamics button shows its name in a Text (bold, italic); the
//    selected one has the semantics "selected" flag. Only that flag and the
//    text style are tested, not how a disabled-looking button is drawn.
//  - a note row in the wheel shows its dynamic as a Text with the same name,
//    bold and italic; rest rows and the empty next slot show none.
//  - `pattern-metronome` is on the Semantics node labelled "metronome step N of
//    16" (N 1..16, one per sixteenth); the dot is a DecoratedBox below it whose
//    BoxDecoration.color is the beat colour at full strength on steps 1, 5, 9,
//    13, the same colour at a third of the saturation on steps 3, 7, 11, 15
//    and null/transparent on the even steps. The colour does not animate.
//  - `pattern-dynamic-tempo` is a Switch, or holds one.
//  - note/rest symbols (8Z, F): inside each length button and wheel row there
//    is one widget keyed `pattern-symbol` (a CustomPaint at its root) with a
//    Semantics label such as "quarter note" or "dotted quarter rest" (the row
//    label is swallowed by the row's own Semantics, so only the buttons are
//    read); the dashes are keyed `dash-1`..`dash-N` (one per sixteenth) and
//    hold a DecoratedBox whose BoxDecoration.color is the dash colour: beat
//    colour ((k - 1) ~/ 4) % 4 of the dot, a third of the saturation for rests.
//  - `pattern-kind` shows the text "Note" or "Rest".
//  - the march (8Z, G): the playhead is the widget keyed `pattern-playhead` on
//    the playing wheel row; the row's Semantics label says "playing entry N".
//    The march runs on timers from the first write's real landing time
//    (DateTime.now) plus the lead, so these tests sample the middle of each
//    entry's window rather than its edges.

import 'dart:async';
import 'dart:ui' show Tristate;

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

/// The five length buttons by their 16th count, and what each is called.
const _lens = [1, 2, 4, 6, 8];
const _lenNames = ['16th', 'eighth', 'quarter', 'dotted quarter', 'half'];
const _dyns = ['ff', 'mf', 'mp', 'pp'];

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
      for (final n in _lens) 'pattern-len-$n',
      for (final d in _dyns) 'pattern-dyn-$d',
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
    expect(find.text('1 sixteenth = 125 ms'), findsOneWidget);
    expect(find.text('1 = 250 ms'), findsNothing);
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
    // Nothing repeats yet, the toggle alternates: note, rest, note. Notes carry
    // the selected dynamic (mf by default), rests none.
    expect(r.pattern!.rendition(0, 0).code, 'N2mf R1 N4mf');
    expect(r.pattern!.cursor, 3);
    expect(find.text('Note'), findsWidgets);
    expect(find.text('Rest'), findsWidgets);
    expect(find.text('Buzz'), findsNothing);
    expect(find.text('Gap'), findsNothing);
    // Delete at the empty slot removes the last entry.
    await _tapKey(t, 'pattern-delete');
    expect(r.pattern!.rendition(0, 0).code, 'N2mf R1');
    r.closePattern();
  });

  testWidgets('the footer stays on screen when the list is long', (t) async {
    final r = await _open(t, DeviceLabLog(), size: const Size(360, 640));
    for (var i = 0; i < 32; i++) {
      r.patternTap(_lens[i % 5]);
    }
    await t.pump(const Duration(milliseconds: 600));
    expect(r.pattern!.rendition(0, 0).code.split(' '), hasLength(32));
    final screen = Offset.zero & const Size(360, 640);
    for (final k in [
      for (final n in _lens) 'pattern-len-$n',
      for (final d in _dyns) 'pattern-dyn-$d',
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
    await _tapKey(t, 'pattern-len-4');
    final s = r.pattern!;
    expect(s.cursor, 3, reason: 'on the empty next slot');
    expect(s.active.code, 'N1mf R2 N4mf');

    final wheel = find.byKey(const ValueKey('pattern-wheel'));
    await t.drag(wheel, const Offset(0, 300));
    await t.pumpAndSettle();
    final c = s.cursor;
    expect(
      c,
      lessThan(3),
      reason: 'dragging down goes back to earlier entries',
    );

    await _tapKey(t, 'pattern-len-6');
    final entries = s.rendition(0, 0).code.split(' ');
    expect(entries, hasLength(3), reason: 'replaced, not appended');
    expect(entries[c].substring(1), startsWith('6'));
    expect(
      [
        for (var i = 0; i < 3; i++)
          if (i != c) entries[i],
      ],
      [
        for (var i = 0; i < 3; i++)
          if (i != c) ['N1mf', 'R2', 'N4mf'][i],
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
    await _tapKey(t, 'pattern-len-4');
    await _tapKey(t, 'pattern-len-2');
    expect(r.pattern!.rendition(0, 1).code, 'N4mf R2');
    expect(r.pattern!.rendition(0, 0).code, 'N1mf');
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

  /// Whether button [n]'s symbol reads as a [kind] ('note' or 'rest') of its
  /// length. Needs semantics on.
  bool buttonIs(WidgetTester t, int n, String kind) {
    final i = _lens.indexOf(n);
    final label = t
        .getSemantics(
          find.descendant(
            of: find.byKey(ValueKey('pattern-len-$n')),
            matching: find.byKey(const ValueKey('pattern-symbol')),
          ),
        )
        .label;
    final other = kind == 'note' ? 'rest' : 'note';
    return label.contains('${_lenNames[i]} $kind') && !label.contains(other);
  }

  void expectButtons(WidgetTester t, String kind) {
    for (final n in _lens) {
      expect(buttonIs(t, n, kind), isTrue, reason: 'button $n is a $kind');
    }
  }

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

  testWidgets('the toggle flips after every tap and the labels follow', (
    t,
  ) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    expectButtons(t, 'note');
    expect(kindText(t), 'Note');
    await _tapKey(t, 'pattern-len-2');
    expectButtons(t, 'rest');
    expect(kindText(t), 'Rest');
    await _tapKey(t, 'pattern-len-1');
    expectButtons(t, 'note');
    expect(kindText(t), 'Note');
    await _tapKey(t, 'pattern-len-4');
    expectButtons(t, 'rest');
    expect(r.pattern!.nextIsNote, isFalse);
    expect(r.pattern!.active.code, 'N2mf R1 N4mf');
    r.closePattern();
    h.dispose();
  });

  testWidgets('a repeating pattern does not change the toggle: it alternates '
      'whatever the lengths', (t) async {
    final r = await _open(t, DeviceLabLog());
    for (final n in [1, 1, 1, 1, 1]) {
      await _tapKey(t, 'pattern-len-$n');
    }
    expect(r.pattern!.active.code, 'N1mf R1 N1mf R1 N1mf');
    expect(kindText(t), 'Rest');
    r.closePattern();
  });

  testWidgets('the toggle sits left of Delete, below the length buttons and '
      'the dynamics row', (t) async {
    final r = await _open(t, DeviceLabLog());
    final kind = t.getRect(find.byKey(const ValueKey('pattern-kind')));
    final del = t.getRect(find.byKey(const ValueKey('pattern-delete')));
    expect(kind.right, lessThanOrEqualTo(del.left), reason: '$kind $del');
    expect((kind.center.dy - del.center.dy).abs(), lessThan(8));
    for (final n in _lens) {
      final len = t.getRect(find.byKey(ValueKey('pattern-len-$n')));
      expect(len.bottom, lessThanOrEqualTo(kind.top), reason: 'len $n');
      for (final d in _dyns) {
        final dyn = t.getRect(find.byKey(ValueKey('pattern-dyn-$d')));
        expect(dyn.bottom, lessThanOrEqualTo(len.top), reason: '$d above $n');
      }
    }
    r.closePattern();
  });

  testWidgets('five length buttons sit in one row of equal width', (t) async {
    final r = await _open(t, DeviceLabLog(), size: const Size(360, 640));
    final rects = [
      for (final n in _lens) t.getRect(find.byKey(ValueKey('pattern-len-$n'))),
    ];
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].left, greaterThanOrEqualTo(rects[i - 1].right));
      expect((rects[i].top - rects[0].top).abs(), lessThan(1));
      expect(rects[i].width, closeTo(rects[0].width, 1));
    }
    expect(rects.first.left, greaterThanOrEqualTo(0));
    expect(rects.last.right, lessThanOrEqualTo(360));
    expect(t.takeException(), isNull);
    r.closePattern();
  });

  testWidgets('overriding the toggle gives two rests in a row', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-len-1'); // N1, then the toggle says Rest
    await _tapKey(t, 'pattern-len-2'); // R2, then the toggle says Note
    expectButtons(t, 'note');
    await _tapKey(t, 'pattern-kind');
    expectButtons(t, 'rest');
    expect(kindText(t), 'Rest');
    expect(r.pattern!.nextIsNote, isFalse);
    await _tapKey(t, 'pattern-len-4'); // a second rest
    expect(r.pattern!.active.code, 'N1mf R2 R4');
    expect(kindText(t), 'Note', reason: 'it alternates again after the tap');
    expectButtons(t, 'note');
    r.closePattern();
    h.dispose();
  });

  testWidgets('overriding the toggle gives two notes in a row', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-len-1'); // N1, then the toggle says Rest
    expect(kindText(t), 'Rest');
    await _tapKey(t, 'pattern-kind'); // back to Note
    expectButtons(t, 'note');
    await _tapKey(t, 'pattern-len-2');
    expect(r.pattern!.active.code, 'N1mf N2mf');
    await _tapKey(t, 'pattern-kind');
    await _tapKey(t, 'pattern-kind');
    expect(kindText(t), 'Rest', reason: 'two flips cancel out');
    r.closePattern();
    h.dispose();
  });

  testWidgets('the footer has no suggested-length mark', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    for (final n in [1, 1, 1, 1]) {
      await _tapKey(t, 'pattern-len-$n');
    }
    for (final n in _lens) {
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
    for (final n in [1, 2, 4]) {
      await _tapKey(t, 'pattern-len-$n');
    }
    expect(r.pattern!.active.code, 'N1mf R2 N4mf');
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

  // ---- 8AA: dynamics ---------------------------------------------------------

  /// Whether the dynamics button [d] is announced as selected.
  bool dynSelected(WidgetTester t, String d) => t
      .getSemantics(find.byKey(ValueKey('pattern-dyn-$d')))
      .flagsCollection
      .isSelected ==
      Tristate.isTrue;

  /// The Texts a dynamics button or wheel row shows for [d].
  Finder dynTextIn(Finder of, String d) =>
      find.descendant(of: of, matching: find.text(d));

  testWidgets('the dynamics row has ff, mf, mp, pp in bold italic and mf is '
      'selected by default', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    for (final d in _dyns) {
      final text = dynTextIn(find.byKey(ValueKey('pattern-dyn-$d')), d);
      expect(text, findsOneWidget, reason: 'button $d shows "$d"');
      final style = t.widget<Text>(text).style;
      expect(style?.fontStyle, FontStyle.italic, reason: '$d italic');
      expect(
        style?.fontWeight?.value ?? 0,
        greaterThanOrEqualTo(FontWeight.w700.value),
        reason: '$d bold',
      );
      expect(dynSelected(t, d), d == 'mf', reason: 'only mf starts selected');
    }
    // Loudest to softest, left to right.
    final lefts = [
      for (final d in _dyns)
        t.getRect(find.byKey(ValueKey('pattern-dyn-$d'))).left,
    ];
    expect(lefts, [...lefts]..sort());
    expect(r.pattern!.active.length, 0);
    r.closePattern();
    h.dispose();
  });

  testWidgets('a dynamic is sticky: notes are written with it, rests have '
      'none, and it stays selected after the tap', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-dyn-pp');
    for (final d in _dyns) {
      expect(dynSelected(t, d), d == 'pp', reason: 'pp alone is selected');
    }
    await _tapKey(t, 'pattern-len-4'); // N4pp
    await _tapKey(t, 'pattern-len-2'); // R2, no dynamic
    await _tapKey(t, 'pattern-len-1'); // N1pp, still pp
    expect(r.pattern!.active.code, 'N4pp R2 N1pp');
    expect(dynSelected(t, 'pp'), isTrue, reason: 'it does not reset');
    expect(dynSelected(t, 'mf'), isFalse);
    await _tapKey(t, 'pattern-dyn-ff');
    await _tapKey(t, 'pattern-len-8'); // a rest now (after N1)
    await _tapKey(t, 'pattern-len-6'); // N6ff
    expect(r.pattern!.active.code, 'N4pp R2 N1pp R8 N6ff');
    r.closePattern();
    h.dispose();
  });

  testWidgets('a dynamic picked on the Rest toggle still applies to the next '
      'note', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-len-4'); // N4mf; the toggle says Rest
    expect(kindText(t), 'Rest');
    await _tapKey(t, 'pattern-dyn-mp');
    expect(dynSelected(t, 'mp'), isTrue, reason: 'selectable on a rest');
    expect(r.pattern!.active.code, 'N4mf', reason: 'nothing else changed');
    expect(kindText(t), 'Rest', reason: 'the toggle is untouched');
    await _tapKey(t, 'pattern-kind');
    await _tapKey(t, 'pattern-len-2');
    expect(r.pattern!.active.code, 'N4mf N2mp');
    r.closePattern();
    h.dispose();
  });

  testWidgets('a dynamic tapped on the empty next slot changes no row', (
    t,
  ) async {
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-len-4');
    await _tapKey(t, 'pattern-len-2');
    expect(r.pattern!.cursor, 2, reason: 'on the empty next slot');
    await _tapKey(t, 'pattern-dyn-ff');
    expect(r.pattern!.active.code, 'N4mf R2');
    expect(r.pattern!.cursor, 2);
    await _tapKey(t, 'pattern-len-1');
    expect(r.pattern!.active.code, 'N4mf R2 N1ff');
    r.closePattern();
  });

  testWidgets('a dynamic tapped while the cursor is on a note changes that '
      'row and its dynamic text', (t) async {
    final r = await _open(t, DeviceLabLog());
    final wheel = find.byKey(const ValueKey('pattern-wheel'));
    await _tapKey(t, 'pattern-len-4'); // N4mf
    await _tapKey(t, 'pattern-kind');
    await _tapKey(t, 'pattern-len-2'); // N2mf; the toggle says Rest
    await _tapKey(t, 'pattern-len-1'); // R1, so the toggle says Note
    expect(r.pattern!.active.code, 'N4mf N2mf R1');
    expect(dynTextIn(wheel, 'mf'), findsNWidgets(2), reason: 'notes only');
    r.patternMove(-3); // onto the first note
    await t.pump(const Duration(milliseconds: 400));
    expect(r.pattern!.cursor, 0);
    await _tapKey(t, 'pattern-dyn-ff');
    expect(r.pattern!.active.code, 'N4ff N2mf R1');
    expect(r.pattern!.cursor, 0, reason: 'the cursor stays');
    expect(dynTextIn(wheel, 'ff'), findsOneWidget);
    expect(dynTextIn(wheel, 'mf'), findsOneWidget);
    // The sticky selection moved too, so the next note is ff.
    r.patternMove(3);
    await t.pump(const Duration(milliseconds: 400));
    await _tapKey(t, 'pattern-len-2');
    expect(r.pattern!.active.code, 'N4ff N2mf R1 N2ff');
    r.closePattern();
  });

  testWidgets('note rows show their dynamic in bold italic, rest rows show '
      'none', (t) async {
    final r = await _open(t, DeviceLabLog());
    final wheel = find.byKey(const ValueKey('pattern-wheel'));
    await _tapKey(t, 'pattern-dyn-mp');
    await _tapKey(t, 'pattern-len-4'); // N4mp
    await _tapKey(t, 'pattern-len-2'); // R2
    expect(r.pattern!.active.code, 'N4mp R2');
    final mp = dynTextIn(wheel, 'mp');
    expect(mp, findsOneWidget, reason: 'one note row says mp');
    final style = t.widget<Text>(mp).style;
    expect(style?.fontStyle, FontStyle.italic);
    expect(
      style?.fontWeight?.value ?? 0,
      greaterThanOrEqualTo(FontWeight.w700.value),
    );
    for (final d in ['ff', 'mf', 'pp']) {
      expect(dynTextIn(wheel, d), findsNothing, reason: 'no row says $d');
    }
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

  /// The metronome's four beat colours A, C, D, E, read off the dot at steps
  /// 1, 5, 9 and 13; the dashes must use these same colours.
  Future<List<Color>> metronomeColours(WidgetTester t) async {
    final key = find.byKey(const ValueKey('pattern-metronome'));
    final byBeat = <int, Color>{};
    for (var i = 0; i < 40 && byBeat.length < 4; i++) {
      final m = RegExp(r'metronome step (\d+) of 16')
          .firstMatch(t.getSemantics(key).label);
      final step = int.parse(m!.group(1)!);
      final c = colourOf(t, key);
      if (step % 4 == 1 && c != null && c.a > 0) byBeat[(step - 1) ~/ 4] = c;
      await t.pump(const Duration(milliseconds: 125));
    }
    expect(byBeat.keys.toSet(), {0, 1, 2, 3});
    return [for (var b = 0; b < 4; b++) byBeat[b]!];
  }

  testWidgets('each length button shows a music symbol: 16th, eighth, '
      'quarter, dotted quarter, half', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    Future<void> check(String kind) async {
      for (var i = 0; i < _lens.length; i++) {
        final n = _lens[i];
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
          contains('${_lenNames[i]} $kind'),
        );
      }
    }

    await check('note');
    await _tapKey(t, 'pattern-len-1');
    await check('rest');
    r.closePattern();
    h.dispose();
  });

  testWidgets('dashes: one per 16th, coloured by the beat they fall in; rests '
      'are the same colours at one third of the saturation', (t) async {
    final r = await _open(t, DeviceLabLog());
    final c = await metronomeColours(t);
    expect(c.toSet(), hasLength(4));

    Finder dash(int n, int k) => find.descendant(
      of: find.byKey(ValueKey('pattern-len-$n')),
      matching: find.byKey(ValueKey('dash-$k')),
    );

    void check(bool note) {
      for (final n in _lens) {
        for (var k = 1; k <= n; k++) {
          expect(dash(n, k), findsOneWidget, reason: 'button $n dash $k');
          final want = c[((k - 1) ~/ 4) % 4];
          final got = colourOf(t, dash(n, k))!;
          final base = HSLColor.fromColor(want);
          final hsl = HSLColor.fromColor(got);
          if (note) {
            expect(got.toARGB32(), want.toARGB32(), reason: 'note $n/$k');
          } else {
            expect(
              hsl.saturation,
              closeTo(base.saturation / 3, 0.03),
              reason: 'rest $n/$k',
            );
            expect(hsl.hue, closeTo(base.hue, 2), reason: 'rest $n/$k');
            expect(hsl.lightness, closeTo(base.lightness, 0.03));
          }
        }
        expect(dash(n, n + 1), findsNothing, reason: 'one dash per sixteenth');
      }
    }

    check(true);
    await _tapKey(t, 'pattern-len-2'); // N2; the buttons now write rests
    check(false);
    r.closePattern();
  });

  testWidgets('a half note is 8 dashes and they fit the button and the row at '
      '360 px', (t) async {
    final r = await _open(t, DeviceLabLog(), size: const Size(360, 640));
    final btn = t.getRect(find.byKey(const ValueKey('pattern-len-8')));
    for (var k = 1; k <= 8; k++) {
      final d = t.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('pattern-len-8')),
          matching: find.byKey(ValueKey('dash-$k')),
        ),
      );
      expect(d.left, greaterThanOrEqualTo(btn.left), reason: 'dash $k left');
      expect(d.right, lessThanOrEqualTo(btn.right), reason: 'dash $k right');
      expect(d.width, greaterThan(0));
    }
    await _tapKey(t, 'pattern-len-8');
    expect(r.pattern!.active.code, 'N8mf');
    final wheel = t.getRect(find.byKey(const ValueKey('pattern-wheel')));
    final row = find.descendant(
      of: find.byKey(const ValueKey('pattern-wheel')),
      matching: find.byKey(const ValueKey('dash-8')),
    );
    expect(row, findsOneWidget, reason: 'the row shows all 8 dashes');
    final d8 = t.getRect(row);
    expect(d8.right, lessThanOrEqualTo(wheel.right));
    expect(d8.left, greaterThanOrEqualTo(wheel.left));
    expect(t.takeException(), isNull, reason: 'no overflow');
    r.closePattern();
  });

  testWidgets('wheel rows carry the same symbols and dash colours', (t) async {
    final r = await _open(t, DeviceLabLog());
    final c = await metronomeColours(t);
    await _tapKey(t, 'pattern-len-2'); // N2
    await _tapKey(t, 'pattern-len-6'); // R6
    expect(r.pattern!.active.code, 'N2mf R6');
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
    bool third(Color x, Color base) {
      final a = HSLColor.fromColor(x);
      final b = HSLColor.fromColor(base);
      return (a.saturation - b.saturation / 3).abs() < 0.03 &&
          (a.hue - b.hue).abs() < 2;
    }

    // The note row (N2) has dashes 1 and 2 at full colour (beat 1); the rest
    // row (R6) has dashes 1 to 4 at a third of beat 1's colour and dashes 5
    // and 6 at a third of beat 2's.
    expect(dashes(1), hasLength(2), reason: 'one per row');
    expect(dashes(2), hasLength(2));
    for (final k in [1, 2]) {
      expect(dashes(k).map((x) => x.toARGB32()), contains(c[0].toARGB32()));
      expect(dashes(k).any((x) => third(x, c[0])), isTrue, reason: 'rest $k');
    }
    for (final k in [3, 4]) {
      expect(dashes(k), hasLength(1), reason: 'only the rest row');
      expect(third(dashes(k).single, c[0]), isTrue, reason: 'rest dash $k');
    }
    for (final k in [5, 6]) {
      expect(dashes(k), hasLength(1), reason: 'only the rest row');
      expect(third(dashes(k).single, c[1]), isTrue, reason: 'rest dash $k');
      expect(third(dashes(k).single, c[0]), isFalse, reason: 'beat 2, not 1');
    }
    r.closePattern();
  });

  testWidgets('the metronome steps every 125 ms through 16 steps: beats full, '
      'the ands at a third of the saturation, the rest off', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    final key = find.byKey(const ValueKey('pattern-metronome'));
    ({int step, Color? color}) dot() {
      final label = t.getSemantics(key).label;
      final m = RegExp(r'metronome step (\d+) of 16').firstMatch(label);
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
    final beats = <int, Color>{}; // beat 0..3 -> full colour
    final ands = <int, Color>{}; // beat 0..3 -> the third-saturation colour
    for (var i = 0; i < 33; i++) {
      await t.pump(const Duration(milliseconds: 125));
      final d = dot();
      expect(d.step, prev % 16 + 1, reason: 'one step per 125 ms, in a loop');
      final beat = (d.step - 1) ~/ 4;
      if (d.step % 4 == 1) {
        expect(d.color, isNotNull, reason: 'step ${d.step} is a beat');
        beats[beat] = d.color!;
      } else if (d.step % 4 == 3) {
        expect(d.color, isNotNull, reason: 'step ${d.step} is an and');
        ands[beat] = d.color!;
      } else {
        expect(d.color, isNull, reason: 'step ${d.step} is off');
      }
      prev = d.step;
    }
    expect(beats.keys.toSet(), {0, 1, 2, 3});
    expect(ands.keys.toSet(), {0, 1, 2, 3});
    expect(
      beats.values.map((c) => c.toARGB32()).toSet(),
      hasLength(4),
      reason: 'A, C, D and E are four colours',
    );
    for (var b = 0; b < 4; b++) {
      final base = HSLColor.fromColor(beats[b]!);
      final and = HSLColor.fromColor(ands[b]!);
      expect(and.saturation, closeTo(base.saturation / 3, 0.03), reason: '$b');
      expect(and.hue, closeTo(base.hue, 2), reason: 'same colour, beat $b');
      expect(and.lightness, closeTo(base.lightness, 0.03));
    }
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
    expect(label(), isNot('metronome step 1 of 16'), reason: 'mid-bar');
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    await t.pump(const Duration(milliseconds: 10));
    await t.pump(const Duration(milliseconds: 10));
    expect(r.patternPlaying, isTrue);
    expect(label(), 'metronome step 1 of 16');
    await t.pump(const Duration(milliseconds: 125));
    expect(label(), 'metronome step 2 of 16');
    await t.pump(const Duration(milliseconds: 125));
    expect(label(), 'metronome step 3 of 16');
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

  testWidgets('Dynamic tempo is on by default, shows 1 sixteenth = 125 ms, '
      'and the switch turns it off', (t) async {
    final r = await _open(t, DeviceLabLog());
    final f = find.byKey(const ValueKey('pattern-dynamic-tempo'));
    final sw = find.descendant(
      of: f,
      matching: find.byType(Switch),
      matchRoot: true,
    );
    expect(t.widget<Switch>(sw).value, isTrue);
    expect(r.pattern!.dynamicTempo, isTrue);
    expect(find.text('1 sixteenth = 125 ms'), findsOneWidget);
    expect(find.textContaining('fitted'), findsNothing);
    await t.tap(sw);
    await t.pump(const Duration(milliseconds: 400));
    expect(r.pattern!.dynamicTempo, isFalse);
    expect(t.widget<Switch>(sw).value, isFalse);
    expect(find.text('1 sixteenth = 125 ms'), findsOneWidget);
    r.closePattern();
  });

  testWidgets('a fitted tempo shows in the label while dynamic', (t) async {
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-len-1'); // test 1: N1
    r.patternTest(1);
    await t.pump(const Duration(milliseconds: 400));
    await _tapKey(t, 'pattern-len-1'); // test 2: N1
    r.pattern!.noteMeasured(0, 250); // 1 sixteenth: 250 ms
    r.pattern!.noteMeasured(1, 250);
    r.patternDynamicTempo(true); // notifies the page
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('1 sixteenth = 250 ms · fitted'), findsOneWidget);
    r.patternDynamicTempo(false);
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('1 sixteenth = 125 ms'), findsOneWidget);
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

  /// Types an eighth note, a quarter rest and an eighth note (8 sixteenths)
  /// on the open test (A); the cursor ends on the empty slot.
  Future<void> typeSequence(WidgetTester t, HardwareProbeRunner r) async {
    for (final n in [2, 4, 2]) {
      await _tapKey(t, 'pattern-len-$n');
    }
    expect(r.pattern!.active.code, 'N2mf R4 N2mf');
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
    // Default: lead 300 ms, 125 ms per sixteenth: N2 300-550, R4 550-1050, N2
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
    expect(s.active.code, 'N2mf R4 N2mf', reason: 'the march edits nothing');
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
      'metronome step 1 of 16',
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
    await _tapKey(t, 'pattern-len-2'); // test 2: N2
    r.pattern!.noteMeasured(0, 2000); // 8 sixteenths: 250 ms each
    r.pattern!.noteMeasured(1, 500); // 2 sixteenths: 250 ms each
    r.patternTest(-1);
    await t.pump(const Duration(milliseconds: 400));
    expect(r.pattern!.unitMs, 250);
    expect(r.pattern!.active.code, 'N2mf R4 N2mf');
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    // Lead 300 ms: N2 300-800, R4 800-1800, N2 1800-2300.
    await advance(t, 1300);
    expectPlaying(t, 2, when: 'at 1300 ms with 250 ms sixteenths');
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
    expect(r.pattern!.active.code, 'N2mf R4 N2mf R1');
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
    expect(r.pattern!.active.code, 'N2mf R4 N2mf');
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
