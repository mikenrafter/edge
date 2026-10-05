// 8Y/8Z/8AA/8AB: the pattern probe page, the transcriber the wearer taps. A
// header with the test, Play, a metronome dot, a Finish button and the A / B
// renditions, a wheel of note and rest entries with the cursor in the middle,
// and a footer (dynamics row, four length buttons plus a Dot toggle, Note/Rest
// toggle, Delete) that stays on screen. The unit is a sixteenth (125 ms). Fake
// async time: the probe's real waits are pumped, not slept.
//
// Contracts these tests rely on that the spec leaves open:
//  - the length buttons are keyed `pattern-len-1`, `-2`, `-4`, `-8` by their
//    16th count (16th, eighth, quarter, half); next to them in the same row is
//    the Dot toggle `pattern-dot` (8AB, A), whose Semantics carry the
//    "selected" flag while it is on. While it is on the buttons write 3, 6 and
//    12 sixteenths (dotted eighth, quarter, half), their symbols read "dotted
//    eighth note" and so on with 3, 6 and 12 dashes, and the 16th button does
//    nothing (it is disabled). One tap on a length button clears the dot. The
//    dynamics buttons (8AC: six) are `pattern-dyn-ff`, `-f`, `-mf`, `-mp`,
//    `-p`, `-pp`, loudest to softest. A dynamics button shows its name in a Text (bold, italic); the
//    selected one has the semantics "selected" flag. Only that flag and the
//    text style are tested, not how a disabled-looking button is drawn.
//  - a note row in the wheel shows its dynamic as a Text with the same name,
//    bold and italic; rest rows and the empty next slot show none.
//  - `pattern-metronome` (8AB, B) is idle until Play: its Semantics label is
//    "metronome idle" and the dot is an outline. Play starts a one-measure
//    count-in (step 1 at the press, 16 steps of one unit) and calls
//    runner.playPattern() at the count-in's end minus the measured lead (at
//    once if that is already past). The march starts at the count-in's end
//    (the downbeat), not at the first write plus the lead. The metronome runs
//    on and goes idle at the end of one padding measure after the later of
//    "the play finished" and "the march's last entry ended", aligned to the
//    bar. A refused play (runner.patternRefusal non-null after the play)
//    stops it at once. While running the node is labelled "metronome step N of
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
//    These tests sample the middle of each entry's window rather than its
//    edges. Times are measured from the Play press on the fake clock.
//  - the end screen (8AB, C): `pattern-finish` in the header, or the back arrow
//    or system back, closes the session (heard lines and tempo line in the lab
//    log) and then shows `pattern-end` with the tests transcribed ("k of 40"),
//    the plays, the tempo line ("1 sixteenth ≈ N ms", "fitted"/"fixed") and the
//    measured lead ("N ms"); `pattern-copy` ("Save probe log file", 8AL) hands
//    logText() (called after the close) to the page's `saveLog:` as a named
//    file and shows "Saved"; `pattern-done` or system back leaves the page.
//    The page takes `logText:`.
//  - refusals (8AB, D): a refused play shows a `pattern-refused` line under
//    Play: "Band resting, ready in N s" counting down (runner.patternRestRemaining
//    is a Duration?), or the probe's reason ("Not connected"). The line clears
//    on the next successful play. The page never edits while a count-in or
//    play it started runs, in these tests.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/haptics/heard_log.dart';
import 'package:openstrap_edge/ui2/profile/pattern_probe_page.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/util/log_file.dart';

/// Flip [up] to false to drop the link after the probe is open.
class _Link {
  bool up = true;
}

/// A live band event on the phone clock, as the panel test builds them.
StrapEvent _event(int id) {
  final ms = DateTime.now().millisecondsSinceEpoch;
  return StrapEvent(
    eventId: id,
    tsEpoch: ms ~/ 1000,
    tsSubsec: ((ms % 1000) * 32768) ~/ 1000,
    receivedAt: DateTime.now(),
    hex: '',
    deviceId: 'band',
  );
}

/// A live 100 stamped a little ahead of the (fake) clock, so a play ends at its
/// own write and takes no fake time (see the panel test's copy of this).
StrapEvent _clockEvent(int id) {
  final now = clock.now().add(const Duration(seconds: 10));
  final ms = now.millisecondsSinceEpoch;
  return StrapEvent(
    eventId: id,
    tsEpoch: ms ~/ 1000,
    tsSubsec: ((ms % 1000) * 32768) ~/ 1000,
    receivedAt: now,
    hex: '',
    deviceId: 'band',
  );
}

/// When (fake clock) each play reached the band, filled by [_runner].
typedef _SentAt = List<DateTime>;

HardwareProbeRunner _runner(
  DeviceLabLog lab, {
  List<List<int>>? sent,
  _SentAt? sentAt,
  Completer<void>? holdPattern,
  _Link? link,
  bool bandEvents = false,
  bool quickEnd = false,
}) {
  late final HardwareProbeRunner r;
  r = HardwareProbeRunner(
    lab: lab,
    sendBuzz: (onReply) async {
      onReply('pending', 40);
      return true;
    },
    sendPattern: (effects, loop, onReply) async {
      sent?.add(List.of(effects));
      sentAt?.add(clock.now());
      await holdPattern?.future;
      // The band answers each write with its live start and end events, so a
      // play does not wait out the probe's timeouts.
      if (bandEvents) {
        r.onBandEvent(_event(60));
        r.onBandEvent(_event(100));
      }
      if (quickEnd) r.onBandEvent(_clockEvent(100));
      onReply('pending', 40);
      return true;
    },
    isConnected: () => link?.up ?? true,
    ecgSupported: () => true,
    ecgBusy: () => false,
    beginEcg: () async => false,
    endEcg: () async {},
    isEcgAlive: () => false,
  );
  return r;
}

const _tall = Size(390, 844);

/// Whether test [i] is flagged unstable (8AC); read dynamically so the rest
/// of this file compiles before the session has the flag.
bool _unstable(HardwareProbeRunner r, int i) =>
    (r.pattern as dynamic).unstable(i) as bool;

/// The four length buttons by their 16th count, and what each is called. The
/// Dot toggle `pattern-dot` makes them 3, 6, 12 (and the 16th is disabled).
const _lens = [1, 2, 4, 8];
const _lenNames = ['16th', 'eighth', 'quarter', 'half'];
const _dyns = ['ff', 'f', 'mf', 'mp', 'p', 'pp'];

void _view(WidgetTester t, Size size) {
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

/// Opens the page on [r], which must already be open.
Future<void> _show(
  WidgetTester t,
  HardwareProbeRunner r, {
  String Function()? logText,
  LogFileSaver? saveLog,
}) async {
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: PatternProbePage(
        runner: r,
        logText: logText ?? () => 'log',
        saveLog: saveLog,
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 300));
}

Future<HardwareProbeRunner> _open(
  WidgetTester t,
  DeviceLabLog lab, {
  Size size = _tall,
  List<List<int>>? sent,
  _SentAt? sentAt,
  Completer<void>? holdPattern,
  _Link? link,
  bool bandEvents = false,
  String Function()? logText,
  LogFileSaver? saveLog,
}) async {
  _view(t, size);
  final r = _runner(
    lab,
    sent: sent,
    sentAt: sentAt,
    holdPattern: holdPattern,
    link: link,
    bandEvents: bandEvents,
  );
  await r.openPattern();
  await _show(t, r, logText: logText, saveLog: saveLog);
  return r;
}

