// The multi-log vocabulary builder.
//
// The device profile is read from transcribed probe logs. This builds a
// profile from SEVERAL logs, so a new log widens the table by a reviewed
// change instead of a hand edit:
//
//   HapticDeviceProfile buildProfileFromLogs(List<String> logTexts,
//       {required HapticDeviceProfile base,
//        Map<String, PatternDynamic> dynamicOverrides = const {}});
//   String describeProfileDiff(HapticDeviceProfile a, HapticDeviceProfile b);
//
// in lib/haptics/vocab_builder.dart. Rules the tests pin:
//   * min / max of a phrase are the shortest and longest rendition (by total
//     units) heard in ANY log of its sourceTests; the same for a gap row from
//     its tests (the rest between the two commands);
//   * a phrase or gap is not stable when ANY log flags ANY of its source tests
//     unstable (a log can only clear stability, never restore it);
//   * a phrase or gap no log mentions is kept as the base has it;
//   * the version is base.version + 1 when anything changed, else unchanged;
//   * id, name, unitMs and probeSetId come from the base;
//   * dynamicOverrides (phrase id -> dynamic) set every note of that phrase's
//     min and max to that dynamic (the L6 table has "buzz14" at f).
//   * describeProfileDiff: "No changes" (any case) when identical; else a line
//     "version 1 -> 2" (or the arrow), then one line per changed phrase or gap
//     naming its id (a gap: its delay in ms) with the old and the new code, and
//     the word "unstable" when stability was lost.
// tool/build_haptic_vocab.dart reads docs/hardware/logs/*.txt, prints the diff
// against HapticDeviceProfile.whoopMg and the Dart table.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/vocab_builder.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

const String _l6Path = 'docs/hardware/logs/2026-10-03-pattern-probe-L6.txt';

const _stamp = '03:34:45.545 | tap +932661 ms | last +0 ms | ';

String _line(
  int n,
  String desc,
  String a,
  String b,
  int plays, {
  bool unstable = false,
}) =>
    '$_stamp${'Pattern probe heard $n/40, $desc'}'
    '${unstable ? ', unstable (A and B are the shortest and longest)' : ''}'
    ': A = $a; B = $b; played $plays×.';

String _l6() => File(_l6Path).readAsStringSync();

String _entries(List<PatternEntry> es) => es.join(' ');

/// Everything a profile says, as text: equal text is an equal profile.
String _snap(HapticDeviceProfile p) {
  final b = StringBuffer(
    '${p.id}|${p.name}|${p.unitMs}|${p.probeSetId}|v${p.version}\n',
  );
  for (final ph in p.phrases) {
    b.writeln(
      'P ${ph.id} ${ph.effects} x${ph.loop} min=${_entries(ph.min)} '
      'max=${_entries(ph.max)} stable=${ph.stable} src=${ph.sourceTests}',
    );
  }
  for (final g in p.gaps) {
    b.writeln(
      'G ${g.delayMs} ${g.minUnits}..${g.maxUnits} stable=${g.stable} '
      'src=${g.sourceTests}',
    );
  }
  return b.toString();
}

HapticPhrase _phrase(HapticDeviceProfile p, String id) =>
    p.phrases.firstWhere((x) => x.id == id);

HapticGap _gap(HapticDeviceProfile p, int delay, {bool stable = true}) =>
    p.gaps.firstWhere((g) => g.delayMs == delay && g.stable == stable);

HapticDeviceProfile _build(
  List<String> logs, {
  Map<String, PatternDynamic> overrides = const {'buzz14': PatternDynamic.f},
}) => buildProfileFromLogs(logs, base: _mg, dynamicOverrides: overrides);

// Test 10 (effect 47 looped 2x) heard longer than in L6 (N6ff).
final String _longer10 = _line(
  10,
  'effect 47 alone, one command looped 2×',
  'half note ff (N8ff)',
  '—',
  4,
);

