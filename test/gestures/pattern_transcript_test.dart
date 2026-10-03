// 8Y/8Z: the pattern probe's transcriber. The wearer taps buttons of length
// 1-4. 8Z types every entry explicitly as a note or a rest (two notes or two
// rests may sit next to each other) and adds a Note/Rest toggle that flips
// after every tap and can be overridden. This file pins the pure model:
// PatternEntry, PatternTranscript (an immutable list of typed entries) and
// PatternEntrySession (which test, which of two renditions, the cursor, the
// toggle, how often the test was played, the tempo fitted from measured plays
// and the lines for the lab log).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probes.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';

/// "N2 R1 N4" as entries.
List<PatternEntry> _entries(String code) => [
      for (final p in code.split(' ').where((p) => p.isNotEmpty))
        PatternEntry(note: p[0] == 'N', length: int.parse(p.substring(1))),
    ];

PatternTranscript _of(String code) => PatternTranscript(_entries(code));

PatternEntrySession _session([int tests = 3]) =>
    PatternEntrySession(PatternProbe.defaultTests.take(tests).toList());

/// Enter [code] at the cursor of the open rendition, flipping the toggle
/// where the code asks for a type other than the one it shows.
void _enter(PatternEntrySession s, String code) {
  for (final e in _entries(code)) {
    if (s.nextIsNote != e.note) s.toggleKind();
    s.tap(e.length);
  }
}

/// Enter [code] in rendition A of [test] and note [ms] as its measured span.
void _measured(PatternEntrySession s, int test, String code, int ms) {
  s.goToTest(test);
  _enter(s, code);
  s.noteMeasured(test, ms);
}

