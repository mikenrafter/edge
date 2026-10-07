// HapticScore: a pattern as a one-line music score. Widget behaviour, the
// clef logo asset, the pattern rows that show it, and the gallery.

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

  group('the clef is the app logo', () {
    testWidgets('an SVG sits where the clef would be, before the staff',
        (t) async {
      await _pump(t, _seq('N4mf R4 N4mf'));
      expect(_clef, findsOneWidget);
      expect(find.descendant(of: _clef, matching: find.byType(SvgPicture)),
          findsOneWidget);
      expect(t.getTopLeft(_clef).dx, lessThan(t.getTopLeft(_staff).dx));
    });

    test('the asset path is one constant, an svg under assets/brand', () {
      expect(kClefLogoAsset, 'assets/brand/clef_logo.svg');
    });

    test('the placeholder file exists and the folder is a declared asset', () {
      expect(File(kClefLogoAsset).existsSync(), isTrue,
          reason: 'the logo placeholder must be committed at $kClefLogoAsset');
      final head = File(kClefLogoAsset).readAsStringSync();
      expect(head, contains('<svg'));
      expect(File('pubspec.yaml').readAsStringSync(),
          contains('- assets/brand/'),
          reason: 'a folder under assets/ is bundled only when listed');
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
