// HapticScore: a pattern as a wrapped three-line music score. Widget
// behaviour (sizes, text scale, pixel density), the "~x.xs" length that stands
// where the clef was, the pattern rows that show it, and the gallery.
//
// The display overhaul: the logo clef is gone from the staff (a text with the
// pattern's length stands there), the staff has three lines and wraps by
// measure; layout geometry is pinned in score_layout_test.dart, colour per
// command in command_colour_test.dart.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/score_layout.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/ui2/haptic_score.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;

import '../../support/haptics_screen_support.dart';

// A pattern whose notes code is [notes]; the taps behind it are not drawn.
BuzzSequence _seq(String notes) =>
    BuzzSequence(const [0], durationsMs: const [125], notes: notes);

Future<void> _pump(WidgetTester t, BuzzSequence s, {double width = 360}) =>
    t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: HapticScore(s)),
        ),
      ),
    ));

final _staff = find.byKey(const ValueKey('haptic-score-staff'));
final _clef = find.byKey(const ValueKey('haptic-score-clef'));

// "~2.0s": a tilde, whole seconds, ONE decimal, an s. Nothing else matches.
final _length = find.byWidgetPredicate(
    (w) => w is Text && RegExp(r'^~\d+\.\ds$').hasMatch(w.data ?? ''),
    description: 'a "~x.xs" length');

ScoreLayout _drawn(WidgetTester t) {
  final paint = t.widget<CustomPaint>(_staff);
  return (paint.painter! as HapticScorePainter).layout;
}