void main() {
  group('PatternEntry', () {
    test('holds a type and a length and compares by value', () {
      const a = PatternEntry(note: true, length: 2);
      expect(a.note, isTrue);
      expect(a.length, 2);
      expect(a, const PatternEntry(note: true, length: 2));
      expect(a.hashCode, const PatternEntry(note: true, length: 2).hashCode);
      expect(a, isNot(const PatternEntry(note: false, length: 2)));
      expect(a, isNot(const PatternEntry(note: true, length: 3)));
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

    test('code and prose name the types and lengths in order', () {
      final t = _of('N2 R1 N4 R4 R4');
      expect(t.length, 5);
      expect(t.entries, _entries('N2 R1 N4 R4 R4'));
      expect(t.code, 'N2 R1 N4 R4 R4');
      expect(t.prose, 'note 2, rest 1, note 4, rest 4, rest 4');
      expect(_of('N3').code, 'N3');
      expect(_of('N3').prose, 'note 3');
      expect(_of('R1').code, 'R1');
      expect(_of('R1').prose, 'rest 1');
    });

    test('two notes or two rests may sit next to each other', () {
      final t = _of('N1 N1 N2 R3 R1 N4');
      expect(t.code, 'N1 N1 N2 R3 R1 N4');
      expect(t.prose, 'note 1, note 1, note 2, rest 3, rest 1, note 4');
    });

    test('append returns a new transcript and leaves the old one alone', () {
      final a = PatternTranscript(const []);
      final b = a.append(const PatternEntry(note: true, length: 2));
      expect(a.entries, isEmpty);
      expect(b.code, 'N2');
      expect(b.append(const PatternEntry(note: true, length: 1)).code, 'N2 N1');
      expect(b.code, 'N2');
    });

    test('the entries list cannot be changed from outside', () {
      final t = _of('N2 R1');
      expect(
        () => t.entries.add(const PatternEntry(note: true, length: 3)),
        throwsUnsupportedError,
      );
      expect(
        () => t.entries[0] = const PatternEntry(note: true, length: 3),
        throwsUnsupportedError,
      );
      final source = _entries('N2 R1');
      final u = PatternTranscript(source);
      source[0] = const PatternEntry(note: true, length: 4);
      expect(u.code, 'N2 R1', reason: 'it keeps its own copy');
    });

    test('replaceAt changes one entry, type and length', () {
      final t = _of('N2 R1 N4');
      expect(
        t.replaceAt(1, const PatternEntry(note: false, length: 3)).code,
        'N2 R3 N4',
      );
      expect(
        t.replaceAt(1, const PatternEntry(note: true, length: 1)).code,
        'N2 N1 N4',
        reason: 'the type is part of the entry, not of its position',
      );
      expect(t.code, 'N2 R1 N4', reason: 'the original is unchanged');
    });

    test('removeAt drops an entry; the others keep their types', () {
      final t = _of('N2 R1 N4');
      expect(t.removeAt(2).code, 'N2 R1');
      expect(t.removeAt(1).code, 'N2 N4');
      expect(t.removeAt(0).code, 'R1 N4');
      expect(t.code, 'N2 R1 N4', reason: 'the original is unchanged');
    });

    test('there is room for 32 entries and a 33rd is ignored', () {
      expect(PatternTranscript.maxEntries, 32);
      var t = PatternTranscript(const []);
      for (var i = 0; i < 32; i++) {
        t = t.append(PatternEntry(note: i.isEven, length: 1 + i % 4));
      }
      expect(t.length, 32);
      final full = t.append(const PatternEntry(note: true, length: 4));
      expect(full.entries, t.entries);
    });

    test('a length outside 1 to 4 is an ArgumentError', () {
      final t = _of('N2 R1');
      for (final bad in [0, 5, -1, 99]) {
        expect(
          () => t.append(PatternEntry(note: true, length: bad)),
          throwsArgumentError,
          reason: 'append $bad',
        );
        expect(
          () => t.replaceAt(0, PatternEntry(note: false, length: bad)),
          throwsArgumentError,
          reason: 'replaceAt $bad',
        );
      }
      for (final ok in [1, 2, 3, 4]) {
        expect(
          t.append(PatternEntry(note: false, length: ok)).entries.last.length,
          ok,
        );
        expect(
          t.replaceAt(0, PatternEntry(note: true, length: ok)).entries.first
              .length,
          ok,
        );
      }
    });
  });

  group('PatternEntrySession: moving between tests', () {
    test('starts at the first test, rendition A, an empty list, no plays', () {
      final s = _session();
      expect(s.testIndex, 0);
      expect(s.activeRendition, 0);
      expect(s.cursor, 0);
      expect(s.nextIsNote, isTrue, reason: 'it starts on Note');
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
      s.tap(3);
      s.tap(3);
      s.tap(3);
      s.previousTest();
      expect(s.testIndex, 0);
      expect(s.activeRendition, 0);
      expect(s.cursor, 2, reason: 'the end slot of test 1 rendition A (2)');
      expect(s.rendition(0, 0).code, 'N2 R1');
      expect(s.rendition(0, 1).code, 'N4');
      expect(s.rendition(1, 0).code, 'N3 R3 N3');
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
      expect(s.rendition(0, 0).code, 'N2 R1 N4');
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
      s.tap(3);
      expect(s.rendition(0, 0).code, 'N2 R3 N4');
      expect(s.cursor, 2);
      s.tap(1);
      expect(s.rendition(0, 0).code, 'N2 R3 N1');
      expect(s.cursor, 3, reason: 'replacing the last entry lands on the end');
      s.tap(2);
      expect(s.rendition(0, 0).code, 'N2 R3 N1 R2');
    });

    test('delete on an entry removes it; the cursor stays', () {
      final s = _session();
      s.tap(2);
      s.tap(1);
      s.tap(4);
      s.moveCursor(-3);
      expect(s.cursor, 0);
      s.delete();
      expect(s.rendition(0, 0).code, 'R1 N4');
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
      expect(s.rendition(0, 0).code, 'N2');
      expect(s.cursor, 1);
    });

    test('delete at the end slot removes the last entry', () {
      final s = _session();
      s.tap(2);
      s.tap(1);
      s.tap(4);
      expect(s.cursor, 3);
      s.delete();
      expect(s.rendition(0, 0).code, 'N2 R1');
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
        s.tap(1 + i % 4);
      }
      expect(s.cursor, 32);
      final toggle = s.nextIsNote;
      s.tap(4);
      expect(s.rendition(0, 0).length, 32);
      expect(s.cursor, 32);
      expect(s.nextIsNote, toggle);
    });

    test('a length outside 1 to 4 is an ArgumentError', () {
      final s = _session();
      expect(() => s.tap(0), throwsArgumentError);
      expect(() => s.tap(5), throwsArgumentError);
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
      s.tap(3);
      expect(s.nextIsNote, isTrue);
      expect(s.rendition(0, 0).code, 'N2 R1 N1 R3');
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
      expect(s.rendition(0, 0).code, 'N1 N1');
      expect(s.nextIsNote, isFalse, reason: 'after the override it flips');
      s.tap(2);
      s.toggleKind();
      s.tap(3);
      expect(s.rendition(0, 0).code, 'N1 N1 R2 R3');
      expect(s.nextIsNote, isTrue);
    });

    test('moving the cursor sets it to the opposite of the entry before the '
        'cursor; Note when there is none', () {
      final s = _session();
      _enter(s, 'N2 R1 N4');
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
      _enter(s, 'N2 R1');
      s.toggleKind();
      expect(s.nextIsNote, isFalse);
      s.moveCursor(-1);
      s.moveCursor(1);
      expect(s.nextIsNote, isTrue, reason: 'R1 is before the cursor again');
    });

    test('next to adjacent entries the toggle follows the one just before '
        'the cursor', () {
      final s = _session();
      _enter(s, 'N1 R1');
      s.toggleKind();
      s.tap(1);
      s.toggleKind();
      s.tap(1);
      expect(s.rendition(0, 0).code, 'N1 R1 R1 R1');
      s.moveCursor(-1);
      expect(s.nextIsNote, isTrue, reason: 'a rest is before cursor 3');
      s.moveCursor(-2);
      expect(s.cursor, 1);
      expect(s.nextIsNote, isFalse, reason: 'a note is before cursor 1');
    });

    test('replacing an entry writes the toggle\'s type, whatever was there',
        () {
      final s = _session();
      _enter(s, 'N2 R1 N4');
      s.moveCursor(-2);
      s.toggleKind();
      expect(s.nextIsNote, isTrue, reason: 'it was Rest after the note');
      s.tap(3);
      expect(s.rendition(0, 0).code, 'N2 N3 N4');
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
      expect(s.rendition(0, 1).code, 'N1 R1');
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
      expect(s.rendition(0, 0).code, 'N2 R1');
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
      s.tap(3);
      expect(s.rendition(0, 0).code, 'N2 R1');
      expect(s.rendition(0, 1).code, 'N3');
      s.selectRendition(0);
      expect(s.activeRendition, 0);
      expect(s.cursor, 2, reason: 'the end of A');
      s.delete();
      expect(s.rendition(0, 0).code, 'N2');
      expect(s.rendition(0, 1).code, 'N3');
    });

    test('the renditions are kept per test', () {
      final s = _session();
      s.tap(2);
      s.selectRendition(1);
      s.tap(4);
      s.goToTest(1);
      s.tap(1);
      expect(s.rendition(0, 0).code, 'N2');
      expect(s.rendition(0, 1).code, 'N4');
      expect(s.rendition(1, 0).code, 'N1');
      expect(s.rendition(1, 1).entries, isEmpty);
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
    test('a unit is 250 ms by default, and dynamic tempo starts on', () {
      expect(PatternEntrySession.defaultUnitMs, 250);
      final s = _session();
      expect(s.dynamicTempo, isTrue);
      expect(s.fittedUnitMs(), isNull);
      expect(s.unitMs, 250);
    });

    test('fewer than two measured tests gives no fit', () {
      final s = _session();
      expect(s.fittedUnitMs(), isNull);
      _measured(s, 0, 'N2 R1 N1', 1200);
      expect(s.fittedUnitMs(), isNull, reason: 'one test is not enough');
      s.noteMeasured(1, 1200);
      expect(s.fittedUnitMs(), isNull, reason: 'test 2 has no transcript');
      s.noteMeasured(0, 1200);
      expect(s.fittedUnitMs(), isNull, reason: 'a repeat is still one test');
    });

    test('a test with a transcript but no measured span does not count', () {
      final s = _session();
      _measured(s, 0, 'N2 R1 N1', 1200);
      s.goToTest(1);
      _enter(s, 'N2 R1 N1');
      expect(s.fittedUnitMs(), isNull);
    });

    test('ms per unit is the span over the units up to the last note; the '
        'median of two tests that agree is that value', () {
      final s = _session();
      _measured(s, 0, 'N2 R1 N1', 1200);
      _measured(s, 1, 'N4', 1200);
      expect(s.fittedUnitMs(), 300);
    });

    test('trailing rests are not counted as units', () {
      final s = _session();
      _measured(s, 0, 'N2 R1 N1 R4 R4', 1200);
      _measured(s, 1, 'N2 R1 N1', 1200);
      expect(s.fittedUnitMs(), 300);
    });

    test('rests between notes are counted', () {
      final s = _session();
      _measured(s, 0, 'N1 R4 N1', 1800);
      _measured(s, 1, 'N1 R4 N1', 1800);
      expect(s.fittedUnitMs(), 300);
    });

    test('a transcript of rests only does not count as a test', () {
      final s = _session();
      _measured(s, 0, 'R2', 5000);
      _measured(s, 1, 'N2', 600);
      expect(s.fittedUnitMs(), isNull, reason: 'only one usable test');
      _measured(s, 2, 'N2', 600);
      expect(s.fittedUnitMs(), 300);
    });

    test('when A and B are both entered their unit counts are averaged', () {
      final s = _session();
      s.goToTest(0);
      _enter(s, 'N4');
      s.selectRendition(1);
      _enter(s, 'N2');
      s.noteMeasured(0, 900);
      _measured(s, 1, 'N3', 900);
      expect(s.fittedUnitMs(), 300, reason: '(4 + 2) / 2 = 3 units: 300 ms');
    });

    test('a test with only rendition B entered uses B', () {
      final s = _session();
      s.goToTest(0);
      s.selectRendition(1);
      _enter(s, 'N2');
      s.noteMeasured(0, 600);
      _measured(s, 1, 'N2', 600);
      expect(s.fittedUnitMs(), 300);
    });

    test('the median is taken over the tests', () {
      final s = _session();
      _measured(s, 0, 'N2', 400);
      _measured(s, 1, 'N2', 600);
      _measured(s, 2, 'N2', 1800);
      expect(s.fittedUnitMs(), 300, reason: '200, 300, 900: the middle one');
    });

    test('the median of an even number of tests is the mean of the middle '
        'two', () {
      final s = _session();
      _measured(s, 0, 'N2', 400);
      _measured(s, 1, 'N2', 800);
      expect(s.fittedUnitMs(), 300, reason: '200 and 400');
    });

    test('a newer measured span for a test replaces the older', () {
      final s = _session();
      _measured(s, 0, 'N2', 4000);
      _measured(s, 1, 'N2', 600);
      s.noteMeasured(0, 600);
      expect(s.fittedUnitMs(), 300);
    });

    test('the fit is clamped to 100 to 800 ms', () {
      final fast = _session();
      _measured(fast, 0, 'N1', 50);
      _measured(fast, 1, 'N1', 50);
      expect(fast.fittedUnitMs(), 100);
      final slow = _session();
      _measured(slow, 0, 'N1', 5000);
      _measured(slow, 1, 'N1', 5000);
      expect(slow.fittedUnitMs(), 800);
    });

    test('unitMs is the fit when dynamic tempo is on and 250 when it is off '
        'or there is no fit', () {
      final s = _session();
      expect(s.unitMs, 250);
      _measured(s, 0, 'N2', 600);
      expect(s.unitMs, 250, reason: 'no fit from one test');
      _measured(s, 1, 'N2', 600);
      expect(s.fittedUnitMs(), 300);
      expect(s.unitMs, 300);
      s.dynamicTempo = false;
      expect(s.unitMs, 250, reason: 'dynamic tempo off: the fixed default');
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
        PatternEntrySession.march(_of('N2 R1 N1'), 250, 300),
        [
          (index: 0, startMs: 300, endMs: 800),
          (index: 1, startMs: 800, endMs: 1050),
          (index: 2, startMs: 1050, endMs: 1300),
        ],
      );
    });

    test('rests take their time too, and a zero lead starts at once', () {
      expect(
        PatternEntrySession.march(_of('N1 N1 R4 N3'), 100, 0),
        [
          (index: 0, startMs: 0, endMs: 100),
          (index: 1, startMs: 100, endMs: 200),
          (index: 2, startMs: 200, endMs: 600),
          (index: 3, startMs: 600, endMs: 900),
        ],
      );
    });

    test('an empty transcript has nothing to march through', () {
      expect(PatternEntrySession.march(_of(''), 250, 300), isEmpty);
    });

    test('the entries follow each other without gaps', () {
      final steps = PatternEntrySession.march(_of('N4 R2 R3 N1 N2'), 180, 450);
      expect(steps.first.startMs, 450);
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i].startMs, steps[i - 1].endMs);
        expect(steps[i].index, i);
      }
      expect(steps.last.endMs, 450 + 180 * 12);
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
        'A = note 2, rest 1, note 4 (N2 R1 N4); B = —; played 3×.',
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
      s.tap(3);
      s.tap(2);
      s.goToTest(1);
      s.notePlayed();
      final lines = s.logLines();
      expect(lines, hasLength(3));
      expect(lines[0], startsWith('Pattern probe heard 2/40, '));
      expect(lines[0], contains(RegExp(r'A = — ?; B = — ?; played 1×\.$')));
      expect(lines[1], startsWith('Pattern probe heard 8/40, '));
      expect(lines[1], contains('A = note 1 (N1); B = note 3, rest 2 (N3 R2)'));
      expect(lines[1], contains('played 0×'));
      expect(lines[2], startsWith('Pattern probe tempo: '));
    });

    test('rests are written as rests, adjacent ones too', () {
      final s = _session();
      _enter(s, 'N2 R1 N4 R4 R4');
      expect(
        s.logLines().first,
        contains('A = note 2, rest 1, note 4, rest 4, rest 4 '
            '(N2 R1 N4 R4 R4)'),
      );
    });

    test('the tempo line says the unit is fixed when there is no fit', () {
      final s = _session();
      s.tap(2);
      final line = s.logLines().last;
      expect(line, startsWith('Pattern probe tempo: '));
      expect(line, contains('1 unit ≈ 250 ms (fixed)'));
    });

    test('the tempo line names the fit and how many tests it came from', () {
      final s = _session();
      _measured(s, 0, 'N2', 600);
      _measured(s, 1, 'N2', 600);
      final line = s.logLines().last;
      expect(line, startsWith('Pattern probe tempo: '));
      expect(line, contains('1 unit ≈ 300 ms (fitted from 2 tests)'));
      _measured(s, 2, 'N1 R1 N1', 900);
      expect(
        s.logLines().last,
        contains('1 unit ≈ 300 ms (fitted from 3 tests)'),
      );
    });

    test('with dynamic tempo off the tempo line is the fixed default', () {
      final s = _session();
      _measured(s, 0, 'N2', 600);
      _measured(s, 1, 'N2', 600);
      s.dynamicTempo = false;
      expect(s.logLines().last, contains('1 unit ≈ 250 ms (fixed)'));
    });
  });
}
