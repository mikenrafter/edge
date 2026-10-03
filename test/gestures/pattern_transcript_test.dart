// 8Y/8Z/8AA: the pattern probe's transcriber. The wearer taps buttons of
// length 1, 2, 4, 6 or 8 sixteenths (16th, eighth, quarter, dotted quarter,
// half); 8AB adds the dotted eighth (3) and dotted half (12), written with a
// one-shot Dot toggle. 8Z types every entry explicitly as a note or a rest (two notes or two
// rests may sit next to each other) and adds a Note/Rest toggle that flips
// after every tap and can be overridden. 8AA makes the unit a sixteenth and
// gives every note a dynamic (ff, mf, mp, pp; rests have none). This file pins
// the pure model: PatternEntry, PatternTranscript (an immutable list of typed
// entries) and PatternEntrySession (which test, which of two renditions, the
// cursor, the toggle, the sticky dynamic, how often the test was played, the
// tempo fitted from measured plays and the lines for the lab log).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probes.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';

/// "N2mf R1 N4ff" as entries: a note has its dynamic after the length, a rest
/// has none.
List<PatternEntry> _entries(String code) => [
      for (final p in code.split(' ').where((p) => p.isNotEmpty))
        if (p[0] == 'N')
          PatternEntry(
            note: true,
            length: int.parse(p.substring(1, p.length - 2)),
            dynamic: PatternDynamic.values.byName(p.substring(p.length - 2)),
          )
        else
          PatternEntry(note: false, length: int.parse(p.substring(1))),
    ];

PatternTranscript _of(String code) => PatternTranscript(_entries(code));

PatternEntrySession _session([int tests = 3]) =>
    PatternEntrySession(PatternProbe.defaultTests.take(tests).toList());

/// Enter [code] at the cursor of the open rendition, flipping the toggle
/// where the code asks for a type other than the one it shows and setting the
/// sticky dynamic for each note.
void _enter(PatternEntrySession s, String code) {
  final before = s.nextDynamic;
  for (final e in _entries(code)) {
    if (s.nextIsNote != e.note) s.toggleKind();
    if (e.note) s.nextDynamic = e.dynamic!;
    s.tap(e.length);
  }
  s.nextDynamic = before;
}

/// Enter [code] in rendition A of [test] and note [ms] as its measured span.
void _measured(PatternEntrySession s, int test, String code, int ms) {
  s.goToTest(test);
  _enter(s, code);
  s.noteMeasured(test, ms);
}