void main() {
  test('the L6 log is there and the base is version 1', () {
    expect(File(_l6Path).existsSync(), isTrue);
    expect(_mg.version, 1);
  });

  group('a test with notes never rated', () {
    test('is left out: the profile is the same with or without it', () {
      // Test 10 heard longer, but left at any loudness: not used.
      final unrated = _longer10.replaceAll('N8ff', 'N8*');
      expect(_snap(_build([_l6(), unrated])), _snap(_build([_l6()])));
    });

    test('the same line rated is used', () {
      expect(_snap(_build([_l6(), _longer10])),
          isNot(_snap(_build([_l6()]))));
    });
  });

  group('the L6 log alone', () {
    test('reproduces HapticDeviceProfile.whoopMg exactly', () {
      final built = _build([_l6()]);
      expect(_snap(built), _snap(_mg));
    });

    test('and the version stays at 1', () {
      expect(_build([_l6()]).version, 1);
    });

    test('the same log twice changes nothing', () {
      expect(_snap(_build([_l6(), _l6()])), _snap(_mg));
    });

    test('keeps id, name, unit and probe set of the base', () {
      final built = _build([_l6()]);
      expect(built.id, 'whoop-5.0-mg');
      expect(built.name, 'WHOOP 5.0 MG');
      expect(built.unitMs, 125);
      expect(built.probeSetId, _mg.probeSetId);
    });

    test('the unstable test 24 still makes click1soft unstable', () {
      expect(_phrase(_build([_l6()]), 'click1soft').stable, isFalse);
    });

    test('no logs, or empty or unrelated text, gives the base unchanged', () {
      expect(_snap(_build(const [])), _snap(_mg));
      expect(_snap(_build([''])), _snap(_mg));
      expect(_snap(_build(['Band events, oldest first\n  Event 100'])),
          _snap(_mg));
    });
  });

  group('a second log widens the vocabulary', () {
    test('a longer rendition widens max, keeps min, bumps the version', () {
      final built = _build([_l6(), _longer10]);
      final ph = _phrase(built, 'buzz47x2');
      expect(_entries(ph.min), 'N6ff');
      expect(_entries(ph.max), 'N8ff');
      expect(ph.unitsMax, 8);
      expect(built.version, 2);
    });

    test('nothing else changes', () {
      final built = _build([_l6(), _longer10]);
      expect(built.phrases.length, _mg.phrases.length);
      for (final base in _mg.phrases) {
        if (base.id == 'buzz47x2') continue;
        final got = _phrase(built, base.id);
        expect(_entries(got.min), _entries(base.min), reason: base.id);
        expect(_entries(got.max), _entries(base.max), reason: base.id);
        expect(got.stable, base.stable, reason: base.id);
      }
      expect(built.gaps.length, _mg.gaps.length);
    });

    test('a shorter rendition lowers min, keeps max, bumps the version', () {
      // Test 26 (effect 47 looped 3x) is N8ff in L6.
      final shorter = _line(
        26,
        'effect 47 alone, one command looped 3×',
        'dotted quarter note ff (N6ff)',
        '—',
        2,
      );
      final built = _build([_l6(), shorter]);
      final ph = _phrase(built, 'buzz47x3');
      expect(_entries(ph.min), 'N6ff');
      expect(_entries(ph.max), 'N8ff');
      expect(built.version, 2);
    });

    test('a rendition inside the known range changes nothing', () {
      // Test 10 heard as the same N6ff again.
      final same = _line(
        10,
        'effect 47 alone, one command looped 2×',
        'dotted quarter note ff (N6ff)',
        '—',
        9,
      );
      final built = _build([_l6(), same]);
      expect(_snap(built), _snap(_mg));
      expect(built.version, 1);
    });

    test('the order of the logs does not matter', () {
      expect(
        _snap(_build([_longer10, _l6()])),
        _snap(_build([_l6(), _longer10])),
      );
    });

    test('three logs: the widest wins', () {
      final evenLonger = _line(
        10,
        'effect 47 alone, one command looped 2×',
        'dotted half note ff (N12ff)',
        '—',
        1,
      );
      final built = _build([_l6(), _longer10, evenLonger]);
      expect(_entries(_phrase(built, 'buzz47x2').max), 'N12ff');
      expect(_entries(_phrase(built, 'buzz47x2').min), 'N6ff');
      expect(built.version, 2);
    });

    test('an unstable test spreads min and max over its two renditions', () {
      final flagged = _line(
        10,
        'effect 47 alone, one command looped 2×',
        'dotted quarter note ff (N6ff)',
        'half note ff (N8ff)',
        3,
        unstable: true,
      );
      final built = _build([_l6(), flagged]);
      final ph = _phrase(built, 'buzz47x2');
      expect(_entries(ph.min), 'N6ff');
      expect(_entries(ph.max), 'N8ff');
      expect(ph.stable, isFalse);
    });
  });

  group('stability', () {
    test('an unstable flag in a second log clears stable', () {
      final flagged = _line(
        12,
        'effect 1, one command looped 2×',
        '16th note mf, 16th note mf, 16th note mf (N1mf N1mf N1mf)',
        '16th note mf, 16th note mf, 16th note mf (N1mf N1mf N1mf)',
        5,
        unstable: true,
      );
      final built = _build([_l6(), flagged]);
      final ph = _phrase(built, 'click1x2');
      expect(ph.stable, isFalse);
      expect(built.version, 2);
      expect(
        [for (final p in built.phrases.where((p) => p.stable)) p.id],
        isNot(contains('click1x2')),
      );
      expect(
        [for (final p in built.phrases) p.id],
        contains('click1x2'),
      );
    });

    test('the legacy R1 R2 R4 tail flags a test unstable too', () {
      final tail = _line(
        12,
        'effect 1, one command looped 2×',
        'a (N1mf N1mf N1mf R1 R2 R4)',
        '—',
        5,
      );
      expect(_phrase(_build([_l6(), tail]), 'click1x2').stable, isFalse);
    });

    test('one flagged source test is enough for a multi-test phrase', () {
      // buzz14 comes from tests 3, 7, 19, 23, 33, 35, 37, 39.
      final flagged = _line(
        19,
        'effect 14, 3 commands 1.8 s apart',
        'quarter note mf, half rest, dotted eighth rest, quarter note mf, '
            'half rest, dotted eighth rest, quarter note mf '
            '(N4mf R8 R3 N4mf R8 R3 N4mf)',
        '—',
        4,
        unstable: true,
      );
      expect(_phrase(_build([_l6(), flagged]), 'buzz14').stable, isFalse);
    });

    test('a later log without the flag does not restore stability', () {
      final unflagged24 = _line(
        24,
        'effect 1, 3 commands, each after the band says the last one ended',
        'x (N1pp N1pp R6 N1pp N1pp R6 N1pp N1pp)',
        '—',
        5,
      );
      final built = _build([_l6(), unflagged24]);
      expect(_phrase(built, 'click1soft').stable, isFalse);
    });

    test('stable phrases that no log flags stay stable', () {
      final built = _build([_l6(), _longer10]);
      expect(_phrase(built, 'buzz47').stable, isTrue);
      expect(_phrase(built, 'pair').stable, isTrue);
    });
  });

  group('gaps', () {
    test('a longer rest between two commands widens the gap row', () {
      // Test 40 (1200 ms): L6 has 12 and 14 sixteenths; this one has 16.
      final wide = _line(
        40,
        'effect 47 alone, 2 commands, the second 1200 ms after the first ends',
        'quarter note ff, dotted half rest, quarter rest, quarter note ff '
            '(N4ff R12 R4 N4ff)',
        '—',
        2,
      );
      final built = _build([_l6(), wide]);
      final g = _gap(built, 1200);
      expect(g.minUnits, 12);
      expect(g.maxUnits, 16);
      expect(g.stable, isTrue);
      expect(built.version, 2);
      // The other rows are as before.
      for (final base in _mg.gaps) {
        if (base.delayMs == 1200) continue;
        final got = built.gaps.firstWhere(
          (x) => x.delayMs == base.delayMs && x.stable == base.stable &&
              x.sourceTests.join() == base.sourceTests.join(),
        );
        expect(got.minUnits, base.minUnits);
        expect(got.maxUnits, base.maxUnits);
      }
    });

    test('an unstable flag on a gap test clears that row stable', () {
      final flagged = _line(
        36,
        'effect 47 alone, 2 commands, the second 300 ms after the first ends',
        'quarter note ff, dotted quarter rest, quarter note ff '
            '(N4ff R6 N4ff)',
        'quarter note ff, dotted quarter rest, quarter note ff '
            '(N4ff R6 N4ff)',
        4,
        unstable: true,
      );
      final built = _build([_l6(), flagged]);
      expect(
        built.gaps.where((g) => g.delayMs == 300 && g.stable),
        isEmpty,
      );
      expect(built.gaps.where((g) => g.delayMs == 300 && !g.stable),
          isNotEmpty);
      expect(
        [for (final g in built.gaps.where((g) => g.stable)) g.delayMs],
        isNot(contains(300)),
      );
      expect(built.version, 2);
    });
  });

  group('dynamic overrides', () {
    test('without one the dynamics are the ones read', () {
      // buzz47 is ff in the table; the override map is empty here.
      final built = _build([_l6(), _longer10], overrides: const {});
      expect(_entries(_phrase(built, 'buzz47x2').max), 'N8ff');
    });

    test('an override sets every note of that phrase', () {
      final built = _build(
        [_l6()],
        overrides: const {'buzz14': PatternDynamic.f, 'buzz47': PatternDynamic.mf},
      );
      final ph = _phrase(built, 'buzz47');
      expect(_entries(ph.min), 'N4mf');
      expect(_entries(ph.max), 'N4mf');
      expect(_entries(_phrase(built, 'buzz14').min), 'N3f');
      expect(_entries(_phrase(built, 'buzz14').max), 'N4f');
      // A change from the base is a version bump.
      expect(built.version, 2);
    });

    test('an override naming no phrase is ignored', () {
      final built = _build(
        [_l6()],
        overrides: const {
          'buzz14': PatternDynamic.f,
          'no-such-phrase': PatternDynamic.pp,
        },
      );
      expect(_snap(built), _snap(_mg));
    });
  });

  group('describeProfileDiff', () {
    test('identical profiles say there is no change', () {
      expect(
        describeProfileDiff(_mg, _mg),
        matches(RegExp('no changes', caseSensitive: false)),
      );
      expect(
        describeProfileDiff(_mg, _build([_l6()])),
        matches(RegExp('no changes', caseSensitive: false)),
      );
    });

    test('a widened phrase names its id, the old and the new code, and the '
        'version', () {
      final text = describeProfileDiff(_mg, _build([_l6(), _longer10]));
      expect(text, matches(RegExp(r'version 1\s*(->|→)\s*2')));
      expect(text, contains('buzz47x2'));
      expect(text, contains('N6ff'));
      expect(text, contains('N8ff'));
      // Only what changed is named.
      expect(text, isNot(contains('buzz14x3')));
      expect(text, isNot(contains('click1soft')));
    });

    test('lost stability is said', () {
      final flagged = _line(
        12,
        'effect 1, one command looped 2×',
        'a (N1mf N1mf N1mf)',
        'a (N1mf N1mf N1mf)',
        5,
        unstable: true,
      );
      final text = describeProfileDiff(_mg, _build([_l6(), flagged]));
      expect(text, contains('click1x2'));
      expect(text, contains('unstable'));
    });

    test('a changed gap names its delay', () {
      final wide = _line(
        40,
        'effect 47 alone, 2 commands, the second 1200 ms after the first ends',
        'a (N4ff R12 R4 N4ff)',
        '—',
        2,
      );
      final text = describeProfileDiff(_mg, _build([_l6(), wide]));
      expect(text, contains('1200'));
      expect(text, contains('16'));
    });

    test('is not symmetric in wording but names the same things both ways',
        () {
      final wider = _build([_l6(), _longer10]);
      expect(describeProfileDiff(wider, _mg), contains('buzz47x2'));
    });
  });

  group('the tool', () {
    test('tool/build_haptic_vocab.dart exists and uses the builder', () {
      final f = File('tool/build_haptic_vocab.dart');
      expect(f.existsSync(), isTrue);
      final text = f.readAsStringSync();
      expect(text, contains('buildProfileFromLogs'));
      expect(text, contains('describeProfileDiff'));
      expect(text, contains('docs/hardware/logs'));
      expect(text, contains('HapticDeviceProfile.whoopMg'));
    });
  });
}
