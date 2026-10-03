// 8Y: the pattern probe's transcriber. The wearer taps buttons of length 1-4;
// entries alternate buzz, gap, buzz, gap... (the first is a buzz). This file
// pins the pure model: PatternTranscript (an immutable list of lengths) and
// PatternEntrySession (which test, which of two renditions, the cursor in the
// list, how often the test was played, and the lines for the lab log).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probes.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';

PatternTranscript _of(List<int> lengths) {
  var t = PatternTranscript(const []);
  for (final l in lengths) {
    t = t.append(l);
  }
  return t;
}

PatternEntrySession _session([int tests = 3]) =>
    PatternEntrySession(PatternProbe.defaultTests.take(tests).toList());

void main() {
  group('PatternTranscript', () {
    test('an empty transcript has no code and no prose', () {
      final t = PatternTranscript(const []);
      expect(t.lengths, isEmpty);
      expect(t.code, '');
      expect(t.prose, '');
    });

    test('entries alternate buzz, gap, buzz, gap; the first is a buzz', () {
      final t = _of([2, 1, 4, 3]);
      expect(
        [for (var i = 0; i < 4; i++) t.isBuzz(i)],
        [true, false, true, false],
      );
    });

    test('code and prose name the types and lengths in order', () {
      final t = _of([2, 1, 4]);
      expect(t.lengths, [2, 1, 4]);
      expect(t.code, 'B2 G1 B4');
      expect(t.prose, 'buzz 2, gap 1, buzz 4');
      expect(_of([3]).code, 'B3');
      expect(_of([3]).prose, 'buzz 3');
    });

    test('append returns a new transcript and leaves the old one alone', () {
      final a = PatternTranscript(const []);
      final b = a.append(2);
      expect(a.lengths, isEmpty);
      expect(b.lengths, [2]);
      expect(b.append(1).lengths, [2, 1]);
      expect(b.lengths, [2]);
    });

    test('the lengths list cannot be changed from outside', () {
      final t = _of([2, 1]);
      expect(() => t.lengths.add(3), throwsUnsupportedError);
      expect(() => t.lengths[0] = 3, throwsUnsupportedError);
      final source = [2, 1];
      final u = PatternTranscript(source);
      source[0] = 4;
      expect(u.lengths, [2, 1], reason: 'it keeps its own copy');
    });

    test('replaceAt changes one entry and keeps the types by position', () {
      final t = _of([2, 1, 4]);
      final r = t.replaceAt(1, 3);
      expect(r.code, 'B2 G3 B4');
      expect(t.code, 'B2 G1 B4', reason: 'the original is unchanged');
    });

    test('removeAt drops an entry; the entries after it change type', () {
      final t = _of([2, 1, 4]);
      expect(t.removeAt(2).code, 'B2 G1');
      expect(t.removeAt(1).code, 'B2 G4');
      expect(t.removeAt(0).code, 'B1 G4');
      expect(t.code, 'B2 G1 B4', reason: 'the original is unchanged');
    });

    test('there is room for 24 entries and a 25th is ignored', () {
      expect(PatternTranscript.maxEntries, 24);
      var t = PatternTranscript(const []);
      for (var i = 0; i < 24; i++) {
        t = t.append(1 + i % 4);
      }
      expect(t.lengths, hasLength(24));
      final full = t.append(4);
      expect(full.lengths, t.lengths);
    });

    test('a length outside 1 to 4 is an ArgumentError', () {
      final t = _of([2, 1]);
      for (final bad in [0, 5, -1, 99]) {
        expect(() => t.append(bad), throwsArgumentError, reason: 'append $bad');
        expect(
          () => t.replaceAt(0, bad),
          throwsArgumentError,
          reason: 'replaceAt $bad',
        );
      }
      for (final ok in [1, 2, 3, 4]) {
        expect(t.append(ok).lengths.last, ok);
        expect(t.replaceAt(0, ok).lengths.first, ok);
      }
    });
  });

  group('PatternEntrySession: moving between tests', () {
    test('starts at the first test, rendition A, an empty list, no plays', () {
      final s = _session();
      expect(s.testIndex, 0);
      expect(s.activeRendition, 0);
      expect(s.cursor, 0);
      for (var t = 0; t < 3; t++) {
        expect(s.plays(t), 0);
        expect(s.rendition(t, 0).lengths, isEmpty);
        expect(s.rendition(t, 1).lengths, isEmpty);
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
      expect(s.rendition(0, 0).code, 'B2 G1');
      expect(s.rendition(0, 1).code, 'B4');
      expect(s.rendition(1, 0).code, 'B3 G3 B3');
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
      expect(s.rendition(0, 0).code, 'B2 G1 B4');
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
      expect(s.rendition(0, 0).code, 'B2 G3 B4');
      expect(s.cursor, 2);
      s.tap(1);
      expect(s.rendition(0, 0).code, 'B2 G3 B1');
      expect(s.cursor, 3, reason: 'replacing the last entry lands on the end');
      s.tap(2);
      expect(s.rendition(0, 0).code, 'B2 G3 B1 G2');
    });

    test('delete on an entry removes it; the cursor stays', () {
      final s = _session();
      s.tap(2);
      s.tap(1);
      s.tap(4);
      s.moveCursor(-3);
      expect(s.cursor, 0);
      s.delete();
      expect(s.rendition(0, 0).code, 'B1 G4');
      expect(s.cursor, 0);
      s.moveCursor(1);
      s.delete();
      expect(s.rendition(0, 0).code, 'B1');
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
      expect(s.rendition(0, 0).code, 'B2');
      expect(s.cursor, 1);
    });

    test('delete at the end slot removes the last entry', () {
      final s = _session();
      s.tap(2);
      s.tap(1);
      s.tap(4);
      expect(s.cursor, 3);
      s.delete();
      expect(s.rendition(0, 0).code, 'B2 G1');
      expect(s.cursor, 2);
      s.delete();
      s.delete();
      expect(s.rendition(0, 0).lengths, isEmpty);
      expect(s.cursor, 0);
      s.delete();
      expect(s.rendition(0, 0).lengths, isEmpty, reason: 'nothing to remove');
      expect(s.cursor, 0);
    });

    test('a 25th entry is ignored and the cursor stays on the end slot', () {
      final s = _session();
      for (var i = 0; i < 24; i++) {
        s.tap(1 + i % 4);
      }
      expect(s.cursor, 24);
      s.tap(4);
      expect(s.rendition(0, 0).lengths, hasLength(24));
      expect(s.cursor, 24);
    });

    test('a length outside 1 to 4 is an ArgumentError', () {
      final s = _session();
      expect(() => s.tap(0), throwsArgumentError);
      expect(() => s.tap(5), throwsArgumentError);
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
      expect(s.rendition(0, 0).code, 'B2 G1');
      expect(s.rendition(0, 1).code, 'B3');
      s.selectRendition(0);
      expect(s.activeRendition, 0);
      expect(s.cursor, 2, reason: 'the end of A');
      s.delete();
      expect(s.rendition(0, 0).code, 'B2');
      expect(s.rendition(0, 1).code, 'B3');
    });

    test('the renditions are kept per test', () {
      final s = _session();
      s.tap(2);
      s.selectRendition(1);
      s.tap(4);
      s.goToTest(1);
      s.tap(1);
      expect(s.rendition(0, 0).code, 'B2');
      expect(s.rendition(0, 1).code, 'B4');
      expect(s.rendition(1, 0).code, 'B1');
      expect(s.rendition(1, 1).lengths, isEmpty);
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

  group('PatternEntrySession: the lab log lines', () {
    test('nothing entered and nothing played gives no lines', () {
      expect(_session().logLines(), isEmpty);
    });

    test('one line per test with a transcript or a play; an empty rendition '
        'is a dash', () {
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
      expect(lines, hasLength(1));
      expect(
        lines.single,
        matches(
          RegExp(
            '^${RegExp.escape('Pattern probe heard 5/40, '
            '${tests[4].description}: A = buzz 2, gap 1, buzz 4 '
            '(B2 G1 B4); B = —')} ?; played 3×\\.\$',
          ),
        ),
      );
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
      expect(lines, hasLength(2));
      expect(lines[0], startsWith('Pattern probe heard 2/40, '));
      expect(lines[0], contains(RegExp(r'A = — ?; B = — ?; played 1×\.$')));
      expect(lines[1], startsWith('Pattern probe heard 8/40, '));
      expect(lines[1], contains('A = buzz 1 (B1); B = buzz 3, gap 2 (B3 G2)'));
      expect(lines[1], contains('played 0×'));
    });
  });
}