void main() {
  group('the lengths and dynamics', () {
    test('a length is 1, 2, 3, 4, 6, 8 or 12 sixteenths (8AB adds the dotted '
        'eighth and the dotted half)', () {
      expect(kPatternLengths, [1, 2, 3, 4, 6, 8, 12]);
    });

    test('the dynamics run from loudest to softest: ff, mf, mp, pp', () {
      expect(PatternDynamic.values, [
        PatternDynamic.ff,
        PatternDynamic.mf,
        PatternDynamic.mp,
        PatternDynamic.pp,
      ]);
      expect([for (final d in PatternDynamic.values) d.name], [
        'ff',
        'mf',
        'mp',
        'pp',
      ]);
    });
  });

  group('PatternEntry', () {
    test('holds a type, a length and a dynamic and compares by value', () {
      const a = PatternEntry(
        note: true,
        length: 2,
        dynamic: PatternDynamic.mf,
      );
      expect(a.note, isTrue);
      expect(a.length, 2);
      expect(a.dynamic, PatternDynamic.mf);
      const same = PatternEntry(
        note: true,
        length: 2,
        dynamic: PatternDynamic.mf,
      );
      expect(a, same);
      expect(a.hashCode, same.hashCode);
      expect(
        a,
        isNot(
          const PatternEntry(
            note: true,
            length: 2,
            dynamic: PatternDynamic.ff,
          ),
        ),
        reason: 'the dynamic is part of the value',
      );
      expect(
        a,
        isNot(
          const PatternEntry(
            note: true,
            length: 4,
            dynamic: PatternDynamic.mf,
          ),
        ),
      );
      expect(a, isNot(const PatternEntry(note: false, length: 2)));
    });

    test('a rest has no dynamic and compares by type and length', () {
      const r = PatternEntry(note: false, length: 4);
      expect(r.note, isFalse);
      expect(r.dynamic, isNull);
      expect(r, const PatternEntry(note: false, length: 4));
      expect(r.hashCode, const PatternEntry(note: false, length: 4).hashCode);
      expect(r, isNot(const PatternEntry(note: false, length: 2)));
    });

    test('the dynamic is part of the hash: two dynamics differ', () {
      final hashes = {
        for (final d in PatternDynamic.values)
          PatternEntry(note: true, length: 2, dynamic: d).hashCode,
      };
      expect(hashes, hasLength(4));
    });
  });

  group('PatternTranscript', () {
    test('an empty transcript has no code and no prose', () {
      final t = PatternTranscript(const []);
      expect(t.entries, isEmpty);
      expect(t.length, 0);
      expect(t.code, '');
      expect(t.prose, '');
    });

    test('code names the type, length and dynamic; a rest has no dynamic', () {
      final t = _of('N4mf R2 N1ff');
      expect(t.length, 3);
      expect(t.entries, _entries('N4mf R2 N1ff'));
      expect(t.code, 'N4mf R2 N1ff');
      expect(_of('N6pp').code, 'N6pp');
      expect(_of('N8mp').code, 'N8mp');
      expect(_of('R1').code, 'R1');
    });

    test('prose names the length, the type and the dynamic', () {
      expect(
        _of('N4mf R2 N1ff').prose,
        'quarter note mf, eighth rest, 16th note ff',
      );
      expect(_of('N6pp').prose, 'dotted quarter note pp');
      expect(_of('N8mp').prose, 'half note mp');
      expect(_of('R6').prose, 'dotted quarter rest');
      expect(_of('R8').prose, 'half rest');
      expect(_of('R1').prose, '16th rest');
      expect(_of('N3mf').prose, 'dotted eighth note mf');
      expect(_of('R3').prose, 'dotted eighth rest');
      expect(_of('N12pp').prose, 'dotted half note pp');
      expect(_of('R12').prose, 'dotted half rest');
      expect(_of('N12pp').code, 'N12pp');
      expect(_of('R3').code, 'R3');
      expect(_of('N2ff').prose, 'eighth note ff');
      expect(_of('R4').prose, 'quarter rest');
    });

    test('two notes or two rests may sit next to each other', () {
      final t = _of('N1mf N1ff N2pp R6 R1 N4mp');
      expect(t.code, 'N1mf N1ff N2pp R6 R1 N4mp');
      expect(
        t.prose,
        '16th note mf, 16th note ff, eighth note pp, dotted quarter rest, '
        '16th rest, quarter note mp',
      );
    });

    test('append returns a new transcript and leaves the old one alone', () {
      final a = PatternTranscript(const []);
      final b = a.append(
        const PatternEntry(note: true, length: 2, dynamic: PatternDynamic.mf),
      );
      expect(a.entries, isEmpty);
      expect(b.code, 'N2mf');
      expect(
        b
            .append(
              const PatternEntry(
                note: true,
                length: 1,
                dynamic: PatternDynamic.pp,
              ),
            )
            .code,
        'N2mf N1pp',
      );
      expect(b.code, 'N2mf');
    });

    test('the entries list cannot be changed from outside', () {
      final t = _of('N2mf R1');
      expect(
        () => t.entries.add(
          const PatternEntry(
            note: true,
            length: 6,
            dynamic: PatternDynamic.mf,
          ),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => t.entries[0] = const PatternEntry(
          note: true,
          length: 6,
          dynamic: PatternDynamic.mf,
        ),
        throwsUnsupportedError,
      );
      final source = _entries('N2mf R1');
      final u = PatternTranscript(source);
      source[0] = const PatternEntry(
        note: true,
        length: 4,
        dynamic: PatternDynamic.mf,
      );
      expect(u.code, 'N2mf R1', reason: 'it keeps its own copy');
    });

    test('replaceAt changes one entry, type, length and dynamic', () {
      final t = _of('N2mf R1 N4pp');
      expect(
        t.replaceAt(1, const PatternEntry(note: false, length: 6)).code,
        'N2mf R6 N4pp',
      );
      expect(
        t
            .replaceAt(
              1,
              const PatternEntry(
                note: true,
                length: 1,
                dynamic: PatternDynamic.ff,
              ),
            )
            .code,
        'N2mf N1ff N4pp',
        reason: 'the type is part of the entry, not of its position',
      );
      expect(
        t
            .replaceAt(
              2,
              const PatternEntry(
                note: true,
                length: 4,
                dynamic: PatternDynamic.mp,
              ),
            )
            .code,
        'N2mf R1 N4mp',
        reason: 'the dynamic can change on its own',
      );
      expect(t.code, 'N2mf R1 N4pp', reason: 'the original is unchanged');
    });

    test('removeAt drops an entry; the others keep their types and '
        'dynamics', () {
      final t = _of('N2ff R1 N4pp');
      expect(t.removeAt(2).code, 'N2ff R1');
      expect(t.removeAt(1).code, 'N2ff N4pp');
      expect(t.removeAt(0).code, 'R1 N4pp');
      expect(t.code, 'N2ff R1 N4pp', reason: 'the original is unchanged');
    });

    test('there is room for 32 entries and a 33rd is ignored', () {
      expect(PatternTranscript.maxEntries, 32);
      var t = PatternTranscript(const []);
      for (var i = 0; i < 32; i++) {
        final len = kPatternLengths[i % kPatternLengths.length];
        t = t.append(
          i.isEven
              ? PatternEntry(
                  note: true,
                  length: len,
                  dynamic: PatternDynamic.mf,
                )
              : PatternEntry(note: false, length: len),
        );
      }
      expect(t.length, 32);
      final full = t.append(
        const PatternEntry(note: true, length: 4, dynamic: PatternDynamic.mf),
      );
      expect(full.entries, t.entries);
    });

    test('a length that is not 1, 2, 3, 4, 6, 8 or 12 is an ArgumentError', () {
      final t = _of('N2mf R1');
      for (final bad in [0, 5, 7, 9, 10, 11, 13, 16, -1, 99]) {
        expect(
          () => t.append(
            PatternEntry(
              note: true,
              length: bad,
              dynamic: PatternDynamic.mf,
            ),
          ),
          throwsArgumentError,
          reason: 'append note $bad',
        );
        expect(
          () => t.append(PatternEntry(note: false, length: bad)),
          throwsArgumentError,
          reason: 'append rest $bad',
        );
        expect(
          () => t.replaceAt(0, PatternEntry(note: false, length: bad)),
          throwsArgumentError,
          reason: 'replaceAt $bad',
        );
      }
      for (final ok in kPatternLengths) {
        expect(
          t.append(PatternEntry(note: false, length: ok)).entries.last.length,
          ok,
        );
        expect(
          t
              .replaceAt(
                0,
                PatternEntry(
                  note: true,
                  length: ok,
                  dynamic: PatternDynamic.mf,
                ),
              )
              .entries
              .first
              .length,
          ok,
        );
      }
    });

    test('a note without a dynamic is an ArgumentError', () {
      final t = _of('N2mf');
      expect(
        () => t.append(const PatternEntry(note: true, length: 2)),
        throwsArgumentError,
      );
      expect(
        () => t.replaceAt(0, const PatternEntry(note: true, length: 2)),
        throwsArgumentError,
      );
    });

    test('a rest with a dynamic is an ArgumentError', () {
      final t = _of('N2mf');
      expect(
        () => t.append(
          const PatternEntry(
            note: false,
            length: 2,
            dynamic: PatternDynamic.mf,
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => t.replaceAt(
          0,
          const PatternEntry(
            note: false,
            length: 2,
            dynamic: PatternDynamic.pp,
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('PatternEntrySession: moving between tests', () {
    test('starts at the first test, rendition A, an empty list, no plays', () {
      final s = _session();
      expect(s.testIndex, 0);
      expect(s.activeRendition, 0);
      expect(s.cursor, 0);
      expect(s.nextIsNote, isTrue, reason: 'it starts on Note');
      expect(s.nextDynamic, PatternDynamic.mf, reason: 'it starts on mf');
      for (var t = 0; t < 3; t++) {
        expect(s.plays(t), 0);
        expect(s.rendition(t, 0).entries, isEmpty);
        expect(s.rendition(t, 1).entries, isEmpty);
      }
    });

    test('next and previous move one test and stop at the ends', () {
      final s = _session();
      s.previousTest();
      expect(s.testIndex, 0);
      s.nextTest();
      s.nextTest();
      expect(s.testIndex, 2);
      s.nextTest();
      expect(s.testIndex, 2);
      s.previousTest();
      expect(s.testIndex, 1);
    });

    test('goToTest clamps to the first and last test', () {
      final s = _session();
      s.goToTest(99);
      expect(s.testIndex, 2);
      s.goToTest(-5);
      expect(s.testIndex, 0);
      s.goToTest(1);
      expect(s.testIndex, 1);
    });

    test('a test change puts the cursor at the end of its transcript, on '
        'rendition A', () {
      final s = _session();
      s.tap(2);
      s.tap(1);
      s.selectRendition(1);
      s.tap(4);
      s.nextTest();
      expect(s.activeRendition, 0);
      expect(s.cursor, 0, reason: 'test 2 is empty');
      s.tap(6);
      s.tap(6);
      s.tap(6);
      s.previousTest();
      expect(s.testIndex, 0);
      expect(s.activeRendition, 0);
      expect(s.cursor, 2, reason: 'the end slot of test 1 rendition A (2)');
      expect(s.rendition(0, 0).code, 'N2mf R1');
      expect(s.rendition(0, 1).code, 'N4mf');
      expect(s.rendition(1, 0).code, 'N6mf R6 N6mf');
    });

    test('goToTest also resets the rendition and moves to the end slot', () {
      final s = _session();
      s.goToTest(2);
      s.tap(1);
      s.tap(2);
      s.selectRendition(1);
      s.goToTest(0);
      s.goToTest(2);
      expect(s.activeRendition, 0);
      expect(s.cursor, 2);
    });
  });

  group('PatternEntrySession: entering and editing', () {
    test('tapping at the end slot appends and moves on', () {
      final s = _session();
      s.tap(2);
      expect(s.cursor, 1);
      s.tap(1);
      s.tap(4);
      expect(s.cursor, 3);
      expect(s.rendition(0, 0).code, 'N2mf R1 N4mf');
    });

    test('every length writes: 16th, eighth, dotted eighth, quarter, dotted '
        'quarter, half, dotted half', () {
      final s = _session();
      for (final len in kPatternLengths) {
        s.tap(len);
      }
      expect(s.rendition(0, 0).code, 'N1mf R2 N3mf R4 N6mf R8 N12mf');
    });

    test('the cursor moves by delta and stays between 0 and the end slot', () {
      final s = _session();
      s.tap(2);
      s.tap(1);
      s.tap(4);
      s.moveCursor(-1);
      expect(s.cursor, 2);
      s.moveCursor(-10);
      expect(s.cursor, 0);
      s.moveCursor(1);
      expect(s.cursor, 1);
      s.moveCursor(10);
      expect(s.cursor, 3);
    });

    test('tapping on an existing entry replaces it and moves on', () {
      final s = _session();
      s.tap(2);
      s.tap(1);
      s.tap(4);
      s.moveCursor(-2);
      expect(s.cursor, 1);
      s.tap(6);
      expect(s.rendition(0, 0).code, 'N2mf R6 N4mf');
      expect(s.cursor, 2);
      s.tap(1);
      expect(s.rendition(0, 0).code, 'N2mf R6 N1mf');
      expect(s.cursor, 3, reason: 'replacing the last entry lands on the end');
      s.tap(2);
      expect(s.rendition(0, 0).code, 'N2mf R6 N1mf R2');
    });

    test('delete on an entry removes it; the cursor stays', () {
      final s = _session();
      s.tap(2);
      s.tap(1);
      s.tap(4);
      s.moveCursor(-3);
      expect(s.cursor, 0);
      s.delete();
      expect(s.rendition(0, 0).code, 'R1 N4mf');
      expect(s.cursor, 0);
      s.moveCursor(1);
      s.delete();
      expect(s.rendition(0, 0).code, 'R1');
      expect(
        s.cursor,
        1,
        reason: 'clamped to the end slot of the shorter list',
      );
    });

    test('delete on the last entry leaves the cursor at the end slot', () {
      final s = _session();
      s.tap(2);
      s.tap(1);
      s.moveCursor(-1);
      expect(s.cursor, 1);
      s.delete();
      expect(s.rendition(0, 0).code, 'N2mf');
      expect(s.cursor, 1);
    });

    test('delete at the end slot removes the last entry', () {
      final s = _session();
      s.tap(2);
      s.tap(1);
      s.tap(4);
      expect(s.cursor, 3);
      s.delete();
      expect(s.rendition(0, 0).code, 'N2mf R1');
      expect(s.cursor, 2);
      s.delete();
      s.delete();
      expect(s.rendition(0, 0).entries, isEmpty);
      expect(s.cursor, 0);
      s.delete();
      expect(s.rendition(0, 0).entries, isEmpty, reason: 'nothing to remove');
      expect(s.cursor, 0);
    });

    test('a 33rd entry is ignored; the cursor and the toggle stay', () {
      final s = _session();
      for (var i = 0; i < 32; i++) {
        s.tap(kPatternLengths[i % kPatternLengths.length]);
      }
      expect(s.cursor, 32);
      final toggle = s.nextIsNote;
      s.tap(4);
      expect(s.rendition(0, 0).length, 32);
      expect(s.cursor, 32);
      expect(s.nextIsNote, toggle);
    });

    test('a length that is not 1, 2, 3, 4, 6, 8 or 12 is an ArgumentError',
        () {
      final s = _session();
      for (final bad in [0, 5, 7, 9, 10, 13]) {
        expect(() => s.tap(bad), throwsArgumentError, reason: 'tap $bad');
      }
      expect(s.rendition(0, 0).entries, isEmpty);
      expect(s.cursor, 0);
    });
  });

  group('PatternEntrySession: the dynamic', () {
    test('a tap writes a note with the sticky dynamic and a rest with none',
        () {
      final s = _session();
      s.nextDynamic = PatternDynamic.ff;
      s.tap(2);
      s.tap(2);
      s.tap(2);
      expect(s.rendition(0, 0).code, 'N2ff R2 N2ff');
      expect(s.rendition(0, 0).entries[1].dynamic, isNull);
    });

    test('the dynamic stays after a tap and after a rest', () {
      final s = _session();
      s.setDynamic(PatternDynamic.pp);
      s.tap(1);
      expect(s.nextDynamic, PatternDynamic.pp);
      s.tap(1);
      expect(s.nextDynamic, PatternDynamic.pp);
      s.tap(1);
      expect(s.rendition(0, 0).code, 'N1pp R1 N1pp');
    });

    test('setDynamic at the end slot sets the sticky dynamic for the next '
        'notes and changes nothing entered', () {
      final s = _session();
      _enter(s, 'N2mf R1');
      expect(s.cursor, 2);
      s.setDynamic(PatternDynamic.ff);
      expect(s.nextDynamic, PatternDynamic.ff);
      expect(s.rendition(0, 0).code, 'N2mf R1');
      expect(s.cursor, 2);
      s.tap(4);
      expect(s.rendition(0, 0).code, 'N2mf R1 N4ff');
    });

    test('setDynamic with the cursor on a note changes that note and the '
        'sticky dynamic; the cursor stays', () {
      final s = _session();
      _enter(s, 'N2mf R1 N4mf');
      s.moveCursor(-3);
      expect(s.cursor, 0);
      s.setDynamic(PatternDynamic.pp);
      expect(s.rendition(0, 0).code, 'N2pp R1 N4mf');
      expect(s.cursor, 0);
      expect(s.nextDynamic, PatternDynamic.pp);
      s.moveCursor(2);
      expect(s.cursor, 2);
      s.setDynamic(PatternDynamic.mp);
      expect(s.rendition(0, 0).code, 'N2pp R1 N4mp');
      expect(s.cursor, 2);
      expect(s.nextDynamic, PatternDynamic.mp);
    });

    test('setDynamic changes only the note under the cursor, not the other '
        'rendition or test', () {
      final s = _session();
      _enter(s, 'N2mf N4mf');
      s.selectRendition(1);
      _enter(s, 'N2mf');
      s.selectRendition(0);
      s.moveCursor(-1);
      s.setDynamic(PatternDynamic.ff);
      expect(s.rendition(0, 0).code, 'N2mf N4ff');
      expect(s.rendition(0, 1).code, 'N2mf');
      s.goToTest(1);
      expect(s.rendition(1, 0).entries, isEmpty);
    });

    test('setDynamic keeps the length and the type of the note it changes',
        () {
      final s = _session();
      _enter(s, 'N6mf');
      s.moveCursor(-1);
      s.setDynamic(PatternDynamic.ff);
      final e = s.rendition(0, 0).entries.single;
      expect(e.note, isTrue);
      expect(e.length, 6);
      expect(e.dynamic, PatternDynamic.ff);
    });

    test('setDynamic with the cursor on a rest only sets the sticky '
        'dynamic; the rest stays a rest', () {
      final s = _session();
      _enter(s, 'N2mf R1 N4mf');
      s.moveCursor(-2);
      expect(s.cursor, 1);
      s.setDynamic(PatternDynamic.pp);
      expect(s.rendition(0, 0).code, 'N2mf R1 N4mf');
      expect(s.rendition(0, 0).entries[1].dynamic, isNull);
      expect(s.nextDynamic, PatternDynamic.pp);
      expect(s.cursor, 1);
    });

    test('setDynamic on an empty list only sets the sticky dynamic', () {
      final s = _session();
      s.setDynamic(PatternDynamic.mp);
      expect(s.nextDynamic, PatternDynamic.mp);
      expect(s.rendition(0, 0).entries, isEmpty);
    });

    test('setDynamic does not touch the Note/Rest toggle', () {
      final s = _session();
      _enter(s, 'N2mf R1 N4mf');
      s.moveCursor(-3);
      final toggle = s.nextIsNote;
      s.setDynamic(PatternDynamic.ff);
      expect(s.nextIsNote, toggle);
      s.toggleKind();
      s.setDynamic(PatternDynamic.pp);
      expect(s.nextIsNote, !toggle, reason: 'a manual override survives');
    });

    test('tapping on an existing entry writes the sticky dynamic into a '
        'replaced note and none into a note replaced by a rest', () {
      final s = _session();
      _enter(s, 'N2ff N4ff');
      s.moveCursor(-2);
      s.setDynamic(PatternDynamic.pp);
      expect(s.rendition(0, 0).code, 'N2pp N4ff');
      s.tap(1);
      expect(s.rendition(0, 0).code, 'N1pp N4ff');
      expect(s.nextIsNote, isFalse, reason: 'it flips after the tap');
      s.tap(2);
      expect(s.rendition(0, 0).code, 'N1pp R2', reason: 'a rest has none');
    });

    test('moving the cursor leaves the sticky dynamic alone', () {
      final s = _session();
      _enter(s, 'N2ff N4pp');
      s.setDynamic(PatternDynamic.mp);
      expect(s.rendition(0, 0).code, 'N2ff N4pp', reason: 'end slot: no edit');
      s.moveCursor(-2);
      expect(s.nextDynamic, PatternDynamic.mp);
      s.moveCursor(1);
      expect(s.nextDynamic, PatternDynamic.mp);
      expect(s.rendition(0, 0).code, 'N2ff N4pp');
    });

    test('the sticky dynamic carries over to another test and rendition', () {
      final s = _session();
      s.setDynamic(PatternDynamic.ff);
      s.selectRendition(1);
      expect(s.nextDynamic, PatternDynamic.ff);
      s.nextTest();
      expect(s.nextDynamic, PatternDynamic.ff);
      s.tap(2);
      expect(s.rendition(1, 0).code, 'N2ff');
    });
  });

  group('PatternEntrySession: the Note/Rest toggle', () {
    test('it flips after every tap: note, rest, note, rest', () {
      final s = _session();
      expect(s.nextIsNote, isTrue);
      s.tap(2);
      expect(s.nextIsNote, isFalse);
      s.tap(1);
      expect(s.nextIsNote, isTrue);
      s.tap(1);
      expect(s.nextIsNote, isFalse);
      s.tap(6);
      expect(s.nextIsNote, isTrue);
      expect(s.rendition(0, 0).code, 'N2mf R1 N1mf R6');
    });

    test('a tap writes an entry of the toggle\'s type', () {
      final s = _session();
      s.toggleKind();
      expect(s.nextIsNote, isFalse);
      s.tap(2);
      expect(s.rendition(0, 0).code, 'R2', reason: 'a first entry can be a rest');
    });

    test('toggleKind flips it, and twice flips it back', () {
      final s = _session();
      s.toggleKind();
      expect(s.nextIsNote, isFalse);
      s.toggleKind();
      expect(s.nextIsNote, isTrue);
    });

    test('toggleKind overrides the next entry: two rests or two notes in a '
        'row, then it alternates again', () {
      final s = _session();
      s.tap(1);
      expect(s.nextIsNote, isFalse);
      s.toggleKind();
      expect(s.nextIsNote, isTrue);
      s.tap(1);
      expect(s.rendition(0, 0).code, 'N1mf N1mf');
      expect(s.nextIsNote, isFalse, reason: 'after the override it flips');
      s.tap(2);
      s.toggleKind();
      s.tap(6);
      expect(s.rendition(0, 0).code, 'N1mf N1mf R2 R6');
      expect(s.nextIsNote, isTrue);
    });

    test('moving the cursor sets it to the opposite of the entry before the '
        'cursor; Note when there is none', () {
      final s = _session();
      _enter(s, 'N2mf R1 N4mf');
      expect(s.nextIsNote, isFalse, reason: 'after a note at the end');
      s.moveCursor(-1);
      expect(s.cursor, 2);
      expect(s.nextIsNote, isTrue, reason: 'R1 is before the cursor');
      s.moveCursor(-1);
      expect(s.cursor, 1);
      expect(s.nextIsNote, isFalse, reason: 'N2 is before the cursor');
      s.moveCursor(-1);
      expect(s.cursor, 0);
      expect(s.nextIsNote, isTrue, reason: 'nothing before the cursor');
      s.moveCursor(10);
      expect(s.cursor, 3);
      expect(s.nextIsNote, isFalse);
    });

    test('moving the cursor drops a manual override', () {
      final s = _session();
      _enter(s, 'N2mf R1');
      s.toggleKind();
      expect(s.nextIsNote, isFalse);
      s.moveCursor(-1);
      s.moveCursor(1);
      expect(s.nextIsNote, isTrue, reason: 'R1 is before the cursor again');
    });

    test('next to adjacent entries the toggle follows the one just before '
        'the cursor', () {
      final s = _session();
      _enter(s, 'N1mf R1');
      s.toggleKind();
      s.tap(1);
      s.toggleKind();
      s.tap(1);
      expect(s.rendition(0, 0).code, 'N1mf R1 R1 R1');
      s.moveCursor(-1);
      expect(s.nextIsNote, isTrue, reason: 'a rest is before cursor 3');
      s.moveCursor(-2);
      expect(s.cursor, 1);
      expect(s.nextIsNote, isFalse, reason: 'a note is before cursor 1');
    });

    test('replacing an entry writes the toggle\'s type, whatever was there',
        () {
      final s = _session();
      _enter(s, 'N2mf R1 N4mf');
      s.moveCursor(-2);
      s.toggleKind();
      expect(s.nextIsNote, isTrue, reason: 'it was Rest after the note');
      s.tap(6);
      expect(s.rendition(0, 0).code, 'N2mf N6mf N4mf');
      expect(s.nextIsNote, isFalse);
    });

    test('changing the rendition sets it from the entry before the end of '
        'that rendition', () {
      final s = _session();
      s.tap(2);
      expect(s.nextIsNote, isFalse);
      s.selectRendition(1);
      expect(s.nextIsNote, isTrue, reason: 'B is empty');
      s.tap(1);
      s.tap(1);
      expect(s.nextIsNote, isTrue);
      s.selectRendition(0);
      expect(s.nextIsNote, isFalse, reason: 'A ends with a note');
      s.selectRendition(1);
      expect(s.rendition(0, 1).code, 'N1mf R1');
      expect(s.nextIsNote, isTrue, reason: 'B ends with a rest');
    });

    test('changing the test sets it from the entry before the end slot', () {
      final s = _session();
      s.tap(2);
      s.tap(1);
      s.toggleKind();
      s.goToTest(1);
      expect(s.nextIsNote, isTrue, reason: 'test 2 is empty');
      s.tap(2);
      expect(s.nextIsNote, isFalse);
      s.goToTest(0);
      expect(s.rendition(0, 0).code, 'N2mf R1');
      expect(s.nextIsNote, isTrue, reason: 'test 1 ends with a rest');
      s.nextTest();
      expect(s.nextIsNote, isFalse, reason: 'test 2 ends with a note');
      s.previousTest();
      expect(s.nextIsNote, isTrue);
    });
  });

  group('PatternEntrySession: two renditions', () {
    test('selecting B moves the cursor to the end of B and edits go to B', () {
      final s = _session();
      s.tap(2);
      s.tap(1);
      s.selectRendition(1);
      expect(s.activeRendition, 1);
      expect(s.cursor, 0);
      s.tap(6);
      expect(s.rendition(0, 0).code, 'N2mf R1');
      expect(s.rendition(0, 1).code, 'N6mf');
      s.selectRendition(0);
      expect(s.activeRendition, 0);
      expect(s.cursor, 2, reason: 'the end of A');
      s.delete();
      expect(s.rendition(0, 0).code, 'N2mf');
      expect(s.rendition(0, 1).code, 'N6mf');
    });

    test('the renditions are kept per test', () {
      final s = _session();
      s.tap(2);
      s.selectRendition(1);
      s.tap(4);
      s.goToTest(1);
      s.tap(1);
      expect(s.rendition(0, 0).code, 'N2mf');
      expect(s.rendition(0, 1).code, 'N4mf');
      expect(s.rendition(1, 0).code, 'N1mf');
      expect(s.rendition(1, 1).entries, isEmpty);
    });
  });

  group('PatternEntrySession: the dot (8AB)', () {
    test('the dot starts off', () {
      expect(_session().dotNext, isFalse);
    });

    test('toggleDot flips it on and off', () {
      final s = _session();
      s.toggleDot();
      expect(s.dotNext, isTrue);
      s.toggleDot();
      expect(s.dotNext, isFalse);
    });

    test('with the dot on, a tap writes 3/2 of its length and clears the dot: '
        '1 eighth to 3 sixteenths, 1 quarter to 3 eighths, a half to a '
        'dotted half', () {
      final s = _session();
      s.toggleDot();
      s.tap(2);
      expect(s.dotNext, isFalse, reason: 'one-shot');
      s.toggleDot();
      s.tap(4);
      s.toggleDot();
      s.tap(8);
      expect(s.rendition(0, 0).code, 'N3mf R6 N12mf');
      expect(s.rendition(0, 0).prose,
          'dotted eighth note mf, dotted quarter rest, dotted half note mf');
    });

    test('the tap after a dotted one is not dotted', () {
      final s = _session();
      s.toggleDot();
      s.tap(2);
      s.tap(2);
      expect(s.rendition(0, 0).code, 'N3mf R2');
    });

    test('a dotted tap moves the cursor and the Note/Rest toggle like any '
        'other', () {
      final s = _session();
      s.toggleDot();
      s.tap(4);
      expect(s.cursor, 1);
      expect(s.nextIsNote, isFalse);
      s.tap(2);
      expect(s.rendition(0, 0).code, 'N6mf R2');
    });

    test('a dotted tap on an existing entry replaces it', () {
      final s = _session();
      s.tap(2);
      s.tap(1);
      s.moveCursor(-2);
      s.toggleDot();
      s.tap(2);
      expect(s.rendition(0, 0).code, 'N3mf R1');
      expect(s.cursor, 1);
    });

    test('a dotted note takes the sticky dynamic, a dotted rest has none', () {
      final s = _session();
      s.nextDynamic = PatternDynamic.pp;
      s.toggleDot();
      s.tap(4);
      s.toggleDot();
      s.tap(4);
      expect(s.rendition(0, 0).code, 'N6pp R6');
    });

    test('a 16th cannot be dotted: tap(1) with the dot on is an '
        'ArgumentError and writes nothing', () {
      final s = _session();
      s.tap(2);
      s.toggleDot();
      expect(() => s.tap(1), throwsArgumentError);
      expect(s.rendition(0, 0).code, 'N2mf');
      expect(s.cursor, 1);
      expect(s.nextIsNote, isFalse, reason: 'the toggle did not flip');
      expect(s.dotNext, isTrue, reason: 'nothing happened, so the dot stays');
    });

    test('a length that has no dotted form (3, 6, 12) is an ArgumentError '
        'with the dot on', () {
      for (final len in [3, 6, 12]) {
        final s = _session();
        s.toggleDot();
        expect(() => s.tap(len), throwsArgumentError, reason: 'tap($len)');
        expect(s.rendition(0, 0).length, 0);
      }
    });

    test('tap(3), tap(6) and tap(12) without the dot write those lengths', () {
      final s = _session();
      s.tap(3);
      s.tap(6);
      s.tap(12);
      expect(s.rendition(0, 0).code, 'N3mf R6 N12mf');
    });

    test('a dotted tap at 32 entries writes nothing and keeps the cursor', () {
      final s = _session();
      for (var i = 0; i < 32; i++) {
        s.tap(1);
      }
      s.toggleDot();
      s.tap(2);
      expect(s.rendition(0, 0).length, 32);
      expect(s.rendition(0, 0).entries.last.length, 1);
    });

    test('the dotted lengths march in sixteenths: a dotted quarter is 6 '
        'units', () {
      final s = _session();
      s.toggleDot();
      s.tap(4);
      s.tap(2);
      final m = PatternEntrySession.march(s.rendition(0, 0), 100, 300);
      expect(m.map((e) => (e.startMs, e.endMs)), [(300, 900), (900, 1100)]);
    });
  });

  group('PatternEntrySession: plays', () {
    test('notePlayed counts a play for the current test only', () {
      final s = _session();
      s.notePlayed();
      s.notePlayed();
      s.nextTest();
      s.notePlayed();
      expect(s.plays(0), 2);
      expect(s.plays(1), 1);
      expect(s.plays(2), 0);
    });
  });

  group('PatternEntrySession: the tempo', () {
    test('a unit is a sixteenth of 125 ms by default, and dynamic tempo '
        'starts on', () {
      expect(PatternEntrySession.defaultUnitMs, 125);
      final s = _session();
      expect(s.dynamicTempo, isTrue);
      expect(s.fittedUnitMs(), isNull);
      expect(s.unitMs, 125);
    });

    test('fewer than two measured tests gives no fit', () {
      final s = _session();
      expect(s.fittedUnitMs(), isNull);
      _measured(s, 0, 'N2mf R1 N1mf', 1200);
      expect(s.fittedUnitMs(), isNull, reason: 'one test is not enough');
      s.noteMeasured(1, 1200);
      expect(s.fittedUnitMs(), isNull, reason: 'test 2 has no transcript');
      s.noteMeasured(0, 1200);
      expect(s.fittedUnitMs(), isNull, reason: 'a repeat is still one test');
    });

    test('a test with a transcript but no measured span does not count', () {
      final s = _session();
      _measured(s, 0, 'N2mf R1 N1mf', 1200);
      s.goToTest(1);
      _enter(s, 'N2mf R1 N1mf');
      expect(s.fittedUnitMs(), isNull);
    });

    test('ms per unit is the span over the units up to the last note; the '
        'median of two tests that agree is that value', () {
      final s = _session();
      _measured(s, 0, 'N2mf R1 N1mf', 1200);
      _measured(s, 1, 'N4mf', 1200);
      expect(s.fittedUnitMs(), 300);
    });

    test('trailing rests are not counted as units', () {
      final s = _session();
      _measured(s, 0, 'N2mf R1 N1mf R4 R4', 1200);
      _measured(s, 1, 'N2mf R1 N1mf', 1200);
      expect(s.fittedUnitMs(), 300);
    });

    test('rests between notes are counted', () {
      final s = _session();
      _measured(s, 0, 'N1mf R4 N1mf', 1800);
      _measured(s, 1, 'N1mf R4 N1mf', 1800);
      expect(s.fittedUnitMs(), 300);
    });

    test('the dynamics do not change the units', () {
      final s = _session();
      _measured(s, 0, 'N2ff R1 N1pp', 1200);
      _measured(s, 1, 'N4mp', 1200);
      expect(s.fittedUnitMs(), 300);
    });

    test('a transcript of rests only does not count as a test', () {
      final s = _session();
      _measured(s, 0, 'R2', 5000);
      _measured(s, 1, 'N2mf', 600);
      expect(s.fittedUnitMs(), isNull, reason: 'only one usable test');
      _measured(s, 2, 'N2mf', 600);
      expect(s.fittedUnitMs(), 300);
    });

    test('when A and B are both entered their unit counts are averaged', () {
      final s = _session();
      s.goToTest(0);
      _enter(s, 'N4mf');
      s.selectRendition(1);
      _enter(s, 'N2mf');
      s.noteMeasured(0, 900);
      _measured(s, 1, 'N6mf', 1800);
      expect(s.fittedUnitMs(), 300, reason: '(4 + 2) / 2 = 3 units: 300 ms');
    });

    test('a test with only rendition B entered uses B', () {
      final s = _session();
      s.goToTest(0);
      s.selectRendition(1);
      _enter(s, 'N2mf');
      s.noteMeasured(0, 600);
      _measured(s, 1, 'N2mf', 600);
      expect(s.fittedUnitMs(), 300);
    });

    test('the median is taken over the tests', () {
      final s = _session();
      _measured(s, 0, 'N2mf', 400);
      _measured(s, 1, 'N2mf', 600);
      _measured(s, 2, 'N2mf', 1800);
      expect(s.fittedUnitMs(), 300, reason: '200, 300, 900: the middle one');
    });

    test('the median of an even number of tests is the mean of the middle '
        'two', () {
      final s = _session();
      _measured(s, 0, 'N2mf', 400);
      _measured(s, 1, 'N2mf', 800);
      expect(s.fittedUnitMs(), 300, reason: '200 and 400');
    });

    test('a newer measured span for a test replaces the older', () {
      final s = _session();
      _measured(s, 0, 'N2mf', 4000);
      _measured(s, 1, 'N2mf', 600);
      s.noteMeasured(0, 600);
      expect(s.fittedUnitMs(), 300);
    });

    test('the fit is clamped to 50 to 400 ms', () {
      final fast = _session();
      _measured(fast, 0, 'N1mf', 20);
      _measured(fast, 1, 'N1mf', 20);
      expect(fast.fittedUnitMs(), 50);
      final slow = _session();
      _measured(slow, 0, 'N1mf', 5000);
      _measured(slow, 1, 'N1mf', 5000);
      expect(slow.fittedUnitMs(), 400);
    });

    test('a fit inside 50 to 400 ms is not clamped, including a sixteenth '
        'tempo below the old 100 ms floor', () {
      final quick = _session();
      _measured(quick, 0, 'N1mf', 70);
      _measured(quick, 1, 'N1mf', 70);
      expect(quick.fittedUnitMs(), 70);
      final edge = _session();
      _measured(edge, 0, 'N1mf', 400);
      _measured(edge, 1, 'N1mf', 400);
      expect(edge.fittedUnitMs(), 400);
    });

    test('unitMs is the fit when dynamic tempo is on and 125 when it is off '
        'or there is no fit', () {
      final s = _session();
      expect(s.unitMs, 125);
      _measured(s, 0, 'N2mf', 600);
      expect(s.unitMs, 125, reason: 'no fit from one test');
      _measured(s, 1, 'N2mf', 600);
      expect(s.fittedUnitMs(), 300);
      expect(s.unitMs, 300);
      s.dynamicTempo = false;
      expect(s.unitMs, 125, reason: 'dynamic tempo off: the fixed default');
      expect(s.fittedUnitMs(), 300, reason: 'the fit itself is still known');
      s.dynamicTempo = true;
      expect(s.unitMs, 300);
    });
  });

  group('PatternEntrySession: the Bluetooth lead', () {
    // The lead is the delay from a play's first write landing to the band
    // starting (its event 60), measured per play.
    test('it is 300 ms until a play has been measured', () {
      expect(PatternEntrySession.defaultLeadMs, 300);
      expect(_session().leadMs, 300);
    });

    test('one measured lead is the lead', () {
      final s = _session();
      s.noteLead(500);
      expect(s.leadMs, 500);
    });

    test('the lead is the median of all measured leads', () {
      final s = _session();
      s.noteLead(200);
      s.noteLead(1000);
      s.noteLead(400);
      expect(s.leadMs, 400);
    });

    test('the median of an even number of leads is the mean of the middle '
        'two', () {
      final s = _session();
      s.noteLead(200);
      s.noteLead(600);
      expect(s.leadMs, 400);
    });

    test('leads from every test count, whichever test is open', () {
      final s = _session();
      s.noteLead(100);
      s.nextTest();
      s.noteLead(700);
      s.noteLead(900);
      expect(s.leadMs, 700);
    });

    test('the lead is clamped to 0 to 1500 ms', () {
      final low = _session();
      low.noteLead(-50);
      expect(low.leadMs, 0);
      final high = _session();
      high.noteLead(5000);
      expect(high.leadMs, 1500);
    });
  });

  group('PatternEntrySession.march: the schedule of a replay', () {
    test('entry i starts at the lead plus the units before it and lasts its '
        'length in units', () {
      expect(
        PatternEntrySession.march(_of('N2mf R1 N1ff'), 250, 300),
        [
          (index: 0, startMs: 300, endMs: 800),
          (index: 1, startMs: 800, endMs: 1050),
          (index: 2, startMs: 1050, endMs: 1300),
        ],
      );
    });

    test('rests take their time too, and a zero lead starts at once', () {
      expect(
        PatternEntrySession.march(_of('N1mf N1pp R4 N6mp'), 100, 0),
        [
          (index: 0, startMs: 0, endMs: 100),
          (index: 1, startMs: 100, endMs: 200),
          (index: 2, startMs: 200, endMs: 600),
          (index: 3, startMs: 600, endMs: 1200),
        ],
      );
    });

    test('a half is eight sixteenths long', () {
      expect(
        PatternEntrySession.march(_of('N8mf'), 125, 0),
        [(index: 0, startMs: 0, endMs: 1000)],
      );
    });

    test('an empty transcript has nothing to march through', () {
      expect(PatternEntrySession.march(_of(''), 250, 300), isEmpty);
    });

    test('the entries follow each other without gaps', () {
      final steps = PatternEntrySession.march(
        _of('N4mf R2 R6 N1ff N2pp'),
        180,
        450,
      );
      expect(steps.first.startMs, 450);
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i].startMs, steps[i - 1].endMs);
        expect(steps[i].index, i);
      }
      expect(steps.last.endMs, 450 + 180 * 15);
    });
  });

  group('PatternEntrySession: the lab log lines', () {
    test('nothing entered and nothing played gives no lines', () {
      expect(_session().logLines(), isEmpty);
    });

    test('one line per test with a transcript or a play, then the tempo '
        'line; an empty rendition is a dash', () {
      final tests = PatternProbe.defaultTests;
      final s = PatternEntrySession(tests);
      s.goToTest(4);
      s.tap(2);
      s.tap(1);
      s.tap(4);
      s.notePlayed();
      s.notePlayed();
      s.notePlayed();
      final lines = s.logLines();
      expect(lines, hasLength(2));
      expect(
        lines.first,
        'Pattern probe heard 5/40, ${tests[4].description}: '
        'A = eighth note mf, 16th rest, quarter note mf (N2mf R1 N4mf); '
        'B = —; played 3×.',
      );
      expect(lines.last, startsWith('Pattern probe tempo: '));
    });

    test('both renditions are written; tests in order, skipping untouched '
        'ones', () {
      final tests = PatternProbe.defaultTests;
      final s = PatternEntrySession(tests);
      s.goToTest(7);
      s.tap(1);
      s.selectRendition(1);
      s.tap(6);
      s.tap(2);
      s.goToTest(1);
      s.notePlayed();
      final lines = s.logLines();
      expect(lines, hasLength(3));
      expect(lines[0], startsWith('Pattern probe heard 2/40, '));
      expect(lines[0], contains(RegExp(r'A = — ?; B = — ?; played 1×\.$')));
      expect(lines[1], startsWith('Pattern probe heard 8/40, '));
      expect(
        lines[1],
        contains('A = 16th note mf (N1mf); '
            'B = dotted quarter note mf, eighth rest (N6mf R2)'),
      );
      expect(lines[1], contains('played 0×'));
      expect(lines[2], startsWith('Pattern probe tempo: '));
    });

    test('every dynamic is written in the code and the prose', () {
      final s = _session();
      _enter(s, 'N1ff N2mf N4mp N6pp N8ff');
      expect(
        s.logLines().first,
        contains('A = 16th note ff, eighth note mf, quarter note mp, '
            'dotted quarter note pp, half note ff '
            '(N1ff N2mf N4mp N6pp N8ff)'),
      );
    });

    test('rests are written as rests, adjacent ones too', () {
      final s = _session();
      _enter(s, 'N2mf R1 N4mf R4 R4');
      expect(
        s.logLines().first,
        contains('A = eighth note mf, 16th rest, quarter note mf, '
            'quarter rest, quarter rest (N2mf R1 N4mf R4 R4)'),
      );
    });

    test('the tempo line says the unit is fixed when there is no fit', () {
      final s = _session();
      s.tap(2);
      final line = s.logLines().last;
      expect(line, startsWith('Pattern probe tempo: '));
      expect(line, contains('1 sixteenth ≈ 125 ms (fixed)'));
    });

    test('the tempo line names the fit and how many tests it came from', () {
      final s = _session();
      _measured(s, 0, 'N2mf', 600);
      _measured(s, 1, 'N2mf', 600);
      final line = s.logLines().last;
      expect(line, startsWith('Pattern probe tempo: '));
      expect(line, contains('1 sixteenth ≈ 300 ms (fitted from 2 tests)'));
      _measured(s, 2, 'N1mf R1 N1mf', 900);
      expect(
        s.logLines().last,
        contains('1 sixteenth ≈ 300 ms (fitted from 3 tests)'),
      );
    });

    test('with dynamic tempo off the tempo line is the fixed default', () {
      final s = _session();
      _measured(s, 0, 'N2mf', 600);
      _measured(s, 1, 'N2mf', 600);
      s.dynamicTempo = false;
      expect(
        s.logLines().last,
        contains('1 sixteenth ≈ 125 ms (fixed)'),
      );
    });
  });
}
