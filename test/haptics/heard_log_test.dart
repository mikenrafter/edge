// 8AC — the heard-lines reader (spec C2): the OUTPUT side of the pattern
// probe. parseHeardLines turns the "Pattern probe heard N/40, ..." lines of a
// lab log back into transcripts, so the WHOOP MG profile table can be checked
// against what was actually written down. The real fixture is the L6 log,
// docs/hardware/logs/2026-10-03-pattern-probe-L6.txt (fixed tempo, 1 sixteenth
// = 125 ms).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/heard_log.dart';

String _code(List<PatternEntry> es) => es.join(' ');

const _stamp = '03:34:45.545 | tap +932661 ms | last +0 ms | ';

String _line(
  int n,
  String desc,
  String a,
  String b,
  int plays, {
  bool unstable = false,
  int of = 40,
}) =>
    '$_stamp${'Pattern probe heard $n/$of, $desc'}'
    '${unstable ? ', unstable (A and B are the shortest and longest)' : ''}'
    ': A = $a; B = $b; played $plays×.';

void main() {
  group('parseHeardLines on synthetic lines', () {
    test('nothing to read gives nothing', () {
      expect(parseHeardLines(''), isEmpty);
      expect(parseHeardLines('Band events, oldest first\n  Event 100'),
          isEmpty);
    });

    test('reads the test number, description, both renditions and the plays',
        () {
      final r = parseHeardLines(
        _line(
          5,
          'band pair 47+152, 2 commands, each after the band says the last '
              'one ended',
          'dotted eighth note mf, 16th rest, dotted eighth note mf '
              '(N3mf R1 N3mf)',
          'quarter note f (N4f)',
          8,
        ),
      );
      expect(r, hasLength(1));
      final h = r.single;
      expect(h.test, 5);
      expect(
        h.description,
        'band pair 47+152, 2 commands, each after the band says the last '
        'one ended',
      );
      expect(_code(h.a), 'N3mf R1 N3mf');
      expect(_code(h.b), 'N4f');
      expect(h.plays, 8);
      expect(h.unstable, isFalse);
    });

    test('a dash is an empty rendition', () {
      final h = parseHeardLines(
        _line(2, 'effect 47 alone, 2 commands 1.8 s apart',
            'quarter note ff (N4ff)', '—', 3),
      ).single;
      expect(_code(h.a), 'N4ff');
      expect(h.b, isEmpty);
    });

    test('an empty A is empty too', () {
      final h = parseHeardLines(
        _line(3, 'effect 14, 2 commands 1.8 s apart', '—', '—', 1),
      ).single;
      expect(h.a, isEmpty);
      expect(h.b, isEmpty);
      expect(h.plays, 1);
    });

    test('f and p are read', () {
      final h = parseHeardLines(
        _line(3, 'effect 14, 2 commands 1.8 s apart',
            'quarter note f, eighth rest, eighth note p (N4f R2 N2p)', '—', 2),
      ).single;
      expect(_code(h.a), 'N4f R2 N2p');
    });

    test('reads every line in the text, in order, among other lines', () {
      final text = [
        'Some header',
        '$_stamp Pattern probe play: 1/40, whatever',
        _line(1, 'd1', 'eighth note mf (N2mf)', '—', 1),
        _line(2, 'd2', 'quarter note mf (N4mf)', '—', 2),
        '$_stamp Pattern probe tempo: 1 sixteenth ≈ 125 ms (fixed).',
        '',
      ].join('\n');
      final r = parseHeardLines(text);
      expect([for (final h in r) h.test], [1, 2]);
      expect([for (final h in r) h.description], ['d1', 'd2']);
    });

    test('takes the LAST line per test', () {
      final text = [
        _line(7, 'same test', 'eighth note mf (N2mf)', '—', 1),
        _line(8, 'other test', 'quarter note mf (N4mf)', '—', 1),
        _line(7, 'same test', 'quarter note ff (N4ff)',
            'half note ff (N8ff)', 4),
      ].join('\n');
      final r = parseHeardLines(text);
      expect(r, hasLength(2));
      final seven = r.firstWhere((h) => h.test == 7);
      expect(_code(seven.a), 'N4ff');
      expect(_code(seven.b), 'N8ff');
      expect(seven.plays, 4);
      expect(_code(r.firstWhere((h) => h.test == 8).a), 'N4mf');
    });

    test('a line with "unstable" is unstable, and nothing is stripped', () {
      final h = parseHeardLines(
        _line(
          4,
          'effect 1, 2 commands 1.8 s apart',
          '16th note mp, 16th note mp (N1mp N1mp)',
          '16th note mp (N1mp)',
          18,
          unstable: true,
        ),
      ).single;
      expect(h.unstable, isTrue);
      expect(h.description, 'effect 1, 2 commands 1.8 s apart',
          reason: 'the "unstable" words are not part of the description');
      expect(_code(h.a), 'N1mp N1mp');
      expect(_code(h.b), 'N1mp');
      expect(h.plays, 18);
    });

    test('a rendition ending R1 R2 R4 marks the test unstable and the '
        'trailing R1 R2 R4 is stripped from it', () {
      final h = parseHeardLines(
        _line(
          24,
          'effect 1, 3 commands, each after the band says the last one ended',
          '16th note pp, 16th note pp, 16th rest, eighth rest, quarter rest '
              '(N1pp N1pp R1 R2 R4)',
          'quarter rest, 16th note pp, 16th rest, eighth rest, quarter rest '
              '(R4 N1pp R1 R2 R4)',
          11,
        ),
      ).single;
      expect(h.unstable, isTrue);
      expect(_code(h.a), 'N1pp N1pp');
      expect(_code(h.b), 'R4 N1pp');
    });

    test('the flag in one rendition marks the test; the other is untouched',
        () {
      final h = parseHeardLines(
        _line(
          9,
          'd',
          'eighth note mf, quarter rest (N2mf R4)',
          'eighth note mf, 16th rest, eighth rest, quarter rest '
              '(N2mf R1 R2 R4)',
          2,
        ),
      ).single;
      expect(h.unstable, isTrue);
      expect(_code(h.a), 'N2mf R4');
      expect(_code(h.b), 'N2mf');
    });

    test('R1 R2 R4 in the middle, or only some of them at the end, is not '
        'the flag', () {
      final mid = parseHeardLines(
        _line(10, 'd', 'eighth note mf, 16th rest, eighth rest, quarter rest, '
            'eighth note mf (N2mf R1 R2 R4 N2mf)', '—', 1),
      ).single;
      expect(mid.unstable, isFalse);
      expect(_code(mid.a), 'N2mf R1 R2 R4 N2mf');
      final partial = parseHeardLines(
        _line(11, 'd', 'eighth note mf, eighth rest, quarter rest '
            '(N2mf R2 R4)', '—', 1),
      ).single;
      expect(partial.unstable, isFalse);
      expect(_code(partial.a), 'N2mf R2 R4');
      final wrongOrder = parseHeardLines(
        _line(12, 'd', 'eighth note mf, quarter rest, eighth rest, 16th rest '
            '(N2mf R4 R2 R1)', '—', 1),
      ).single;
      expect(wrongOrder.unstable, isFalse);
      expect(_code(wrongOrder.a), 'N2mf R4 R2 R1');
    });

    test('a test with a different total, N/M, still reads', () {
      final h = parseHeardLines(
        _line(3, 'd', 'eighth note mf (N2mf)', '—', 1, of: 12),
      ).single;
      expect(h.test, 3);
    });
  });

  group('the L6 log', () {
    final file = File('docs/hardware/logs/2026-10-03-pattern-probe-L6.txt');
    late final List<HeardTest> heard;
    late final Map<int, HeardTest> byTest;

    setUpAll(() {
      heard = parseHeardLines(file.readAsStringSync());
      byTest = {for (final h in heard) h.test: h};
    });

    test('the fixture is in the repo', () {
      expect(file.existsSync(), isTrue);
    });

    test('has all 40 tests once, with their descriptions', () {
      expect(heard, hasLength(40));
      expect(byTest.keys.toSet(), {for (var i = 1; i <= 40; i++) i});
      for (final (i, t) in kWhoopMgPatternProbeSet.indexed) {
        expect(byTest[i + 1]!.description, t.description, reason: 'test ${i + 1}');
      }
    });

    test('spot checks: tests 1, 14, 16, 33 and 40', () {
      expect(_code(byTest[1]!.a), 'N2mf R2 N2mf R8 N2mf R2 N2mf');
      expect(byTest[1]!.b, isEmpty);
      expect(byTest[1]!.plays, 9);
      expect(_code(byTest[14]!.a), 'N2ff R1 N4ff R3 N3mf');
      expect(_code(byTest[16]!.a), 'N1mp R1 N1pp N1pp R2 N2mp');
      expect(_code(byTest[33]!.a), 'N3mf R4 N3mf');
      expect(_code(byTest[40]!.a), 'N4ff R12 N4ff');
      expect(_code(byTest[40]!.b), 'N4ff R8 R6 N4ff');
      expect(byTest[40]!.plays, 3);
    });

    test('test 24 is unstable, with R1 R2 R4 stripped from A and B', () {
      final h = byTest[24]!;
      expect(h.unstable, isTrue);
      expect(_code(h.a), 'N1pp N1pp R6 N1pp N1pp R6 N1pp N1pp');
      expect(_code(h.b), 'R4 N1pp N1pp R2 N1pp N1pp R2 N1pp N1pp');
      expect(h.plays, 11);
    });

    test('test 24 is the only test the log flags unstable', () {
      expect([
        for (final h in heard)
          if (h.unstable) h.test,
      ], [24]);
    });

    test('no entry anywhere ends with the R1 R2 R4 flag any more', () {
      for (final h in heard) {
        for (final r in [h.a, h.b]) {
          if (r.length < 3) continue;
          final tail = r.sublist(r.length - 3).map((e) => e.toString());
          expect(tail.toList(), isNot(['R1', 'R2', 'R4']), reason: 'test ${h.test}');
        }
      }
    });

    test('the WHOOP MG table agrees with the log for every phrase heard from '
        'one single-command test (loop or listed: 9-16, 25-32)', () {
      final mg = HapticDeviceProfile.whoopMg;
      var checked = 0;
      for (final p in mg.phrases) {
        if (p.sourceTests.length != 1) continue;
        final n = p.sourceTests.single;
        if (!((n >= 9 && n <= 16) || (n >= 25 && n <= 32))) continue;
        final h = byTest[n]!;
        // The documented override (a single 14 is f) only touches buzz14,
        // which is not a single-source phrase, so the compare is exact.
        expect(_code(p.min), _code(h.a), reason: '${p.id} min vs test $n A');
        expect(
          _code(p.max),
          _code(h.b.isEmpty ? h.a : h.b),
          reason: '${p.id} max vs test $n B',
        );
        checked++;
      }
      expect(checked, 16, reason: 'tests 9-16 and 25-32, one phrase each');
    });

    test('the single 14 row matches the log ignoring dynamics (the override '
        'is f where the log says mf or ff): its N3 and N4 are the first '
        'note lengths heard for 14', () {
      final mg = HapticDeviceProfile.whoopMg;
      final p = mg.phrases.firstWhere((p) => p.id == 'buzz14');
      String shape(List<PatternEntry> es) => [
        for (final e in es) '${e.note ? 'N' : 'R'}${e.length}',
      ].join(' ');
      // Heard A/B across the single-14 tests whose renditions are one note.
      final heardShapes = {
        for (final n in p.sourceTests.where((n) => n <= 23))
          if (byTest[n]!.a.isNotEmpty && byTest[n]!.a.first.note)
            shape([byTest[n]!.a.first]),
      };
      expect(heardShapes, containsAll([shape(p.min), shape(p.max)]),
          reason: 'N3 and N4 appear as the first note of 14 renditions');
    });
  });
}