/// Closes the session and lets everything pending run out: the page's
/// timers, the probe's waits.
Future<void> _finish(WidgetTester t, HardwareProbeRunner r) async {
  r.closePattern();
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 30));
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
      'pattern-dot',
      for (final d in _dyns) 'pattern-dyn-$d',
      'pattern-kind',
      'pattern-delete',
      'pattern-metronome',
      'pattern-dynamic-tempo',
      'pattern-finish',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    for (final k in ['pattern-len-3', 'pattern-len-6', 'pattern-len-12']) {
      expect(find.byKey(ValueKey(k)), findsNothing, reason: '$k: dot, not a key');
    }
    for (final k in ['pattern-refused', 'pattern-end']) {
      expect(find.byKey(ValueKey(k)), findsNothing, reason: k);
    }
    expect(find.textContaining('Pick Note or Rest, then a length.'), findsOneWidget);
    expect(
      find.textContaining('Scroll to an entry to change it.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Each play waits for the band to finish the last one; at most 30 '
        'commands in any 2 minutes; leaving this screen stops it.',
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
    expect(find.textContaining('160'), findsNothing, reason: 'no session cap');
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
      r.patternTap(_lens[i % 4]);
    }
    await t.pump(const Duration(milliseconds: 600));
    expect(r.pattern!.rendition(0, 0).code.split(' '), hasLength(32));
    final screen = Offset.zero & const Size(360, 640);
    for (final k in [
      for (final n in _lens) 'pattern-len-$n',
      'pattern-dot',
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

    await _tapKey(t, 'pattern-len-8');
    final entries = s.rendition(0, 0).code.split(' ');
    expect(entries, hasLength(3), reason: 'replaced, not appended');
    expect(entries[c].substring(1), startsWith('8'));
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

  testWidgets('four length buttons and the Dot sit in one row of equal width', (
    t,
  ) async {
    final r = await _open(t, DeviceLabLog(), size: const Size(360, 640));
    final rects = [
      for (final n in _lens) t.getRect(find.byKey(ValueKey('pattern-len-$n'))),
      t.getRect(find.byKey(const ValueKey('pattern-dot'))),
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

  // ---- 8AC: f and p, and the unstable toggle ---------------------------------

  testWidgets('the dynamics row has six buttons in a row, ff, f, mf, mp, p, '
      'pp, and they fit at 360 px (8AC)', (t) async {
    final r = await _open(t, DeviceLabLog(), size: const Size(360, 640));
    expect(_dyns, ['ff', 'f', 'mf', 'mp', 'p', 'pp']);
    final rects = [
      for (final d in _dyns) t.getRect(find.byKey(ValueKey('pattern-dyn-$d'))),
    ];
    for (var i = 1; i < rects.length; i++) {
      expect(
        rects[i].left,
        greaterThanOrEqualTo(rects[i - 1].right),
        reason: '${_dyns[i]} sits right of ${_dyns[i - 1]}, no overlap',
      );
      expect((rects[i].top - rects[0].top).abs(), lessThan(1), reason: 'one row');
    }
    for (final (i, rect) in rects.indexed) {
      expect(rect.left, greaterThanOrEqualTo(0), reason: _dyns[i]);
      expect(rect.right, lessThanOrEqualTo(360), reason: _dyns[i]);
      expect(rect.width, greaterThanOrEqualTo(40), reason: '${_dyns[i]} can be hit');
      expect(
        find.byKey(ValueKey('pattern-dyn-${_dyns[i]}')).hitTestable(),
        findsOneWidget,
      );
    }
    expect(t.takeException(), isNull);
    r.closePattern();
  });

  testWidgets('the footer is fully visible at 360x640 with six dynamics '
      '(8AC)', (t) async {
    final r = await _open(t, DeviceLabLog(), size: const Size(360, 640));
    final screen = Offset.zero & const Size(360, 640);
    for (final k in [
      for (final n in _lens) 'pattern-len-$n',
      'pattern-dot',
      for (final d in _dyns) 'pattern-dyn-$d',
      'pattern-kind',
      'pattern-delete',
    ]) {
      final rect = t.getRect(find.byKey(ValueKey(k)));
      expect(
        screen.contains(rect.topLeft) && screen.contains(rect.bottomRight),
        isTrue,
        reason: '$k is fully on screen: $rect',
      );
    }
    expect(t.takeException(), isNull);
    r.closePattern();
  });

  testWidgets('f and p buttons are bold italic, select, and write notes '
      '(8AC)', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    for (final d in ['f', 'p']) {
      final text = dynTextIn(find.byKey(ValueKey('pattern-dyn-$d')), d);
      expect(text, findsOneWidget, reason: 'button $d shows "$d"');
      final style = t.widget<Text>(text).style;
      expect(style?.fontStyle, FontStyle.italic, reason: '$d italic');
      expect(
        style?.fontWeight?.value ?? 0,
        greaterThanOrEqualTo(FontWeight.w700.value),
        reason: '$d bold',
      );
    }
    await _tapKey(t, 'pattern-dyn-f');
    for (final d in _dyns) {
      expect(dynSelected(t, d), d == 'f', reason: 'only f is selected');
    }
    await _tapKey(t, 'pattern-len-4');
    await _tapKey(t, 'pattern-len-2'); // a rest
    await _tapKey(t, 'pattern-dyn-p');
    for (final d in _dyns) {
      expect(dynSelected(t, d), d == 'p', reason: 'only p is selected');
    }
    await _tapKey(t, 'pattern-len-2');
    expect(r.pattern!.active.code, 'N4f R2 N2p');
    expect(r.pattern!.nextDynamic.name, 'p');
    r.closePattern();
    h.dispose();
  });

  testWidgets('a note row shows f and p as its dynamic, bold and italic '
      '(8AC)', (t) async {
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-dyn-f');
    await _tapKey(t, 'pattern-len-4');
    await _tapKey(t, 'pattern-len-1'); // a rest
    await _tapKey(t, 'pattern-dyn-p');
    await _tapKey(t, 'pattern-len-2');
    final wheel = find.byKey(const ValueKey('pattern-wheel'));
    for (final d in ['f', 'p']) {
      final text = find.descendant(of: wheel, matching: find.text(d));
      expect(text, findsOneWidget, reason: 'one note row shows "$d"');
      final style = t.widget<Text>(text).style;
      expect(style?.fontStyle, FontStyle.italic, reason: d);
      expect(
        style?.fontWeight?.value ?? 0,
        greaterThanOrEqualTo(FontWeight.w700.value),
        reason: d,
      );
    }
    r.closePattern();
  });

  testWidgets('changing the note under the cursor to f or p works from the '
      'button (8AC)', (t) async {
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-len-4');
    await _tapKey(t, 'pattern-len-2');
    await _tapKey(t, 'pattern-len-1');
    r.patternMove(-3);
    await t.pump(const Duration(milliseconds: 400));
    await _tapKey(t, 'pattern-dyn-f');
    r.patternMove(2);
    await t.pump(const Duration(milliseconds: 400));
    await _tapKey(t, 'pattern-dyn-p');
    expect(r.pattern!.active.code, 'N4f R2 N1p');
    r.closePattern();
  });

  bool unstableSelected(WidgetTester t) => t
      .getSemantics(find.byKey(const ValueKey('pattern-unstable')))
      .flagsCollection
      .isSelected ==
      Tristate.isTrue;

  Finder chipText(String key, String text) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.text(text),
      );

  testWidgets('the Unstable toggle starts off and the chips read A and B '
      '(8AC)', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    final toggle = find.byKey(const ValueKey('pattern-unstable'));
    expect(toggle, findsOneWidget);
    expect(
      find.descendant(of: toggle, matching: find.text('Unstable')),
      findsOneWidget,
    );
    expect(unstableSelected(t), isFalse);
    expect(_unstable(r, 0), isFalse);
    expect(chipText('pattern-rendition-a', 'A'), findsOneWidget);
    expect(chipText('pattern-rendition-b', 'B'), findsOneWidget);
    expect(find.text('A · shortest'), findsNothing);
    expect(find.text('B · longest'), findsNothing);
    r.closePattern();
    h.dispose();
  });

  testWidgets('tapping Unstable flags the test, selects the toggle and '
      'relabels the chips "A · shortest" and "B · longest"; tapping again '
      'undoes it (8AC)', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-unstable');
    expect(_unstable(r, 0), isTrue);
    expect(unstableSelected(t), isTrue);
    expect(chipText('pattern-rendition-a', 'A · shortest'), findsOneWidget);
    expect(chipText('pattern-rendition-b', 'B · longest'), findsOneWidget);
    expect(chipText('pattern-rendition-a', 'A'), findsNothing);
    await _tapKey(t, 'pattern-unstable');
    expect(_unstable(r, 0), isFalse);
    expect(unstableSelected(t), isFalse);
    expect(chipText('pattern-rendition-a', 'A'), findsOneWidget);
    expect(chipText('pattern-rendition-b', 'B'), findsOneWidget);
    r.closePattern();
    h.dispose();
  });

  testWidgets('Unstable is per test: the next test shows plain A and B, and '
      'the flag is still there when the wearer comes back (8AC)', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-unstable');
    await _tapKey(t, 'pattern-next');
    expect(r.pattern!.testIndex, 1);
    expect(unstableSelected(t), isFalse);
    expect(chipText('pattern-rendition-a', 'A'), findsOneWidget);
    expect(find.text('A · shortest'), findsNothing);
    await _tapKey(t, 'pattern-prev');
    expect(unstableSelected(t), isTrue);
    expect(chipText('pattern-rendition-a', 'A · shortest'), findsOneWidget);
    expect(chipText('pattern-rendition-b', 'B · longest'), findsOneWidget);
    r.closePattern();
    h.dispose();
  });

  testWidgets('the A and B chips still switch the rendition while Unstable '
      'is on, and the data does not depend on which holds the shortest '
      '(8AC)', (t) async {
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-unstable');
    await _tapKey(t, 'pattern-len-4');
    await _tapKey(t, 'pattern-rendition-b');
    expect(r.pattern!.activeRendition, 1);
    await _tapKey(t, 'pattern-len-1');
    expect(r.pattern!.rendition(0, 0).code, 'N4mf');
    expect(r.pattern!.rendition(0, 1).code, 'N1mf');
    expect(_unstable(r, 0), isTrue);
    await _tapKey(t, 'pattern-rendition-a');
    expect(r.pattern!.activeRendition, 0);
    r.closePattern();
  });

  testWidgets('Unstable sits in the same header as the renditions and the '
      'longer chip labels still fit at 360 px (8AC)', (t) async {
    final r = await _open(t, DeviceLabLog(), size: const Size(360, 640));
    await _tapKey(t, 'pattern-unstable');
    final screen = Offset.zero & const Size(360, 640);
    final keys = [
      'pattern-play',
      'pattern-rendition-a',
      'pattern-rendition-b',
      'pattern-unstable',
    ];
    final rects = {
      for (final k in keys) k: t.getRect(find.byKey(ValueKey(k))),
    };
    for (final k in keys) {
      final rect = rects[k]!;
      expect(
        screen.contains(rect.topLeft) && screen.contains(rect.bottomRight),
        isTrue,
        reason: '$k is on screen: $rect',
      );
      expect(find.byKey(ValueKey(k)).hitTestable(), findsOneWidget, reason: k);
    }
    for (final a in keys) {
      for (final b in keys) {
        if (a.compareTo(b) >= 0) continue;
        expect(
          rects[a]!.overlaps(rects[b]!),
          isFalse,
          reason: '$a and $b do not overlap: ${rects[a]} ${rects[b]}',
        );
      }
    }
    expect(t.takeException(), isNull, reason: 'no overflow with the long labels');
    // The footer is still fully on screen.
    final kind = t.getRect(find.byKey(const ValueKey('pattern-kind')));
    expect(kind.bottom, lessThanOrEqualTo(640));
    r.closePattern();
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
    await _tapKey(t, 'pattern-dot');
    await _tapKey(t, 'pattern-len-4'); // N6ff, a dotted quarter
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
  /// 1, 5, 9 and 13 of a count-in; the dashes must use these same colours. Presses
  /// Play and lets the whole play and its metronome run out, so the caller
  /// starts from an idle page again. Needs semantics on.
  Future<List<Color>> metronomeColours(WidgetTester t) async {
    final key = find.byKey(const ValueKey('pattern-metronome'));
    final byBeat = <int, Color>{};
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    await t.pump(const Duration(milliseconds: 20));
    for (var i = 0; i < 14 && byBeat.length < 4; i++) {
      final m = RegExp(
        r'metronome step (\d+) of 16',
      ).firstMatch(t.getSemantics(key).label);
      final step = int.parse(m!.group(1)!);
      final c = colourOf(t, key);
      if (step % 4 == 1 && c != null && c.a > 0) byBeat[(step - 1) ~/ 4] = c;
      await t.pump(const Duration(milliseconds: 125));
    }
    expect(byBeat.keys.toSet(), {0, 1, 2, 3});
    await t.pump(const Duration(seconds: 40));
    expect(t.getSemantics(key).label, 'metronome idle');
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
    final h = t.ensureSemantics();
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
    await _finish(t, r);
    h.dispose();
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
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    final c = await metronomeColours(t);
    await _tapKey(t, 'pattern-len-2'); // N2
    await _tapKey(t, 'pattern-dot');
    await _tapKey(t, 'pattern-len-4'); // R6, a dotted quarter rest
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
    await _finish(t, r);
    h.dispose();
  });

  // ---- 8AB B: the metronome is a count-in for Play ---------------------------

  final metro = find.byKey(const ValueKey('pattern-metronome'));

  /// The metronome's label, e.g. 'metronome step 3 of 16' or 'metronome idle'.
  String metroLabel(WidgetTester t) => t.getSemantics(metro).label;

  /// The step 1..16, or null when idle.
  int? metroStep(WidgetTester t) {
    final m = RegExp(r'metronome step (\d+) of 16').firstMatch(metroLabel(t));
    return m == null ? null : int.parse(m.group(1)!);
  }

  /// The dot's fill, null when it is an outline.
  Color? dotFill(WidgetTester t) {
    final box = t.widget<DecoratedBox>(
      find.descendant(of: metro, matching: find.byType(DecoratedBox)).first,
    );
    final c = (box.decoration as BoxDecoration).color;
    return c == null || c.a == 0 ? null : c;
  }

  /// Presses Play and returns the fake-clock instant of the press. The step 1
  /// of the count-in shows at once.
  Future<DateTime> pressPlay(WidgetTester t) async {
    final t0 = clock.now();
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    await t.pump(const Duration(milliseconds: 20));
    return t0;
  }

  /// Fake time in 25 ms steps until [ms] after [t0] (no more than 25 ms past
  /// it).
  Future<void> until(WidgetTester t, DateTime t0, int ms) async {
    while (clock.now().difference(t0).inMilliseconds < ms) {
      await t.pump(const Duration(milliseconds: 25));
    }
  }

  testWidgets('the metronome is idle until Play: an outline, no steps', (
    t,
  ) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    for (var i = 0; i < 20; i++) {
      expect(metroLabel(t), 'metronome idle', reason: 'at ${i * 125} ms');
      expect(dotFill(t), isNull, reason: 'an outline while idle');
      await t.pump(const Duration(milliseconds: 125));
    }
    expect(find.textContaining('metronome step'), findsNothing);
    await _finish(t, r);
    h.dispose();
  });

  testWidgets('Play starts the metronome at step 1 and it steps every 125 ms: '
      'beats full, the ands at a third of the saturation, the rest off', (
    t,
  ) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    expect(metroLabel(t), 'metronome idle');
    await pressPlay(t);
    expect(metroLabel(t), 'metronome step 1 of 16');
    var prev = 1;
    final beats = <int, Color>{}; // beat 0..3 -> full colour
    final ands = <int, Color>{}; // beat 0..3 -> the third-saturation colour
    for (var i = 0; i < 33; i++) {
      await t.pump(const Duration(milliseconds: 125));
      final step = metroStep(t);
      expect(step, prev % 16 + 1, reason: 'one step per 125 ms, in a loop');
      final d = (step: step!, color: dotFill(t));
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
    await _finish(t, r);
    h.dispose();
  });

  testWidgets('the count-in is one measure: the band is asked at its end '
      'minus the default lead of 300 ms, and the dot is on step 1 again at '
      'the downbeat', (t) async {
    final h = t.ensureSemantics();
    final sentAt = <DateTime>[];
    final r = await _open(t, DeviceLabLog(), sentAt: sentAt);
    final t0 = await pressPlay(t);
    await until(t, t0, 1500);
    expect(sentAt, isEmpty, reason: 'nothing is sent during the count-in');
    expect(r.patternPlaying, isFalse);
    await until(t, t0, 1800);
    expect(sentAt, hasLength(1));
    final lead = sentAt.single.difference(t0).inMilliseconds;
    expect(lead, closeTo(2000 - 300, 60), reason: 'count-in 2000 ms - lead');
    expect(r.patternPlaying, isTrue);
    // The dot keeps stepping through the downbeat: step 16 then 1 again.
    await until(t, t0, 1900);
    expect(metroStep(t), 16, reason: '1875-2000 ms is the last sixteenth');
    await until(t, t0, 2060);
    expect(metroStep(t), 1, reason: 'the downbeat after the count-in');
    await until(t, t0, 2190);
    expect(metroStep(t), 2);
    await _finish(t, r);
    h.dispose();
  });

  testWidgets('the band is asked a measured lead before the downbeat', (
    t,
  ) async {
    final h = t.ensureSemantics();
    final sentAt = <DateTime>[];
    final r = await _open(t, DeviceLabLog(), sentAt: sentAt);
    r.pattern!.noteLead(1000);
    final t0 = await pressPlay(t);
    await until(t, t0, 900);
    expect(sentAt, isEmpty);
    await until(t, t0, 1200);
    expect(sentAt, hasLength(1));
    expect(
      sentAt.single.difference(t0).inMilliseconds,
      closeTo(2000 - 1000, 60),
    );
    await _finish(t, r);
    h.dispose();
  });

  testWidgets('a lead longer than the count-in asks the band at once', (
    t,
  ) async {
    final h = t.ensureSemantics();
    final sentAt = <DateTime>[];
    final r = await _open(t, DeviceLabLog(), sentAt: sentAt);
    // Two tests of one sixteenth each, measured at 50 ms: the fitted tempo is
    // 50 ms, so the count-in is 800 ms; the lead is 1500 ms.
    await _tapKey(t, 'pattern-len-1');
    r.patternTest(1);
    await t.pump(const Duration(milliseconds: 400));
    await _tapKey(t, 'pattern-len-1');
    r.pattern!.noteMeasured(0, 50);
    r.pattern!.noteMeasured(1, 50);
    r.pattern!.noteLead(1500);
    r.patternDynamicTempo(true);
    r.patternTest(-1);
    await t.pump(const Duration(milliseconds: 400));
    expect(r.pattern!.unitMs, 50);
    expect(r.pattern!.leadMs, 1500);
    final t0 = await pressPlay(t);
    await until(t, t0, 200);
    expect(sentAt, hasLength(1), reason: 'the moment is already past');
    expect(sentAt.single.difference(t0).inMilliseconds, lessThan(150));
    await _finish(t, r);
    h.dispose();
  });

  /// Runs fake time from [t0] until the metronome goes idle or [limitMs]
  /// pass. Returns (ms of the first idle, ms the play finished or null).
  Future<({int? idleAt, int? playDoneAt, bool sawRunning})> runOut(
    WidgetTester t,
    HardwareProbeRunner r,
    DateTime t0,
    int limitMs,
  ) async {
    int? idleAt, playDoneAt;
    var sawPlaying = false, sawRunning = false;
    while (clock.now().difference(t0).inMilliseconds < limitMs) {
      await t.pump(const Duration(milliseconds: 25));
      final now = clock.now().difference(t0).inMilliseconds;
      if (r.patternPlaying) sawPlaying = true;
      if (sawPlaying && !r.patternPlaying) playDoneAt ??= now;
      if (metroStep(t) != null) {
        sawRunning = true;
      } else if (sawRunning) {
        idleAt = now;
        break;
      }
    }
    return (idleAt: idleAt, playDoneAt: playDoneAt, sawRunning: sawRunning);
  }

  testWidgets('with nothing to march the metronome stops one padding measure '
      'after the play finished, on a bar line', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    final t0 = await pressPlay(t);
    final run = await runOut(t, r, t0, 40000);
    expect(run.playDoneAt, isNotNull, reason: 'the play finishes');
    expect(run.idleAt, isNotNull, reason: 'the metronome goes idle');
    final idle = run.idleAt!, done = run.playDoneAt!;
    expect(idle, greaterThanOrEqualTo(done + 2000 - 50), reason: 'a measure');
    expect(idle, lessThanOrEqualTo(done + 4000 + 50), reason: 'only one');
    // Bars start at the downbeat, 2000 ms after the press.
    final off = (idle - 2000) % 2000;
    expect(
      off < 60 || off > 2000 - 60,
      isTrue,
      reason: 'stops on a bar line, idle at $idle ms (offset $off)',
    );
    expect(metroLabel(t), 'metronome idle');
    await _finish(t, r);
    h.dispose();
  });

  testWidgets('a march that outlasts the play keeps the metronome going until '
      'it ends, plus one padding measure', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    for (var i = 0; i < 8; i++) {
      await _tapKey(t, 'pattern-len-8'); // 8 x 8 sixteenths = 8000 ms
    }
    expect(r.pattern!.active.length, 8);
    final t0 = await pressPlay(t);
    final run = await runOut(t, r, t0, 60000);
    // The march runs 2000 ms (count-in) to 10000 ms.
    expect(run.playDoneAt, isNotNull);
    expect(run.idleAt, isNotNull);
    final idle = run.idleAt!;
    expect(
      idle,
      greaterThanOrEqualTo(10000 + 2000 - 50),
      reason: 'a measure after the march ended',
    );
    expect(
      idle,
      lessThanOrEqualTo(math.max(10000, run.playDoneAt!) + 4000 + 50),
      reason: 'one padding measure, not more',
    );
    expect(
      idle,
      greaterThanOrEqualTo(run.playDoneAt! + 2000 - 50),
      reason: 'and after the play finished',
    );
    final off = (idle - 2000) % 2000;
    expect(off < 60 || off > 2000 - 60, isTrue, reason: 'idle at $idle ms');
    await _finish(t, r);
    h.dispose();
  });

  testWidgets('a play that is refused stops the metronome at once and says '
      'why', (t) async {
    final h = t.ensureSemantics();
    final link = _Link();
    final sent = <List<int>>[];
    final r = await _open(t, DeviceLabLog(), link: link, sent: sent);
    expect(find.byKey(const ValueKey('pattern-refused')), findsNothing);
    link.up = false;
    final t0 = await pressPlay(t);
    expect(metroStep(t), 1, reason: 'the count-in starts');
    await until(t, t0, 1500);
    expect(metroStep(t), isNotNull, reason: 'it runs until the band is asked');
    await until(t, t0, 1900);
    expect(sent, isEmpty);
    expect(r.patternRefusal, isNotNull);
    expect(metroLabel(t), 'metronome idle', reason: 'stopped on the refusal');
    final line = find.byKey(const ValueKey('pattern-refused'));
    expect(line, findsOneWidget);
    expect(
      find.descendant(of: line, matching: find.textContaining('Not connected')),
      findsOneWidget,
    );
    await until(t, t0, 8000);
    expect(metroLabel(t), 'metronome idle', reason: 'and stays stopped');
    await _finish(t, r);
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

  testWidgets('Play buzzes the band after the count-in, is disabled while '
      'playing, and counts', (t) async {
    final hold = Completer<void>();
    final sent = <List<int>>[];
    final r = await _open(t, DeviceLabLog(), sent: sent, holdPattern: hold);
    final t0 = clock.now();
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    await t.pump(const Duration(milliseconds: 300));
    expect(sent, isEmpty, reason: 'the count-in comes first');
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    await until(t, t0, 1900);
    expect(r.patternPlaying, isTrue);
    expect(sent, hasLength(1), reason: 'a second tap did not start a second');
    expect(find.text('Playing…'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pattern-play')));
    await t.pump(const Duration(milliseconds: 300));
    expect(sent, hasLength(1), reason: 'a tap while playing does nothing');

    hold.complete();
    await t.pump(const Duration(seconds: 20));
    expect(r.patternPlaying, isFalse);
    expect(find.text('Playing…'), findsNothing);
    expect(find.text('Played 1×'), findsOneWidget);
    await _finish(t, r);
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

  testWidgets('Play on a transcribed rendition marches a playhead from the '
      'downbeat at the default tempo, then the wheel returns to the cursor', (
    t,
  ) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await typeSequence(t, r);
    final s = r.pattern!;
    expect(head, findsNothing, reason: 'no march before Play');
    final t0 = await pressPlay(t);
    await until(t, t0, 1500);
    expect(head, findsNothing, reason: 'the count-in is a measure of 2000 ms');
    await until(t, t0, 1950);
    expect(head, findsNothing, reason: 'not at the first write plus the lead');
    // 125 ms per sixteenth from the downbeat at 2000: N2 2000-2250, R4
    // 2250-2750, N2 2750-3000.
    await until(t, t0, 2200);
    expectPlaying(t, 1);
    expect(s.cursor, 3, reason: 'the march never moves the cursor');
    await until(t, t0, 2500);
    expectPlaying(t, 2);
    expect(s.cursor, 3);
    await until(t, t0, 2900);
    expectPlaying(t, 3);
    expect(s.cursor, 3);
    await until(t, t0, 3300);
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
    await _finish(t, r);
    h.dispose();
  });

  testWidgets('the march starts at the downbeat whatever the lead, and the '
      'dot is on step 1 there', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await typeSequence(t, r);
    r.pattern!.noteLead(1000);
    final t0 = await pressPlay(t);
    await until(t, t0, 1500);
    expect(head, findsNothing, reason: 'the band starts at 1000 ms, not the '
        'playhead');
    await until(t, t0, 1950);
    expect(head, findsNothing);
    await until(t, t0, 2060);
    expect(head, findsOneWidget, reason: 'the playhead is on entry 1');
    expect(metroStep(t), 1, reason: 'the dot is on the downbeat');
    await until(t, t0, 2220);
    expectPlaying(t, 1);
    await _finish(t, r);
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
    final t0 = await pressPlay(t);
    // The count-in is 16 x 250 = 4000 ms. N2 4000-4500, R4 4500-5500, N2
    // 5500-6000.
    await until(t, t0, 3500);
    expect(head, findsNothing);
    await until(t, t0, 5000);
    expectPlaying(t, 2, when: 'at 5000 ms with 250 ms sixteenths');
    await until(t, t0, 5750);
    expectPlaying(t, 3);
    await _finish(t, r);
    h.dispose();
  });

  testWidgets('there is no march for an empty active rendition', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    final t0 = await pressPlay(t);
    for (var i = 0; i < 160; i++) {
      await advance(t, 50);
      expect(head, findsNothing, reason: 'first listen, nothing to march');
    }
    expect(clock.now().difference(t0).inMilliseconds, greaterThan(8000));
    await _finish(t, r);
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
    for (var i = 0; i < 100; i++) {
      await advance(t, 50);
      expect(head, findsNothing);
    }
    await _finish(t, r);
    h.dispose();
  });

  testWidgets('tapping a length cancels the march and the wheel goes to the '
      'new cursor', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await typeSequence(t, r);
    final t0 = await pressPlay(t);
    await until(t, t0, 2500);
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
    await _finish(t, r);
    h.dispose();
  });

  testWidgets('scrolling the wheel cancels the march', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await typeSequence(t, r);
    final t0 = await pressPlay(t);
    await until(t, t0, 2500);
    expectPlaying(t, 2);
    await t.drag(wheelFinder, const Offset(0, 60));
    await advance(t, 300);
    expect(head, findsNothing, reason: 'a scroll cancels the march');
    await advance(t, 1500);
    expect(head, findsNothing, reason: 'it does not start again');
    expect(r.pattern!.active.code, 'N2mf R4 N2mf');
    await _finish(t, r);
    h.dispose();
  });

  testWidgets('leaving the page mid-march leaves no timer behind', (t) async {
    final r = await _open(t, DeviceLabLog());
    await typeSequence(t, r);
    final t0 = await pressPlay(t);
    await until(t, t0, 2125);
    expect(head, findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 30));
    expect(r.pattern, isNull);
    // testWidgets fails the test if a timer is still pending.
  });

  testWidgets('leaving the page during the count-in leaves no timer behind', (
    t,
  ) async {
    final sent = <List<int>>[];
    final r = await _open(t, DeviceLabLog(), sent: sent);
    await pressPlay(t);
    await t.pump(const Duration(milliseconds: 500));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 30));
    expect(r.pattern, isNull);
    expect(sent, isEmpty, reason: 'the band is not asked after leaving');
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

  // ---- 8AB A: dotted notes ---------------------------------------------------

  /// Whether the widget at [key] is announced as selected. Needs semantics.
  bool selectedOf(WidgetTester t, String key) =>
      t.getSemantics(find.byKey(ValueKey(key))).flagsCollection.isSelected ==
      Tristate.isTrue;

  /// The symbol label of length button [n], e.g. 'dotted eighth note'.
  String symbolLabel(WidgetTester t, int n) => t
      .getSemantics(
        find.descendant(
          of: find.byKey(ValueKey('pattern-len-$n')),
          matching: find.byKey(const ValueKey('pattern-symbol')),
        ),
      )
      .label;

  testWidgets('the Dot button is a toggle: selected while on, off again on a '
      'second tap, and the runner passes it through', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    expect(r.pattern!.dotNext, isFalse);
    expect(selectedOf(t, 'pattern-dot'), isFalse);
    await _tapKey(t, 'pattern-dot');
    expect(r.pattern!.dotNext, isTrue);
    expect(selectedOf(t, 'pattern-dot'), isTrue);
    await _tapKey(t, 'pattern-dot');
    expect(r.pattern!.dotNext, isFalse);
    expect(selectedOf(t, 'pattern-dot'), isFalse);
    r.patternToggleDot();
    await t.pump(const Duration(milliseconds: 400));
    expect(r.pattern!.dotNext, isTrue, reason: 'the runner flips it');
    expect(selectedOf(t, 'pattern-dot'), isTrue, reason: 'the page follows');
    expect(r.pattern!.active.length, 0, reason: 'the dot writes nothing');
    r.closePattern();
    h.dispose();
  });

  testWidgets('with the dot on the buttons are dotted: names, dashes, and the '
      '16th is disabled', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-dot');
    const dotted = {2: 'dotted eighth', 4: 'dotted quarter', 8: 'dotted half'};
    const dashes = {2: 3, 4: 6, 8: 12};
    Future<void> check(String kind) async {
      for (final n in dotted.keys) {
        expect(
          symbolLabel(t, n),
          contains('${dotted[n]} $kind'),
          reason: 'button $n',
        );
        Finder dash(int k) => find.descendant(
          of: find.byKey(ValueKey('pattern-len-$n')),
          matching: find.byKey(ValueKey('dash-$k')),
        );
        expect(dash(dashes[n]!), findsOneWidget, reason: 'button $n dashes');
        expect(dash(dashes[n]! + 1), findsNothing, reason: 'button $n dashes');
      }
    }

    await check('note');
    await _tapKey(t, 'pattern-kind');
    await check('rest');
    await _tapKey(t, 'pattern-kind');
    expect(r.pattern!.dotNext, isTrue, reason: 'the toggle keeps the dot');
    // A 16th cannot be dotted: the button does nothing and the dot stays.
    await _tapKey(t, 'pattern-len-1');
    expect(r.pattern!.active.length, 0, reason: 'nothing was written');
    expect(r.pattern!.dotNext, isTrue);
    expect(selectedOf(t, 'pattern-dot'), isTrue);
    // Off again: plain names and dashes.
    await _tapKey(t, 'pattern-dot');
    for (final n in dotted.keys) {
      expect(symbolLabel(t, n), isNot(contains('dotted')), reason: 'plain $n');
    }
    r.closePattern();
    h.dispose();
  });

  testWidgets('a length with the dot on writes 3, 6 or 12 sixteenths and '
      'clears the dot', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-dot');
    await _tapKey(t, 'pattern-len-2'); // N3
    expect(r.pattern!.dotNext, isFalse, reason: 'one-shot');
    expect(selectedOf(t, 'pattern-dot'), isFalse);
    expect(symbolLabel(t, 2), 'eighth rest', reason: 'plain again');
    await _tapKey(t, 'pattern-dot');
    await _tapKey(t, 'pattern-len-4'); // R6
    await _tapKey(t, 'pattern-len-8'); // N8, no dot
    await _tapKey(t, 'pattern-dot');
    await _tapKey(t, 'pattern-len-8'); // R12
    expect(r.pattern!.active.code, 'N3mf R6 N8mf R12');
    // A 16th still works once the dot is off.
    await _tapKey(t, 'pattern-len-1');
    expect(r.pattern!.active.code, 'N3mf R6 N8mf R12 N1mf');
    r.closePattern();
    h.dispose();
  });

  testWidgets('a dotted length replaces the entry under the cursor', (t) async {
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-len-2');
    await _tapKey(t, 'pattern-len-4');
    expect(r.pattern!.active.code, 'N2mf R4');
    r.patternMove(-2); // onto the first entry
    await t.pump(const Duration(milliseconds: 400));
    expect(r.pattern!.cursor, 0);
    await _tapKey(t, 'pattern-dot');
    await _tapKey(t, 'pattern-len-4');
    expect(r.pattern!.active.code, 'N6mf R4');
    expect(r.pattern!.dotNext, isFalse);
    r.closePattern();
  });

  testWidgets('wheel rows say dotted lengths and show their dashes', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-dot');
    await _tapKey(t, 'pattern-len-2'); // N3
    await _tapKey(t, 'pattern-dot');
    await _tapKey(t, 'pattern-len-8'); // R12
    expect(r.pattern!.active.code, 'N3mf R12');
    expect(
      find.bySemanticsLabel(RegExp('dotted eighth note mf, entry 1')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp('dotted half rest, entry 2')),
      findsOneWidget,
    );
    final wheel = find.byKey(const ValueKey('pattern-wheel'));
    for (final k in [3, 12]) {
      expect(
        find.descendant(of: wheel, matching: find.byKey(ValueKey('dash-$k'))),
        findsWidgets,
        reason: 'a row shows dash $k',
      );
    }
    r.closePattern();
    h.dispose();
  });

  testWidgets('a dotted half is 12 dashes and they fit its button and its row '
      'at 360 px', (t) async {
    final r = await _open(t, DeviceLabLog(), size: const Size(360, 640));
    await _tapKey(t, 'pattern-dot');
    final btn = t.getRect(find.byKey(const ValueKey('pattern-len-8')));
    for (var k = 1; k <= 12; k++) {
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
    expect(r.pattern!.active.code, 'N12mf');
    final wheel = t.getRect(find.byKey(const ValueKey('pattern-wheel')));
    final row = find.descendant(
      of: find.byKey(const ValueKey('pattern-wheel')),
      matching: find.byKey(const ValueKey('dash-12')),
    );
    expect(row, findsOneWidget, reason: 'the row shows all 12 dashes');
    expect(t.getRect(row).right, lessThanOrEqualTo(wheel.right));
    expect(t.getRect(row).left, greaterThanOrEqualTo(wheel.left));
    expect(t.takeException(), isNull, reason: 'no overflow');
    r.closePattern();
  });

  // ---- 8AB C: the end screen -------------------------------------------------

  /// The page behind a launcher button, so Done and back can pop to it.
  Future<HardwareProbeRunner> openNav(
    WidgetTester t,
    DeviceLabLog lab, {
    String Function()? logText,
  }) async {
    _view(t, _tall);
    final r = _runner(lab);
    await r.openPattern();
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              key: const ValueKey('launch'),
              onPressed: () => Navigator.of(c).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      PatternProbePage(runner: r, logText: logText ?? () => 'log'),
                ),
              ),
              child: const Text('Device lab'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('launch')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(PatternProbePage), findsOneWidget);
    return r;
  }

  /// Every Text on the end screen, one per line.
  String endText(WidgetTester t) => t
      .widgetList<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('pattern-end')),
          matching: find.byType(Text),
        ),
      )
      .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
      .join('\n');

  testWidgets('Finish closes the session first, then shows the end screen with '
      'the counts, the tempo and the lead', (t) async {
    final lab = DeviceLabLog();
    final r = await _open(t, lab);
    await _tapKey(t, 'pattern-len-2'); // test 1 transcribed
    r.pattern!.notePlayed(0);
    r.pattern!.notePlayed(0);
    r.pattern!.noteLead(450);
    expect(find.byKey(const ValueKey('pattern-end')), findsNothing);
    await _tapKey(t, 'pattern-finish');
    expect(r.pattern, isNull, reason: 'the session is closed');
    expect(r.running, isNull);
    expect(lab.steps.join('\n'), contains('Pattern probe heard 1/40'));
    expect(lab.steps.join('\n'), contains('Pattern probe tempo'));
    expect(
      lab.sessionSummaries.single,
      contains('1 of 40 tests transcribed, 2 plays'),
    );
    expect(find.byKey(const ValueKey('pattern-end')), findsOneWidget);
    expect(find.byKey(const ValueKey('pattern-wheel')), findsNothing);
    expect(find.byKey(const ValueKey('pattern-play')), findsNothing);
    expect(find.byKey(const ValueKey('pattern-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('pattern-done')), findsOneWidget);
    final text = endText(t);
    expect(text, contains('1 of 40'));
    expect(
      text,
      matches(RegExp(r'(plays?\W+2\b|\b2\s+plays?)', caseSensitive: false)),
    );
    expect(text, contains('1 sixteenth ≈ 125 ms'));
    expect(text, contains('fixed'));
    expect(text, contains('450 ms'), reason: 'the measured Bluetooth lead');
    expect(find.text('Saved'), findsNothing, reason: 'not before the save');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('the end screen says when the tempo was fitted', (t) async {
    final r = await _open(t, DeviceLabLog());
    await _tapKey(t, 'pattern-len-1');
    r.patternTest(1);
    await t.pump(const Duration(milliseconds: 400));
    await _tapKey(t, 'pattern-len-1');
    r.pattern!.noteMeasured(0, 250);
    r.pattern!.noteMeasured(1, 250);
    r.patternDynamicTempo(true);
    await t.pump(const Duration(milliseconds: 400));
    await _tapKey(t, 'pattern-finish');
    final text = endText(t);
    expect(text, contains('1 sixteenth ≈ 250 ms'));
    expect(text, contains('fitted'));
    expect(text, isNot(contains('fixed')));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('Save probe log file on the end screen saves logText() as a '
      'named file, called after the session closed, and says Saved', (t) async {
    final saved = <(String, String)>[];
    final lab = DeviceLabLog();
    final calls = <bool>[];
    late final HardwareProbeRunner r;
    r = await _open(
      t,
      lab,
      logText: () {
        calls.add(r.pattern != null);
        return 'LAB LOG\n${lab.steps.reversed.join('\n')}';
      },
      saveLog: (n, x) async {
        saved.add((n, x));
        return true;
      },
    );
    await _tapKey(t, 'pattern-len-2');
    await _tapKey(t, 'pattern-finish');
    expect(saved, isEmpty, reason: 'Finish saves nothing by itself');
    expect(find.text('Save probe log file'), findsOneWidget);
    await _tapKey(t, 'pattern-copy');
    expect(saved, hasLength(1));
    expect(calls, [false], reason: 'built after closePattern');
    expect(
      saved.single.$1,
      matches(RegExp(r'^openstrap-pattern-probe-log-\d{8}-\d{6}\.txt$')),
    );
    final text = saved.single.$2;
    expect(text, startsWith('LAB LOG'));
    expect(
      text,
      contains('Pattern probe heard 1/40'),
      reason: 'the heard lines are in the file',
    );
    expect(text, contains('Pattern probe tempo'));
    expect(find.text('Saved'), findsWidgets);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('the back arrow also leads to the end screen, after closing the '
      'session; Done returns to the lab', (t) async {
    final lab = DeviceLabLog();
    final r = await openNav(t, lab);
    await _tapKey(t, 'pattern-len-2');
    await t.tap(
      find.descendant(
        of: find.byType(NavBar),
        matching: find.byIcon(LucideIcons.chevronLeft),
      ),
    );
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(PatternProbePage), findsOneWidget, reason: 'still here');
    expect(find.byKey(const ValueKey('pattern-end')), findsOneWidget);
    expect(r.pattern, isNull);
    expect(lab.steps.join('\n'), contains('Pattern probe heard 1/40'));
    await _tapKey(t, 'pattern-done');
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(PatternProbePage), findsNothing);
    expect(find.byKey(const ValueKey('launch')), findsOneWidget);
    expect(lab.sessionSummaries, hasLength(1), reason: 'closed once');
    expect(
      'Pattern probe heard 1/40'.allMatches(lab.steps.join('\n')),
      hasLength(1),
      reason: 'logged once',
    );
  });

  testWidgets('Finish then Done returns to the lab', (t) async {
    final lab = DeviceLabLog();
    await openNav(t, lab);
    await _tapKey(t, 'pattern-finish');
    expect(find.byKey(const ValueKey('pattern-end')), findsOneWidget);
    await _tapKey(t, 'pattern-done');
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(PatternProbePage), findsNothing);
    expect(find.byKey(const ValueKey('launch')), findsOneWidget);
  });

  testWidgets('system back: from the transcriber it goes to the end screen, '
      'from the end screen it is Done', (t) async {
    final lab = DeviceLabLog();
    final r = await openNav(t, lab);
    await _tapKey(t, 'pattern-len-4');
    await t.binding.handlePopRoute();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('pattern-end')), findsOneWidget);
    expect(r.pattern, isNull);
    expect(lab.steps.join('\n'), contains('Pattern probe heard 1/40'));
    await t.binding.handlePopRoute();
    await t.pump(const Duration(milliseconds: 500));
    // The exit animation starts on the first frame after the pop.
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(PatternProbePage), findsNothing);
    expect(find.byKey(const ValueKey('launch')), findsOneWidget);
  });

  testWidgets('Finish during a count-in stops it and shows the end screen', (
    t,
  ) async {
    final sent = <List<int>>[];
    final r = await _open(t, DeviceLabLog(), sent: sent);
    await pressPlay(t);
    await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.byKey(const ValueKey('pattern-finish')));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('pattern-end')), findsOneWidget);
    expect(r.pattern, isNull);
    await t.pump(const Duration(seconds: 10));
    expect(sent, isEmpty, reason: 'the band is not asked after Finish');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  // ---- 8AB D: refusals are visible --------------------------------------------

  testWidgets('after 30 commands in two minutes the next play is refused: the '
      'page says the band is resting and counts down, then a play clears it', (
    t,
  ) async {
    final h = t.ensureSemantics();
    _view(t, _tall);
    final sent = <List<int>>[];
    final r = _runner(DeviceLabLog(), sent: sent, bandEvents: true);
    await r.openPattern();
    // Plays of test 1 until 30 commands are written (two per play).
    for (var i = 0; i < 40 && sent.length < 30; i++) {
      unawaited(r.playPattern());
      await t.pump();
      while (r.patternPlaying) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }
    expect(sent, hasLength(30));
    expect(r.patternRefusal, isNull, reason: 'thirty is allowed');
    await _show(t, r);
    expect(find.byKey(const ValueKey('pattern-refused')), findsNothing);

    final t0 = await pressPlay(t);
    await until(t, t0, 2500);
    expect(sent, hasLength(30), reason: 'the 31st command was not sent');
    expect(r.patternRefusal, isNotNull);
    final rest = r.patternRestRemaining;
    expect(rest, isNotNull);
    expect(rest!, greaterThan(const Duration(seconds: 5)));
    expect(metroLabel(t), 'metronome idle', reason: 'stopped on the refusal');
    final line = find.byKey(const ValueKey('pattern-refused'));
    expect(line, findsOneWidget);
    int secondsShown() {
      final text = t.widget<Text>(
        find.descendant(of: line, matching: find.byType(Text)).first,
      );
      final m = RegExp(
        r'^Band resting, ready in (\d+) s',
      ).firstMatch(text.data ?? text.textSpan?.toPlainText() ?? '');
      expect(m, isNotNull, reason: 'the line reads "Band resting, ready in N s"');
      return int.parse(m!.group(1)!);
    }

    final n1 = secondsShown();
    expect(
      (n1 - r.patternRestRemaining!.inSeconds).abs(),
      lessThanOrEqualTo(1),
      reason: 'it shows the remaining rest',
    );
    await until(t, t0, 5500);
    final n2 = secondsShown();
    expect(n2, lessThanOrEqualTo(n1 - 2), reason: 'it counts down: $n1 -> $n2');
    expect(n2, greaterThanOrEqualTo(n1 - 4));

    // Wait the rest out, then a play goes through and the line goes.
    while (r.patternRestRemaining != null &&
        r.patternRestRemaining! > Duration.zero) {
      await t.pump(const Duration(milliseconds: 250));
    }
    await t.pump(const Duration(seconds: 1));
    final t1 = await pressPlay(t);
    await until(t, t1, 2500);
    expect(sent.length, greaterThan(30), reason: 'the band was asked again');
    for (var i = 0; i < 400 && r.patternPlaying; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(r.patternRefusal, isNull);
    expect(find.byKey(const ValueKey('pattern-refused')), findsNothing);
    await _finish(t, r);
    h.dispose();
  });

  // ---- 8AB E: the limit display, blurred until tapped -------------------------

  final limit = find.byKey(const ValueKey('pattern-limit'));

  /// One play of the one-command test 8, run out in fake time.
  Future<void> playOnce(WidgetTester t, HardwareProbeRunner r) async {
    unawaited(r.playPattern());
    await t.pump();
    for (var i = 0; i < 100 && r.patternPlaying; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(r.patternPlaying, isFalse);
  }

  /// The runner of a page on the one-command test with [plays] plays behind it.
  Future<HardwareProbeRunner> openWithPlays(WidgetTester t, int plays) async {
    _view(t, _tall);
    final r = _runner(DeviceLabLog(), quickEnd: true);
    await r.openPattern();
    r.patternTest(8);
    for (var i = 0; i < plays; i++) {
      await playOnce(t, r);
    }
    await _show(t, r);
    return r;
  }

  /// The blur's sigma on the limit display, null when it is not blurred.
  double? limitBlur(WidgetTester t) {
    final f = find.descendant(of: limit, matching: find.byType(ImageFiltered));
    if (f.evaluate().isEmpty) return null;
    final m = RegExp(r'blur\(([\d.]+)')
        .firstMatch(t.widget<ImageFiltered>(f.first).imageFilter.toString());
    expect(m, isNotNull, reason: 'a blur filter');
    return double.parse(m!.group(1)!);
  }

  /// The colour of the Text [data] on the page.
  Color? textColour(WidgetTester t, String data) =>
      t.widget<Text>(find.text(data)).style?.color;

  testWidgets('the limit display says 30 of 30 left with nothing in the '
      'window, and no countdown', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    expect(limit, findsOneWidget);
    expect(find.text('30 of 30 left'), findsOneWidget);
    expect(find.textContaining('next in'), findsNothing);
    await _finish(t, r);
    h.dispose();
  });

  testWidgets('it is blurred by default, with a blur too strong to read, and '
      'says so', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    expect(limitBlur(t), isNotNull, reason: 'blurred');
    expect(limitBlur(t)!, greaterThanOrEqualTo(4));
    expect(t.getSemantics(limit).label, 'limit display, blurred');
    await _finish(t, r);
    h.dispose();
  });

  testWidgets('a tap toggles the blur and the semantics label', (t) async {
    final h = t.ensureSemantics();
    final r = await _open(t, DeviceLabLog());
    await t.tap(limit);
    await t.pump(const Duration(milliseconds: 400));
    expect(limitBlur(t), isNull, reason: 'unblurred after a tap');
    final open = t.getSemantics(limit).label;
    expect(open, contains('limit display'));
    expect(open, isNot(contains('blurred')));
    expect(find.text('30 of 30 left'), findsOneWidget);
    await t.tap(limit);
    await t.pump(const Duration(milliseconds: 400));
    expect(limitBlur(t), greaterThanOrEqualTo(4), reason: 'blurred again');
    expect(t.getSemantics(limit).label, 'limit display, blurred');
    await _finish(t, r);
    h.dispose();
  });

  testWidgets('after a play it shows the commands left and a next-free '
      'countdown that runs down once a second', (t) async {
    final r = await openWithPlays(t, 1);
    expect(find.text('29 of 30 left'), findsOneWidget);
    int secondsLeft() {
      final m = RegExp(r'^next in (\d+):(\d\d)$').firstMatch(
        t.widgetList<Text>(find.textContaining('next in')).single.data ?? '',
      );
      expect(m, isNotNull, reason: 'next in m:ss');
      return int.parse(m!.group(1)!) * 60 + int.parse(m.group(2)!);
    }

    final n1 = secondsLeft();
    expect(n1, inInclusiveRange(115, 120), reason: 'the 2 minute window');
    await t.pump(const Duration(seconds: 10));
    final n2 = secondsLeft();
    expect(n2, inInclusiveRange(n1 - 11, n1 - 9), reason: 'counts down: $n1 $n2');
    await _finish(t, r);
  });

  testWidgets('the count turns red under 5 left, not at 5', (t) async {
    final r = await openWithPlays(t, 25);
    expect(find.text('5 of 30 left'), findsOneWidget);
    final calm = textColour(t, '5 of 30 left');
    expect(calm, isNot(C.red), reason: 'five is not low yet');
    await playOnce(t, r);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('4 of 30 left'), findsOneWidget);
    expect(textColour(t, '4 of 30 left'), C.red);
    await _finish(t, r);
  });

  testWidgets('with none left it says 0 of 30 in red, and the refusal line '
      'under Play is not blurred', (t) async {
    final r = await openWithPlays(t, 30);
    expect(find.text('0 of 30 left'), findsOneWidget);
    expect(textColour(t, '0 of 30 left'), C.red);
    final t0 = await pressPlay(t);
    await until(t, t0, 2500);
    final line = find.byKey(const ValueKey('pattern-refused'));
    expect(line, findsOneWidget);
    expect(
      find.ancestor(of: line, matching: find.byType(ImageFiltered)),
      findsNothing,
      reason: 'the refusal stays readable',
    );
    expect(limitBlur(t), isNotNull, reason: 'the limit display is still blurred');
    await _finish(t, r);
  });

  // 8AD, spec E: "Tap what you felt" fills the active rendition from taps.
  // Contracts: the button is keyed `pattern-tap-baseline` and is part of the
  // footer area (it must not push any footer control off a 360x640 screen); its
  // semantics label contains "Tap what you felt". With entries in the active
  // rendition an AlertDialog (Replace / Cancel) asks first; then a pad keyed
  // `pattern-tap-pad` (text "Tap your pattern"; press, hold, release) takes the
  // rhythm, closes 2 s after the last release and the active rendition becomes
  // notesFromTaps(take), with the cursor on the empty slot after it. Taps carry
  // no pressure, so the notes are `*` (8AF.6): unrated, and the page waits for
  // a dynamic per note before leaving the test.
  // The runner logs "Pattern probe: test N rendition A from taps: <code>".
  group('8AD tap a baseline', () {
    const baseline = ValueKey('pattern-tap-baseline');
    const pad = ValueKey('pattern-tap-pad');

    // Two half-second holds with a 125 ms release gap: N4* R1 N4*.
    Future<void> takeHolds(WidgetTester t) async {
      final at = t.getCenter(find.byKey(pad));
      final a = await t.startGesture(at, pointer: 1);
      await t.pump(const Duration(milliseconds: 500));
      await a.up();
      await t.pump(const Duration(milliseconds: 125));
      final b = await t.startGesture(at, pointer: 2);
      await t.pump(const Duration(milliseconds: 500));
      await b.up();
      await t.pump(const Duration(milliseconds: 2100));
      await t.pumpAndSettle();
    }

    Finder inDialog(String text) => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(text),
    );

    testWidgets('the button is there and says what it does', (t) async {
      final r = await _open(t, DeviceLabLog());
      expect(find.byKey(baseline), findsOneWidget);
      expect(t.getSemantics(find.byKey(baseline)).label,
          contains('Tap what you felt'));
      expect(find.byKey(pad), findsNothing);
      r.closePattern();
    });

    testWidgets('the footer stays fully on screen at 360x640 with the '
        'button in', (t) async {
      final r = await _open(t, DeviceLabLog(), size: const Size(360, 640));
      for (var i = 0; i < 32; i++) {
        r.patternTap(_lens[i % 4]);
      }
      await t.pump(const Duration(milliseconds: 600));
      final screen = Offset.zero & const Size(360, 640);
      for (final k in [
        'pattern-tap-baseline',
        for (final n in _lens) 'pattern-len-$n',
        'pattern-dot',
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
      expect(find.byKey(const ValueKey('pattern-wheel')), findsOneWidget);
      r.closePattern();
    });

    testWidgets('on an empty rendition: no question, a pad, then the notes',
        (t) async {
      final r = await _open(t, DeviceLabLog());
      await _tapKey(t, 'pattern-tap-baseline');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(pad), findsOneWidget);
      expect(find.text('Tap your pattern'), findsOneWidget);
      await takeHolds(t);
      expect(find.byKey(pad), findsNothing, reason: 'the pad closed');
      final s = r.pattern!;
      expect(s.rendition(0, 0).code, 'N4* R1 N4*');
      expect(s.rendition(0, 1).code, '', reason: 'B is untouched');
      expect(s.cursor, 3, reason: 'on the empty slot after the take');
      expect(s.nextIsNote, isFalse, reason: 'the toggle follows the last note');
      // The wheel shows them.
      await _tapKey(t, 'pattern-len-2');
      expect(s.rendition(0, 0).code, 'N4* R1 N4* R2');
      r.closePattern();
    });

    testWidgets('it fills the ACTIVE rendition, B, and leaves A', (t) async {
      final r = await _open(t, DeviceLabLog());
      await _tapKey(t, 'pattern-len-1');
      await _tapKey(t, 'pattern-rendition-b');
      await _tapKey(t, 'pattern-tap-baseline');
      await takeHolds(t);
      final s = r.pattern!;
      expect(s.rendition(0, 1).code, 'N4* R1 N4*');
      expect(s.rendition(0, 0).code, 'N1mf');
      expect(s.activeRendition, 1);
      r.closePattern();
    });

    testWidgets('with entries it asks first; Cancel changes nothing and '
        'opens no pad', (t) async {
      final r = await _open(t, DeviceLabLog());
      await _tapKey(t, 'pattern-len-2');
      await _tapKey(t, 'pattern-tap-baseline');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byKey(pad), findsNothing);
      await t.tap(inDialog('Cancel'));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(pad), findsNothing);
      expect(r.pattern!.rendition(0, 0).code, 'N2mf');
      r.closePattern();
    });

    testWidgets('with entries, Replace opens the pad and the take replaces '
        'them', (t) async {
      final r = await _open(t, DeviceLabLog());
      await _tapKey(t, 'pattern-len-2');
      await _tapKey(t, 'pattern-tap-baseline');
      await t.tap(inDialog('Replace'));
      await t.pumpAndSettle();
      expect(find.byKey(pad), findsOneWidget);
      expect(r.pattern!.rendition(0, 0).code, 'N2mf',
          reason: 'not replaced before there is a take');
      await takeHolds(t);
      expect(r.pattern!.rendition(0, 0).code, 'N4* R1 N4*');
      r.closePattern();
    });

    testWidgets('a take is unrated: a hint shows and the test cannot be left '
        'until every * note has a dynamic', (t) async {
      final r = await _open(t, DeviceLabLog());
      await _tapKey(t, 'pattern-tap-baseline');
      await takeHolds(t);
      final hint = find.byKey(const ValueKey('pattern-unrated-hint'));
      expect(hint, findsOneWidget);
      final s = r.pattern!;
      expect(s.unratedNotes(0), 2);
      // The page's Next does nothing while unrated.
      await _tapKey(t, 'pattern-next');
      expect(s.testIndex, 0);
      // Rate both notes: move the cursor onto each and tap a dynamic.
      s.cursor = 0;
      await _tapKey(t, 'pattern-dyn-f');
      s.cursor = 2;
      await _tapKey(t, 'pattern-dyn-p');
      await t.pump();
      expect(s.rendition(0, 0).code, 'N4f R1 N4p');
      expect(s.unratedNotes(0), 0);
      expect(hint, findsNothing);
      await _tapKey(t, 'pattern-next');
      expect(s.testIndex, 1, reason: 'rated: the test can be left');
      r.closePattern();
    });

    testWidgets('left unrated at close, the log carries the * and the heard '
        'log reads it as unrated', (t) async {
      final lab = DeviceLabLog();
      final r = await _open(t, lab);
      await _tapKey(t, 'pattern-tap-baseline');
      await takeHolds(t);
      r.closePattern();
      final heard = lab.steps.where((l) => l.contains('Pattern probe heard 1/40'));
      expect(heard, hasLength(1));
      expect(heard.single, contains('(N4* R1 N4*)'));
      final parsed = parseHeardLines(heard.single);
      expect(parsed.single.unrated, isTrue);
    });

    testWidgets('the lab log says which test and rendition came from taps',
        (t) async {
      final lab = DeviceLabLog();
      final r = await _open(t, lab);
      r.patternTest(2);
      await t.pump(const Duration(milliseconds: 400));
      await _tapKey(t, 'pattern-rendition-b');
      await _tapKey(t, 'pattern-tap-baseline');
      await takeHolds(t);
      r.closePattern();
      expect(
        lab.steps.where((l) => l.contains(
            'Pattern probe: test 3 rendition B from taps: N4* R1 N4*')),
        hasLength(1),
      );
      expect(lab.steps.join('\n'), contains('Pattern probe heard 3/40'));
    });
  });

  // ---- 8AF.5: the probe records what is felt, never "any" ---------------------

  testWidgets('the probe offers six dynamics and no * button', (t) async {
    final r = await _open(t, DeviceLabLog());
    for (final d in _dyns) {
      expect(find.byKey(ValueKey('pattern-dyn-$d')), findsOneWidget, reason: d);
    }
    expect(find.byKey(const ValueKey('pattern-dyn-any')), findsNothing);
    expect(find.text('*'), findsNothing);
    await _finish(t, r);
  });
}