void main() {
  testWidgets('renders a staff for a pattern without an error', (t) async {
    await _pump(t, _seq('N2mf R2 N2mf'));
    expect(find.byType(HapticScore), findsOneWidget);
    expect(_staff, findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('a long pattern in a narrow space still lays out', (t) async {
    await _pump(
      t,
      _seq('N2f R2 N2f R2 N2f R4 N6f R3 N6f R3 N6f R4 N2f R2 N2f R2 N2f'),
      width: 160,
    );
    expect(t.takeException(), isNull);
    expect(_staff, findsOneWidget);
  });

  group('the length stands where the clef was', () {
    testWidgets('no logo is drawn on the staff', (t) async {
      await _pump(t, _seq('N4mf R4 N4mf'));
      expect(_clef, findsNothing);
      expect(find.byType(SvgPicture), findsNothing);
    });

    testWidgets('"~x.xs": the total length, one decimal, tilde first',
        (t) async {
      // 4 + 4 + 8 = 16 sixteenths of 125 ms.
      await _pump(t, _seq('N4mf R4 N8mf'));
      expect(find.text('~2.0s'), findsOneWidget);
      await _pump(t, _seq('N4mf R4 N4mf')); // 12 x 125 ms
      expect(find.text('~1.5s'), findsOneWidget);
      await _pump(t, _seq('N4mf R2 N2mf')); // 8 x 125 ms
      expect(find.text('~1.0s'), findsOneWidget);
    });

    testWidgets('a stored plan\'s recorded runtime wins over the written length',
        (t) async {
      // 12 sixteenths written (1.5 s); the plan is felt for 2.5 s.
      final s = BuzzSequence(const [0, 625],
          durationsMs: const [500, 500],
          notes: 'N4mf R4 N4mf',
          bakedSteps: [
            BakedStep(effects: const [47], loop: 1, delayMs: 0),
            BakedStep(effects: const [47], loop: 1, delayMs: 300),
          ],
          bakedRuntimeMs: 2500);
      await _pump(t, s);
      expect(find.text('~2.5s'), findsOneWidget);
      expect(find.text('~1.5s'), findsNothing);
    });

    testWidgets('it counts the rests at both ends', (t) async {
      await _pump(t, _seq('R4 N4mf R8')); // 16 x 125 ms
      expect(find.text('~2.0s'), findsOneWidget);
    });

    testWidgets('it follows the unit: a sixteenth of 250 ms doubles it',
        (t) async {
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: SizedBox(
              width: 360, child: HapticScore(_seq('N4mf R4 N4mf'), unitMs: 250)),
        ),
      ));
      expect(find.text('~3.0s'), findsOneWidget);
    });

    testWidgets('it is left of the staff, on its first line', (t) async {
      await _pump(t, _seq('N4mf R4 N8mf'));
      final layout = _drawn(t);
      final text = t.getRect(_length);
      final staff = t.getTopLeft(_staff);
      final first = layout.lines.first;
      expect(text.left, greaterThanOrEqualTo(staff.dx - 0.5));
      expect(text.right,
          lessThanOrEqualTo(staff.dx + first.measures.first.x + 0.5),
          reason: 'before the first measure');
      expect(text.center.dy, greaterThanOrEqualTo(staff.dy + first.top - 0.5));
      expect(text.center.dy,
          lessThanOrEqualTo(staff.dy + first.top + layout.metrics.lineHeight));
    });

    testWidgets('once, however many lines the score wraps onto', (t) async {
      final dense = List.filled(6, 'N3mf R1 N3mf R1 N3mf R1 N3mf R1').join(' ');
      await _pump(t, _seq(dense), width: 320);
      expect(_drawn(t).lines.length, greaterThan(1));
      expect(_length, findsOneWidget);
    });
  });

  group('the staff is three lines wrapped by measure', () {
    testWidgets('one painter draws every line; it is the layout of the width',
        (t) async {
      await _pump(t, _seq('N4mf R4 N8mf'), width: 360);
      final l = _drawn(t);
      expect(l.lines, hasLength(1));
      expect(l.lines.single.staffY, hasLength(3));
      expect(l.lines.single.startDoubleBar && l.lines.single.endDoubleBar,
          isTrue);
    });

    testWidgets('the first measure begins after the room kept for the length',
        (t) async {
      await _pump(t, _seq('N4mf R4 N8mf'));
      final l = _drawn(t);
      final text = t.getRect(_length);
      expect(t.getTopLeft(_staff).dx + l.lines.first.measures.first.x,
          greaterThanOrEqualTo(text.right - 0.5),
          reason: 'the start double bar and the notes clear the text');
    });

    testWidgets('a narrower row wraps onto more lines and grows taller',
        (t) async {
      final dense = List.filled(6, 'N3mf R1 N3mf R1 N3mf R1 N3mf R1').join(' ');
      await _pump(t, _seq(dense), width: 600);
      final wide = _drawn(t).lines.length;
      final wideHeight = t.getSize(find.byType(HapticScore)).height;
      await _pump(t, _seq(dense), width: 320);
      expect(_drawn(t).lines.length, greaterThan(wide));
      expect(t.getSize(find.byType(HapticScore)).height,
          greaterThan(wideHeight));
    });
  });

  group('the notes drawn are the notes of the pattern', () {
    int notes(ScoreLayout l) =>
        l.glyphs.where((g) => !g.rest && !g.tiedFromPrev).length;

    testWidgets('three notes and two rests draw three notes', (t) async {
      await _pump(t, _seq('N2mf R2 N2mf R2 N2mf'));
      final l = _drawn(t);
      expect(notes(l), 3);
      expect(l.glyphs.where((g) => g.rest), hasLength(2));
    });

    testWidgets('a tapped rhythm (no notes code) is drawn from its taps',
        (t) async {
      await _pump(
        t,
        BuzzSequence(const [0, 500, 1000], durationsMs: const [125, 125, 125]),
      );
      expect(notes(_drawn(t)), 3);
    });
  });

  group('dynamics are written under the notes', () {
    testWidgets('each dynamic appears once per note that has it', (t) async {
      await _pump(t, _seq('N2mf R2 N2f R2 N2mf'));
      expect(find.text('mf'), findsNWidgets(2));
      expect(find.text('f'), findsOneWidget);
    });

    testWidgets('any loudness writes nothing', (t) async {
      await _pump(t, _seq('N4* R2 N4*'));
      for (final d in ['*', 'ff', 'f', 'mf', 'mp', 'p', 'pp']) {
        expect(find.text(d), findsNothing, reason: d);
      }
    });

    testWidgets('a rest writes no dynamic', (t) async {
      await _pump(t, _seq('N2p R6'));
      expect(find.text('p'), findsOneWidget);
    });
  });

  group('the semantics label says how many notes and how long', () {
    testWidgets('3 notes, 1.5 seconds', (t) async {
      final h = t.ensureSemantics();
      await _pump(t, _seq('N4mf R2 N2mf R2 N2mf')); // 4+2+2+2+2 = 12 x 125 ms
      expect(find.bySemanticsLabel('3 notes, 1.5 seconds'), findsOneWidget);
      h.dispose();
    });

    testWidgets('one note and exactly one second are singular', (t) async {
      final h = t.ensureSemantics();
      await _pump(t, _seq('N8mf'));
      expect(find.bySemanticsLabel('1 note, 1 second'), findsOneWidget);
      h.dispose();
    });

    testWidgets('a fraction keeps up to two decimals', (t) async {
      final h = t.ensureSemantics();
      await _pump(t, _seq('N2mf R2 N2mf')); // 6 x 125 ms
      expect(find.bySemanticsLabel('2 notes, 0.75 seconds'), findsOneWidget);
      h.dispose();
    });

    testWidgets('a whole number of seconds has no decimals', (t) async {
      final h = t.ensureSemantics();
      await _pump(t, _seq('N4mf R4 N8mf')); // 16 x 125 ms = 2 s, 2 notes
      expect(find.bySemanticsLabel('2 notes, 2 seconds'), findsOneWidget);
      h.dispose();
    });
  });

  group('it fits every phone: pixel density and text size', () {
    // The sizes the app runs at, logical px: the narrowest phone and a wide one.
    const widths = [320.0, 600.0];
    const densities = [1.0, 1.5, 2.625];
    const scales = [1.0, 2.0];
    // Long enough to wrap on a phone, with dynamics and a bar-crossing tie.
    final long = [
      'N6mf R2 N2f R2 N2mf R2 N6ff R3 N6mf R3 N6mf R4',
      'N2f R2 N2mf R2 N2f R4 N6mf R2 N3ff R1 N3mf R1 N3mf R1 N3mf R1',
    ].join(' ');

    for (final dpr in densities) {
      for (final scale in scales) {
        for (final w in widths) {
          testWidgets('dpr $dpr, text x$scale, $w px wide', (t) async {
            t.view.devicePixelRatio = dpr;
            t.view.physicalSize = Size(w * dpr, 900 * dpr);
            addTearDown(t.view.reset);
            await t.pumpWidget(MaterialApp(
              theme: buildTheme(Brightness.light),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: w, child: HapticScore(_seq(long))),
                ),
              ),
            ));
            // No overflow, no layout error.
            expect(t.takeException(), isNull);
            // The length is there, once.
            expect(_length, findsOneWidget);

            final box = t.getRect(find.byType(HapticScore));
            expect(box.width, lessThanOrEqualTo(w + 0.01));
            // Nothing clipped: every text, and the staff, inside the widget.
            for (final text in t.widgetList<Text>(
                find.descendant(
                    of: find.byType(HapticScore), matching: find.byType(Text)))) {
              final r = t.getRect(find.byWidget(text));
              expect(r.left, greaterThanOrEqualTo(box.left - 0.5),
                  reason: '"${text.data}" left');
              expect(r.right, lessThanOrEqualTo(box.right + 0.5),
                  reason: '"${text.data}" right');
              expect(r.top, greaterThanOrEqualTo(box.top - 0.5),
                  reason: '"${text.data}" top');
              expect(r.bottom, lessThanOrEqualTo(box.bottom + 0.5),
                  reason: '"${text.data}" bottom');
            }
            final paint = t.getRect(_staff);
            expect(paint.left, greaterThanOrEqualTo(box.left - 0.5));
            expect(paint.right, lessThanOrEqualTo(box.right + 0.5));
            expect(paint.bottom, lessThanOrEqualTo(box.bottom + 0.5));

            // What is painted stays on the canvas.
            final l = _drawn(t);
            expect(l.contentWidth, lessThanOrEqualTo(paint.width + 0.01));
            expect(l.height, lessThanOrEqualTo(paint.height + 0.01));
            for (final g in l.glyphs) {
              expect(g.x + g.width, lessThanOrEqualTo(paint.width + 0.01));
              expect(g.bottom, lessThanOrEqualTo(paint.height + 0.01));
              expect(g.top, greaterThanOrEqualTo(-0.01));
            }
            // And the layout is a pure function of the logical width: the
            // density changes nothing about where things go.
            expect(l.lines, isNotEmpty);
            if (w == 320) {
              expect(l.lines.length, greaterThan(1),
                  reason: 'a long pattern wraps on a phone');
            }
          });
        }
      }
    }

    testWidgets('the layout does not depend on the pixel density', (t) async {
      final seen = <List<double>>[];
      for (final dpr in densities) {
        t.view.devicePixelRatio = dpr;
        t.view.physicalSize = Size(320 * dpr, 900 * dpr);
        await _pump(t, _seq(long), width: 320);
        seen.add([for (final g in _drawn(t).glyphs) g.x]);
      }
      addTearDown(t.view.reset);
      expect(seen[1], seen[0]);
      expect(seen[2], seen[0]);
    });

    testWidgets('the dynamics under the notes stay in the widget at x2',
        (t) async {
      t.view.physicalSize = const Size(320 * 3, 900 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 320, child: HapticScore(_seq(long))),
          ),
        ),
      ));
      final box = t.getRect(find.byType(HapticScore));
      for (final d in ['mf', 'f', 'ff']) {
        for (final e in find.text(d).evaluate()) {
          final r = t.getRect(find.byElementPredicate((x) => x == e));
          expect(box.contains(r.topLeft) && box.contains(r.bottomRight), isTrue,
              reason: '"$d" at $r outside $box');
        }
      }
    });
  });

  group('where patterns are listed', () {
    final mine = userPattern('a', 'Morning nudge');
    final preset = presetPattern('sys.p1', 'One pulse', 'preset.one_pulse');

    testWidgets('a saved pattern\'s row shows its score', (t) async {
      await pumpHub(t, HubCalls(), patterns: [mine, preset], profile: kMg);
      final row = find.byKey(const ValueKey('haptic-pattern:a'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.byType(HapticScore)),
          findsOneWidget);
    });

    testWidgets('a preset\'s row shows its score', (t) async {
      await pumpHub(t, HubCalls(), patterns: [mine, preset], profile: kMg);
      final row = find.byKey(const ValueKey('haptic-pattern:sys.p1'));
      expect(find.descendant(of: row, matching: find.byType(HapticScore)),
          findsOneWidget);
    });

    testWidgets('the row keeps its name and stays tappable', (t) async {
      final c = HubCalls();
      await pumpHub(t, c, patterns: [mine], profile: kMg);
      expect(find.text('Morning nudge'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('haptic-pattern:a')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('haptic-pattern-sheet')), findsOneWidget);
    });
  });

  group('it is a component, so it is in the design system', () {
    test('the barrel exports it and the gallery shows it', () {
      expect(File('lib/ui2/ui2.dart').readAsStringSync(),
          contains("export 'haptic_score.dart';"));
      expect(File('lib/ui2/profile/gallery.dart').readAsStringSync(),
          contains('HapticScore('),
          reason: 'test/ui2_tokens_test.dart: every component is in the gallery');
    });
  });
}
