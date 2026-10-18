// "Tell the time" band gesture action: the encoder, its glyph rendering and the
// band-command count. Pure functions of a local wall-clock time.
//
// The spec (owner's, verbatim intent):
//   Count (default)  the HOUR as N buzzes, N = the real 12-hour clock hour
//                    (1..12; 00:xx and 12:xx are 12). AM hours short, PM long.
//                    A 1 s pause. Then QUARTERS = round(minute / 15) clamped to
//                    0..4 as clicks. :53 is 4 quarters and is NEVER rolled into
//                    the next hour (13:53 is 1 long, pause, 4 clicks). 0
//                    quarters: no clicks and no trailing pause.
//   Binary           the hour as 4 bits MSB first (long = 1, short = 0), a gap
//                    between bits; a 1 s pause; one AM/PM marker (click = AM,
//                    long = PM); a 1 s pause and the quarter clicks.
//   Morse            the hour's decimal digits (dot = short, dash = long,
//                    standard digit codes), a pause between digits (the letter
//                    gap; the element enum has no letter gap, so it is a
//                    pause); a 1 s pause, "A" (.-) or "P" (.--.), a 1 s pause
//                    and the quarter clicks.
//
// Notation below: S short, L long, C click, g gap, P pause.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/time_buzz.dart';

const _sh = TimeBuzzElement.short;
const _lg = TimeBuzzElement.long;
const _ck = TimeBuzzElement.click;
const _g = TimeBuzzElement.gap;
const _ps = TimeBuzzElement.pause;

/// 'L g L P C' -> the elements. Space separated tokens S L C g P.
List<TimeBuzzElement> _e(String s) => [
      for (final t in s.trim().split(RegExp(r'\s+')))
        if (t.isNotEmpty)
          switch (t) {
            'S' => _sh,
            'L' => _lg,
            'C' => _ck,
            'g' => _g,
            'P' => _ps,
            _ => throw ArgumentError('bad token $t'),
          },
    ];

/// [n] copies of [tok] joined by gaps: 'L g L g L'.
String _rep(String tok, int n) => List.filled(n, tok).join(' g ');

/// Quarter clicks, with the pause before them; empty for 0 quarters.
String _quarters(int q) => q == 0 ? '' : ' P ${_rep('C', q)}';

/// A Morse code ('.---') as 'S g L g L g L'.
String _morse(String code) =>
    code.split('').map((c) => c == '.' ? 'S' : 'L').join(' g ');

DateTime _t(int h, int m) => DateTime(2026, 10, 7, h, m);

List<TimeBuzzElement> _count(int h, int m) =>
    encodeTime(_t(h, m), TimeBuzzMode.count);
List<TimeBuzzElement> _binary(int h, int m) =>
    encodeTime(_t(h, m), TimeBuzzMode.binary);
List<TimeBuzzElement> _morseOf(int h, int m) =>
    encodeTime(_t(h, m), TimeBuzzMode.morse);

