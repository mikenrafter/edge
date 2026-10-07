// What an incoming `tasker_play` call asks for (RED), as a pure parse.
//
// Tasker -> band. The native receiver forwards the intent's extras on the
// `openstrap/tasker` channel as method `tasker_play` with a map holding
// EITHER `slot` OR `pattern`:
//   slot     1..6 (int, or the number as a string): numbered Tasker slot n,
//            which is the haptic slot `tasker.n`; or a haptic cue slot key
//            ('tasker.3', 'gesture.confirm', 'breath.done', ...).
//   pattern  a stored pattern id ('sys.preset.sos', or a wearer's pattern id).
// Anything that names neither is not a request (null) and the handler ignores
// and logs it. Whether a pattern id exists is only known when it plays (see
// tasker_incoming_play_test.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/platform/tasker_play.dart';

String? _slot(Object? args) {
  final r = parseTaskerPlay(args);
  return r is TaskerSlotPlay ? r.slotKey : null;
}

String? _pattern(Object? args) {
  final r = parseTaskerPlay(args);
  return r is TaskerPatternPlay ? r.patternId : null;
}

void main() {
  group('a slot', () {
    test('by number 1..6 is the Tasker slot of that number', () {
      for (var n = 1; n <= 6; n++) {
        expect(_slot({'slot': n}), 'tasker.$n', reason: 'int $n');
        expect(_slot({'slot': '$n'}), 'tasker.$n', reason: 'string "$n"');
      }
    });

    test('by key is that slot, for a Tasker slot and for the other cue slots',
        () {
      expect(_slot({'slot': 'tasker.4'}), 'tasker.4');
      expect(_slot({'slot': 'gesture.confirm'}), 'gesture.confirm');
      expect(_slot({'slot': 'breath.done'}), 'breath.done');
    });

    test('a number outside 1..6 is not a request', () {
      for (final bad in [0, 7, -1, 100, '0', '7', '1.5', ' ']) {
        expect(parseTaskerPlay({'slot': bad}), isNull, reason: '$bad');
      }
    });

    test('an unknown key is not a request', () {
      for (final bad in ['tasker.0', 'tasker.7', 'tasker', 'nope', '']) {
        expect(parseTaskerPlay({'slot': bad}), isNull, reason: '"$bad"');
      }
    });
  });

  group('a pattern', () {
    test('by id is that pattern, whatever the id looks like', () {
      expect(_pattern({'pattern': 'sys.preset.sos'}), 'sys.preset.sos');
      expect(_pattern({'pattern': 'a1b2c3'}), 'a1b2c3');
    });

    test('an empty id is not a request', () {
      expect(parseTaskerPlay({'pattern': ''}), isNull);
    });
  });

  group('malformed calls', () {
    test('no arguments, not a map, an empty map or unrelated keys', () {
      for (final bad in <Object?>[null, 3, 'tasker.1', <String, Object>{}, [1], {'x': 1}]) {
        expect(parseTaskerPlay(bad), isNull, reason: '$bad');
      }
    });

    test('a map with the keys of the native channel (Object? keys) parses',
        () {
      final args = <Object?, Object?>{'slot': 2};
      expect(_slot(args), 'tasker.2');
    });
  });
}
