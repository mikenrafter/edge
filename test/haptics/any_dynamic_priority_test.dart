// 8AF.5: the "any loudness" note (code "*") and the rhythm / dynamics
// priority. This file holds the model, the heard-log guard and the stored
// BuzzSequence side; the compiler side is haptic_priority_compile_test.dart and
// the editor side is in haptic_pattern_editor_test.dart.
//
// The tests reach the new behaviour through strings and JSON maps (the code
// "N2*", the key 'priority') so they pin what a stored pattern and a typed code
// do, whatever the Dart names are.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probes.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/heard_log.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

bool _junk(Object? e) => e is ArgumentError || e is FormatException;

Map<String, Object?> _mapJson({String? priority, bool withNotes = true}) => {
      'offsetsMs': [0],
      'durationsMs': [500],
      if (withNotes) 'notes': 'N4* R1 N2mf',
      'priority': ?priority,
    };

void main() {
  group('the any-loudness note in the model', () {
    test('"N2*" parses: a note, two sixteenths, any loudness', () {
      final e = PatternEntry.parse('N2*');
      expect(e.note, isTrue);
      expect(e.length, 2);
      expect(e.dynamic, isNotNull, reason: 'a note always has a dynamic');
      expect(e.toString(), 'N2*');
    });

    test('the prose says "eighth note, any loudness"', () {
      expect(PatternEntry.parse('N2*').prose, 'eighth note, any loudness');
      expect(PatternEntry.parse('N3*').prose,
          'dotted eighth note, any loudness');
      expect(PatternEntry.parse('N2mf').prose, 'eighth note mf',
          reason: 'the six keep their prose');
    });

    test('every length takes *, and the code round-trips', () {
      for (final n in kPatternLengths) {
        final e = PatternEntry.parse('N$n*');
        expect(e.length, n);
        expect(e.toString(), 'N$n*');
        expect(PatternEntry.parse(e.toString()), e);
      }
      final t = PatternTranscript.parseCode('N2* R1 N4mf N1*');
      expect(t.code, 'N2* R1 N4mf N1*');
      expect(PatternTranscript.parseCode(t.code).entries, t.entries);
      expect(t.prose,
          'eighth note, any loudness, 16th rest, quarter note mf, 16th note, any loudness');
    });

    test('any is its own value: equal to itself, not to any of the six, and '
        'the hash tells them apart', () {
      final any = PatternEntry.parse('N2*');
      expect(any, PatternEntry.parse('N2*'));
      expect(any.hashCode, PatternEntry.parse('N2*').hashCode);
      final hashes = {any.hashCode};
      for (final d in ['ff', 'f', 'mf', 'mp', 'p', 'pp']) {
        final other = PatternEntry.parse('N2$d');
        expect(any, isNot(other), reason: d);
        hashes.add(other.hashCode);
      }
      expect(hashes, hasLength(7));
      expect(any, isNot(PatternEntry.parse('N4*')));
    });

    test('a rest never has an any: "R2*" is junk, so is "N2**" and "N2 *"', () {
      for (final bad in ['R2*', 'N2**', 'N*', 'N2*x', '*', 'N2 *']) {
        expect(
          () => PatternTranscript.parseCode(bad),
          throwsA(predicate(_junk)),
          reason: bad,
        );
      }
    });

    test('a length outside the allowed ones is still refused with *', () {
      expect(() => PatternEntry.parse('N5*'), throwsArgumentError);
    });

    test('a note with any loudness is a valid transcript entry', () {
      final e = PatternEntry.parse('N4*');
      final t = PatternTranscript(const []).append(e);
      expect(t.code, 'N4*');
      expect(t.replaceAt(0, e).code, 'N4*');
    });

    test('the sticky selector can hold any, and a note under the cursor takes '
        'it', () {
      // The session is exercised through its code so nothing depends on the
      // Dart name of the value.
      final any = PatternEntry.parse('N2*').dynamic!;
      final s = PatternEntrySession([PatternProbe.defaultTests.first]);
      s.tap(2);
      s.moveCursor(-1);
      s.setDynamic(any);
      expect(s.nextDynamic, any);
      expect(s.active.code, 'N2*', reason: 'the cursor was on the note');
      s.moveCursor(1);
      s.tap(1);
      s.tap(4);
      expect(s.active.code, 'N2* R1 N4*');
    });
  });

  // 8AF.6: a take from taps in the lab probe is `*` notes until each is rated.
  // A probe line left with one still parses, as an unrated test.
  group('the heard log reads an any as "not rated"', () {
    String line(String a) =>
        '03:34:45.545 | tap +1 ms | last +0 ms | Pattern probe heard 1/40, '
        'test one: A = $a; B = —; played 1×.';

    test('a probe line whose code carries * parses and is flagged unrated',
        () {
      final r = parseHeardLines(line('eighth note, any loudness (N2*)'));
      expect(r.single.a.join(' '), 'N2*');
      expect(r.single.unrated, isTrue);
    });

    test('the same line with a real dynamic still reads, and is rated', () {
      final r = parseHeardLines(line('eighth note mf (N2mf)'));
      expect(r.single.a.join(' '), 'N2mf');
      expect(r.single.unrated, isFalse);
    });

    test('a rest never makes a test unrated', () {
      final r = parseHeardLines(line('rest (R2)'));
      expect(r.single.unrated, isFalse);
    });
  });

  group('BuzzSequence priority is stored only when it is not the default', () {
    test('old JSON round-trips byte-identical, with no priority key', () {
      final olds = <Object>[
        [0, 300],
        {'offsetsMs': [0, 900], 'durationsMs': [750, 80]},
        _mapJson(),
        {
          'offsetsMs': [0],
          'durationsMs': [500],
          'notes': 'N4* R1 N2mf',
          'profileId': 'whoop-5.0-mg',
          'profileVersion': 1,
          'plan': [
            {'effects': [47], 'loop': 1, 'delayMs': 0},
          ],
          'bakedRuntimeMs': 500,
        },
      ];
      for (final old in olds) {
        final s = BuzzSequence.fromJson(jsonDecode(jsonEncode(old)));
        expect(jsonEncode(s.toJson()), jsonEncode(old), reason: '$old');
        if (s.toJson() is Map) {
          expect((s.toJson() as Map).containsKey('priority'), isFalse);
        }
      }
    });

    test('"dynamics" is written as a priority key and read back', () {
      final s = BuzzSequence.fromJson(_mapJson(priority: 'dynamics'));
      final json = s.toJson() as Map;
      expect(json['priority'], 'dynamics');
      final back = BuzzSequence.fromJson(jsonDecode(jsonEncode(json)));
      expect(back, s);
      expect(jsonEncode(back.toJson()), jsonEncode(json));
    });

    test('a priority with nothing else still takes the map form', () {
      final s = BuzzSequence.fromJson(
        _mapJson(priority: 'dynamics', withNotes: false),
      );
      final json = s.toJson();
      expect(json, isA<Map>());
      expect((json as Map)['priority'], 'dynamics');
    });

    test('"rhythm" is the default: read as it, never written', () {
      final s = BuzzSequence.fromJson(_mapJson(priority: 'rhythm'));
      expect((s.toJson() as Map).containsKey('priority'), isFalse);
      expect(s, BuzzSequence.fromJson(_mapJson()));
    });

    test('an unknown priority value, or one that is not a string, is refused',
        () {
      for (final bad in <Object>['loudness', 3, true]) {
        expect(
          () => BuzzSequence.fromJson({..._mapJson(), 'priority': bad}),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });

    test('equality and hashCode see the priority', () {
      final a = BuzzSequence.fromJson(_mapJson());
      final b = BuzzSequence.fromJson(_mapJson(priority: 'dynamics'));
      expect(a, isNot(b));
      expect(a.hashCode, isNot(b.hashCode));
      expect(b, BuzzSequence.fromJson(_mapJson(priority: 'dynamics')));
    });

    test('copyWith keeps the priority it was not told to change', () {
      final s = BuzzSequence.fromJson(_mapJson(priority: 'dynamics'));
      final c = s.copyWith(patternId: 'p');
      expect((c.toJson() as Map)['priority'], 'dynamics');
      expect(c, isNot(s));
    });

    test('notes with an any survive a stored round trip', () {
      final s = BuzzSequence.fromJson(_mapJson());
      expect(s.notes, 'N4* R1 N2mf');
      final back = BuzzSequence.fromJson(jsonDecode(jsonEncode(s.toJson())));
      expect(back.notes, 'N4* R1 N2mf');
    });
  });
}