void main() {
  group('count mode: the examples from the spec', () {
    test('03:00 is 3 short', () {
      expect(_count(3, 0), _e('S g S g S'));
    });

    test('15:07 is 3 long and 0 quarters (no pause, no clicks)', () {
      expect(_count(15, 7), _e('L g L g L'));
    });

    test('15:08 is 3 long, a pause, 1 click', () {
      expect(_count(15, 8), _e('L g L g L P C'));
    });

    test('00:20 is 12 short, a pause, 1 click', () {
      expect(_count(0, 20), _e('${_rep('S', 12)} P C'));
    });

    test('12:44 is 12 long, a pause, 3 clicks', () {
      expect(_count(12, 44), _e('${_rep('L', 12)} P ${_rep('C', 3)}'));
    });

    test('23:59 is 11 long, a pause, 4 clicks', () {
      expect(_count(23, 59), _e('${_rep('L', 11)} P ${_rep('C', 4)}'));
    });

    test('13:53 is 1 long, a pause, 4 clicks: never rolled into 2 o\'clock',
        () {
      expect(_count(13, 53), _e('L P ${_rep('C', 4)}'));
    });
  });

  group('midnight and noon', () {
    test('00:00 is 12 short and nothing else', () {
      expect(_count(0, 0), _e(_rep('S', 12)));
    });

    test('12:00 is 12 long and nothing else', () {
      expect(_count(12, 0), _e(_rep('L', 12)));
    });

    test('00:xx is AM and 12:xx is PM, 12 buzzes either way', () {
      expect(_count(0, 30), _e('${_rep('S', 12)}${_quarters(2)}'));
      expect(_count(12, 30), _e('${_rep('L', 12)}${_quarters(2)}'));
    });

    test('01:00 is 1 short, 13:00 is 1 long', () {
      expect(_count(1, 0), _e('S'));
      expect(_count(13, 0), _e('L'));
    });

    test('11:00 is 11 short, 23:00 is 11 long', () {
      expect(_count(11, 0), _e(_rep('S', 11)));
      expect(_count(23, 0), _e(_rep('L', 11)));
    });
  });

  group('the :53 rule', () {
    test('minute 53 is 4 quarters at every hour of the day and never changes '
        'the hour', () {
      for (var h = 0; h < 24; h++) {
        final n = h % 12 == 0 ? 12 : h % 12;
        final tok = h < 12 ? 'S' : 'L';
        expect(_count(h, 53), _e('${_rep(tok, n)}${_quarters(4)}'),
            reason: 'at $h:53');
        // The hour is the same one a minute-0 time of that hour has.
        expect(_count(h, 53).sublist(0, _count(h, 0).length), _count(h, 0),
            reason: 'at $h:53 the hour part is the hour $h');
      }
    });

    test('every minute from :53 to :59 is 4 quarters, in every mode', () {
      for (var m = 53; m <= 59; m++) {
        for (final mode in TimeBuzzMode.values) {
          final e = encodeTime(_t(14, m), mode);
          expect(e.sublist(e.length - 7), _e(_rep('C', 4)),
              reason: '14:$m in $mode ends in 4 clicks');
        }
      }
    });
  });

  group('quarters: round(minute / 15) clamped to 0..4', () {
    // minute -> quarters at the boundaries (the half-way minutes are 7.5,
    // 22.5, 37.5 and 52.5, so there is no tie to break).
    const table = {
      0: 0, 1: 0, 7: 0, 8: 1, 14: 1, 15: 1, 16: 1, 22: 1, //
      23: 2, 29: 2, 30: 2, 37: 2, 38: 3, 44: 3, 45: 3, 52: 3, //
      53: 4, 54: 4, 59: 4,
    };
    for (final MapEntry(key: minute, value: q) in table.entries) {
      test('minute $minute is $q quarter${q == 1 ? '' : 's'}', () {
        expect(_count(3, minute), _e('${_rep('S', 3)}${_quarters(q)}'));
      });
    }

    test('0 quarters leaves no trailing pause and no clicks', () {
      final e = _count(9, 7);
      expect(e, isNot(contains(_ps)));
      expect(e, isNot(contains(_ck)));
    });

    test('seconds and milliseconds are not read: only hour and minute', () {
      expect(encodeTime(DateTime(2026, 10, 7, 15, 7, 59, 999),
              TimeBuzzMode.count),
          _e('L g L g L'));
      expect(encodeTime(DateTime(2026, 10, 7, 15, 8, 0, 0), TimeBuzzMode.count),
          _e('L g L g L P C'));
    });
  });

  group('binary mode', () {
    // The hour as 4 bits, MSB first.
    const bits = {
      1: '0001', 2: '0010', 3: '0011', 4: '0100', 5: '0101', 6: '0110', //
      7: '0111', 8: '1000', 9: '1001', 10: '1010', 11: '1011', 12: '1100',
    };
    String bitTokens(String b) =>
        b.split('').map((c) => c == '1' ? 'L' : 'S').join(' g ');

    for (final MapEntry(key: hour, value: b) in bits.entries) {
      test('hour $hour is bits $b, then a pause and the AM click', () {
        final h24 = hour % 12; // 12 -> 0: midnight, AM
        expect(_binary(h24, 0), _e('${bitTokens(b)} P C'));
      });
      test('hour $hour PM is bits $b, then a pause and the long PM marker',
          () {
        final h24 = hour % 12 + 12; // 12 -> 12: noon, PM
        expect(_binary(h24, 0), _e('${bitTokens(b)} P L'));
      });
    }

    test('15:08 is 0011, a pause, PM long, a pause, 1 click', () {
      expect(_binary(15, 8), _e('S g S g L g L P L P C'));
    });

    test('03:00 AM with no quarters ends on the AM click, no trailing pause',
        () {
      final e = _binary(3, 0);
      expect(e, _e('S g S g L g L P C'));
      expect(e.last, _ck);
    });

    test('quarters follow the marker after a pause', () {
      expect(_binary(3, 23), _e('S g S g L g L P C P ${_rep('C', 2)}'));
      expect(_binary(18, 53), _e('S g L g L g S P L P ${_rep('C', 4)}'));
    });
  });

  group('morse mode', () {
    // Standard digit codes.
    const digit = {
      '0': '-----', '1': '.----', '2': '..---', '3': '...--', '4': '....-',
      '5': '.....', '6': '-....', '7': '--...', '8': '---..', '9': '----.',
    };
    const a = '.-';
    const p = '.--.';

    test('hours 1..9 are one digit, a pause, A or P', () {
      for (var h = 1; h <= 9; h++) {
        expect(_morseOf(h, 0), _e('${_morse(digit['$h']!)} P ${_morse(a)}'),
            reason: '$h AM');
        expect(_morseOf(h + 12, 0),
            _e('${_morse(digit['$h']!)} P ${_morse(p)}'),
            reason: '$h PM');
      }
    });

    test('hour 10 is the digits 1 and 0', () {
      expect(_morseOf(10, 0),
          _e('${_morse('.----')} P ${_morse('-----')} P ${_morse(a)}'));
    });

    test('hour 11 is the digits 1 and 1', () {
      expect(_morseOf(11, 0),
          _e('${_morse('.----')} P ${_morse('.----')} P ${_morse(a)}'));
    });

    test('hour 12 is the digits 1 and 2 (midnight AM, noon PM)', () {
      expect(_morseOf(0, 0),
          _e('${_morse('.----')} P ${_morse('..---')} P ${_morse(a)}'));
      expect(_morseOf(12, 0),
          _e('${_morse('.----')} P ${_morse('..---')} P ${_morse(p)}'));
    });

    test('15:08 is 3, a pause, P, a pause, 1 click', () {
      expect(_morseOf(15, 8),
          _e('${_morse('...--')} P ${_morse(p)} P C'));
    });

    test('quarters follow the letter after a pause', () {
      // 22:53 is 10 PM.
      expect(_morseOf(22, 53),
          _e('${_morse('.----')} P ${_morse('-----')} P ${_morse(p)} '
              'P ${_rep('C', 4)}'));
    });
  });

  group('local wall-clock fields only (DST days, zones)', () {
    test('a spring-forward day reads its own hour and minute', () {
      // US 2026-03-08 and EU 2026-03-29: the day is 23 h long, the wall clock
      // is all that is read.
      expect(encodeTime(DateTime(2026, 3, 8, 3, 8), TimeBuzzMode.count),
          _e('S g S g S P C'));
      expect(encodeTime(DateTime(2026, 3, 29, 1, 59), TimeBuzzMode.count),
          _e('S P ${_rep('C', 4)}'));
    });

    test('a fall-back day reads its own hour and minute', () {
      // 2026-11-01 (US) and 2026-10-25 (EU): the day is 25 h long.
      expect(encodeTime(DateTime(2026, 11, 1, 1, 30), TimeBuzzMode.count),
          _e('S P C g C'));
      expect(encodeTime(DateTime(2026, 10, 25, 2, 30), TimeBuzzMode.binary),
          _e('S g S g L g S P C P C g C'));
    });

    test('the same wall-clock fields give the same rhythm on any date', () {
      for (final mode in TimeBuzzMode.values) {
        final want = encodeTime(DateTime(2026, 1, 15, 15, 8), mode);
        for (final d in [
          DateTime(2026, 3, 8, 15, 8),
          DateTime(2026, 11, 1, 15, 8),
          DateTime(2024, 2, 29, 15, 8),
          DateTime(2026, 12, 31, 15, 8),
        ]) {
          expect(encodeTime(d, mode), want, reason: '$d in $mode');
        }
      }
    });

    test('a UTC-flagged DateTime is read by its own fields, not converted',
        () {
      for (final mode in TimeBuzzMode.values) {
        expect(encodeTime(DateTime.utc(2026, 10, 7, 15, 8), mode),
            encodeTime(DateTime(2026, 10, 7, 15, 8), mode));
      }
    });
  });

  group('shape invariants over every minute of the day, in every mode', () {
    test('a rhythm starts and ends on a buzz, never doubles a separator, has '
        'at least one buzz, and never costs more than the default band '
        'limit (30 commands)', () {
      var worst = 0;
      for (final mode in TimeBuzzMode.values) {
        for (var h = 0; h < 24; h++) {
          for (var m = 0; m < 60; m++) {
            final e = encodeTime(_t(h, m), mode);
            final at = '$h:$m in $mode';
            expect(e, isNotEmpty, reason: at);
            expect(e.first, isNot(anyOf(_g, _ps)), reason: '$at starts on a buzz');
            expect(e.last, isNot(anyOf(_g, _ps)), reason: '$at ends on a buzz');
            for (var i = 1; i < e.length; i++) {
              bool sep(TimeBuzzElement x) => x == _g || x == _ps;
              expect(sep(e[i]) && sep(e[i - 1]), isFalse,
                  reason: '$at has two separators in a row at $i');
            }
            // A buzz is always followed by a separator or the end.
            for (var i = 0; i + 1 < e.length; i++) {
              final sep = e[i] == _g || e[i] == _ps;
              final nextSep = e[i + 1] == _g || e[i + 1] == _ps;
              expect(sep != nextSep, isTrue,
                  reason: '$at: buzzes and separators alternate (at $i)');
            }
            final cost = bandCommandsFor(e);
            if (cost > worst) worst = cost;
            expect(cost, lessThanOrEqualTo(30), reason: at);
          }
        }
      }
      expect(worst, greaterThan(0));
    });

    test('the hour part never contains a click in count mode, and the clicks '
        'are only the quarters', () {
      for (var h = 0; h < 24; h++) {
        final e = _count(h, 53);
        expect(e.where((x) => x == _ck), hasLength(4), reason: 'at $h:53');
        expect(e.take(e.indexOf(_ps)).where((x) => x == _ck), isEmpty);
      }
    });
  });

  group('renderTimeBuzz glyphs', () {
    test('the glyph convention: long ▬, short ·, click •, pause │', () {
      expect(renderTimeBuzz([_lg]), '▬');
      expect(renderTimeBuzz([_sh]), '·');
      expect(renderTimeBuzz([_ck]), '•');
      expect(renderTimeBuzz([_ps]), '│');
    });

    test('a gap draws nothing; glyphs are joined by single spaces', () {
      expect(renderTimeBuzz(_e('S g L P C')), '· ▬ │ •');
      expect(renderTimeBuzz(_e('L g L g L')), '▬ ▬ ▬');
    });

    test('an empty list is the empty string', () {
      expect(renderTimeBuzz(const []), '');
    });

    test('count: 3:08 PM is ▬ ▬ ▬ │ •', () {
      expect(renderTimeBuzz(_count(15, 8)), '▬ ▬ ▬ │ •');
    });

    test('count: 3:00 AM is · · ·', () {
      expect(renderTimeBuzz(_count(3, 0)), '· · ·');
    });

    test('count: 11:59 PM is 11 long, a pause, 4 clicks', () {
      expect(renderTimeBuzz(_count(23, 59)),
          '${List.filled(11, '▬').join(' ')} │ • • • •');
    });

    test('binary: 3:08 PM is · · ▬ ▬ │ ▬ │ •', () {
      expect(renderTimeBuzz(_binary(15, 8)), '· · ▬ ▬ │ ▬ │ •');
    });

    test('binary: 3:00 AM is · · ▬ ▬ │ •', () {
      expect(renderTimeBuzz(_binary(3, 0)), '· · ▬ ▬ │ •');
    });

    test('morse: 3:08 PM is · · · ▬ ▬ │ · ▬ ▬ · │ •', () {
      expect(renderTimeBuzz(_morseOf(15, 8)), '· · · ▬ ▬ │ · ▬ ▬ · │ •');
    });

    test('morse: 12:00 AM is ·▬▬▬▬ │ ··▬▬▬ │ ·▬ spaced', () {
      expect(renderTimeBuzz(_morseOf(0, 0)),
          '· ▬ ▬ ▬ ▬ │ · · ▬ ▬ ▬ │ · ▬');
    });
  });

  group('bandCommandsFor', () {
    test('counts shorts, longs and clicks; gaps and pauses are waits', () {
      expect(bandCommandsFor(const []), 0);
      expect(bandCommandsFor(_e('S')), 1);
      expect(bandCommandsFor(_e('S g L P C')), 3);
      expect(bandCommandsFor(_e('L g L g L P C')), 4);
      expect(bandCommandsFor(_e('P')), 0);
      expect(bandCommandsFor(_e('g g P')), 0);
    });

    test('the examples', () {
      expect(bandCommandsFor(_count(3, 0)), 3);
      expect(bandCommandsFor(_count(15, 8)), 4);
      expect(bandCommandsFor(_count(12, 44)), 15, reason: '12 long + 3 clicks');
      expect(bandCommandsFor(_count(0, 53)), 16, reason: '12 short + 4 clicks');
      expect(bandCommandsFor(_binary(15, 8)), 6, reason: '4 bits + PM + 1');
      expect(bandCommandsFor(_morseOf(15, 8)), 10, reason: '5 + 4 + 1');
    });

    test('it equals the buzzes in the list for every minute of the day', () {
      for (final mode in TimeBuzzMode.values) {
        for (var h = 0; h < 24; h++) {
          for (var m = 0; m < 60; m += 7) {
            final e = encodeTime(_t(h, m), mode);
            expect(bandCommandsFor(e),
                e.where((x) => x != _g && x != _ps).length,
                reason: '$h:$m in $mode');
          }
        }
      }
    });
  });
}
