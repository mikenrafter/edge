// 8AC — the device haptic profile (spec C1): how the WHOOP 5.0 MG band feels
// each command it can be sent (measured in the L6 pattern probe, fixed tempo,
// 1 sixteenth = 125 ms), the rests it adds between two commands, the stable
// probe input set those numbers came from, and the registry the callers look
// a device up in. Pure Dart: no Flutter, no BLE.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probes.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';

/// "N4ff R6 N4f" -> entries. Independent of PatternEntry.parse on purpose.
List<PatternEntry> _c(String code) => [
  for (final tok in code.split(RegExp(r'\s+')).where((t) => t.isNotEmpty))
    tok.startsWith('N')
        ? PatternEntry(
            note: true,
            length: int.parse(RegExp(r'\d+').firstMatch(tok)!.group(0)!),
            dynamic: PatternDynamic.values.firstWhere(
              (d) => d.name == tok.substring(1).replaceAll(RegExp(r'\d+'), ''),
            ),
          )
        : PatternEntry(note: false, length: int.parse(tok.substring(1))),
];

String _code(List<PatternEntry> es) => es.join(' ');

int _units(List<PatternEntry> es) => es.fold(0, (a, e) => a + e.length);

/// One expected phrase row of the spec's table.
typedef _Row = ({
  String id,
  List<int> effects,
  int loop,
  String min,
  String max,
  bool stable,
  List<int> tests,
});

_Row _row(
  String id,
  List<int> effects,
  int loop,
  String min,
  String? max,
  List<int> tests, {
  bool stable = true,
}) => (
  id: id,
  effects: effects,
  loop: loop,
  min: min,
  max: max ?? min,
  stable: stable,
  tests: tests,
);

final List<_Row> _table = [
  _row('buzz47', [47], 1, 'N4ff', null, [2, 6, 18, 22, 34, 36, 38, 40]),
  _row('buzz14', [14], 1, 'N3f', 'N4f', [3, 7, 19, 23, 33, 35, 37, 39]),
  _row('click1', [1], 1, 'N1mp N1mp', null, [4, 8, 20]),
  _row(
    'pair',
    [47, 152],
    1,
    'N2mf R2 N2mf',
    'N3mf R1 N3mf',
    [1, 5, 17, 21],
  ),
  _row('buzz47x2', [47], 2, 'N6ff', null, [10]),
  _row('buzz47x3', [47], 3, 'N8ff', null, [26]),
  _row('buzz14x2', [14], 2, 'N6ff', null, [11]),
  _row('buzz14x3', [14], 3, 'N8ff', null, [27]),
  _row('click1x2', [1], 2, 'N1mf N1mf N1mf', null, [12]),
  _row('click1x3', [1], 3, 'N1mf N1mf N1mf', null, [28]),
  _row('pairx2', [47, 152], 2, 'N2mf R2 N2mf R2 N2mf', null, [9]),
  _row(
    'pairx3',
    [47, 152],
    3,
    'N3mf R1 N3mf R1 N3mf R1 N3mf',
    null,
    [25],
  ),
  _row(
    'pair2',
    [47, 152, 47, 152],
    1,
    'N3ff R1 N3ff R1 N3ff R1 N3ff',
    null,
    [13],
  ),
  _row(
    'pair3',
    [47, 152, 47, 152, 47, 152],
    1,
    'N2mf R2 N2mf R2 N2mf R2 N2mf R2 N2mf R2 N2mf',
    null,
    [29],
  ),
  _row('arc47', [47, 152, 47], 1, 'N2ff R1 N4ff R3 N3mf', null, [14]),
  _row('arc14', [14, 152, 14], 1, 'N2mf R1 N4ff R1 N3mf', null, [15]),
  _row('arc1', [1, 152, 1], 1, 'N1mp R1 N1pp N1pp R2 N2mp', null, [16]),
  _row(
    'arc47x3',
    [47, 152, 47, 152, 47],
    1,
    'N2mf R2 N2mf R2 N4ff R2 N2mf R2 N2mf',
    null,
    [30],
  ),
  _row(
    'arc14x3',
    [14, 152, 14, 152, 14],
    1,
    'N2mf R1 N2mf R2 N4ff R2 N2mf R1 N2mf',
    null,
    [31],
  ),
  _row(
    'arc1x3',
    [1, 152, 1, 152, 1],
    1,
    'N2mf R1 N1mp R1 N1mp N1mp R1 N2mp R1 N2mf',
    null,
    [32],
  ),
  _row('click1soft', [1], 1, 'N1pp N1pp', null, [24], stable: false),
];

/// One expected gap row.
typedef _Gap = ({int delayMs, int min, int max, bool stable, List<int> tests});

const List<_Gap> _gaps = [
  (delayMs: 0, min: 3, max: 4, stable: true, tests: [33, 34]),
  (delayMs: 100, min: 3, max: 4, stable: true, tests: [6, 7, 8, 22, 23]),
  (delayMs: 100, min: 1, max: 6, stable: false, tests: [5, 7, 21, 24]),
  (delayMs: 300, min: 4, max: 6, stable: true, tests: [35, 36]),
  (delayMs: 700, min: 6, max: 8, stable: true, tests: [37, 38]),
  (delayMs: 1200, min: 12, max: 14, stable: true, tests: [39, 40]),
];

/// The 40 descriptions of the L6 probe, in test order. Test number N is the
/// index plus 1 and must never move.
const List<String> _probeDescriptions = [
  'band pair 47+152, 2 commands 1.8 s apart',
  'effect 47 alone, 2 commands 1.8 s apart',
  'effect 14, 2 commands 1.8 s apart',
  'effect 1, 2 commands 1.8 s apart',
  'band pair 47+152, 2 commands, each after the band says the last one ended',
  'effect 47 alone, 2 commands, each after the band says the last one ended',
  'effect 14, 2 commands, each after the band says the last one ended',
  'effect 1, 2 commands, each after the band says the last one ended',
  'band pair 47+152, one command looped 2×',
  'effect 47 alone, one command looped 2×',
  'effect 14, one command looped 2×',
  'effect 1, one command looped 2×',
  'band pair 47+152, one command listing it 2× with a pause slot between',
  'effect 47 alone, one command listing it 2× with a pause slot between',
  'effect 14, one command listing it 2× with a pause slot between',
  'effect 1, one command listing it 2× with a pause slot between',
  'band pair 47+152, 3 commands 1.8 s apart',
  'effect 47 alone, 3 commands 1.8 s apart',
  'effect 14, 3 commands 1.8 s apart',
  'effect 1, 3 commands 1.8 s apart',
  'band pair 47+152, 3 commands, each after the band says the last one ended',
  'effect 47 alone, 3 commands, each after the band says the last one ended',
  'effect 14, 3 commands, each after the band says the last one ended',
  'effect 1, 3 commands, each after the band says the last one ended',
  'band pair 47+152, one command looped 3×',
  'effect 47 alone, one command looped 3×',
  'effect 14, one command looped 3×',
  'effect 1, one command looped 3×',
  'band pair 47+152, one command listing it 3× with a pause slot between',
  'effect 47 alone, one command listing it 3× with a pause slot between',
  'effect 14, one command listing it 3× with a pause slot between',
  'effect 1, one command listing it 3× with a pause slot between',
  'effect 14, 2 commands, the second 0 ms after the first ends',
  'effect 47 alone, 2 commands, the second 0 ms after the first ends',
  'effect 14, 2 commands, the second 300 ms after the first ends',
  'effect 47 alone, 2 commands, the second 300 ms after the first ends',
  'effect 14, 2 commands, the second 700 ms after the first ends',
  'effect 47 alone, 2 commands, the second 700 ms after the first ends',
  'effect 14, 2 commands, the second 1200 ms after the first ends',
  'effect 47 alone, 2 commands, the second 1200 ms after the first ends',
];

void main() {
  final mg = HapticDeviceProfile.whoopMg;

  group('the WHOOP MG profile header', () {
    test('id, name, unit and probe set', () {
      expect(mg.id, 'whoop-5.0-mg');
      expect(mg.name, 'WHOOP 5.0 MG');
      expect(mg.unitMs, 125);
      expect(mg.probeSetId, 'whoop-mg-pattern-v1');
    });

    test('version 1: bump it when the measured vocabulary changes', () {
      expect(mg.version, 1);
    });
  });

  group('the WHOOP MG phrase table (L6)', () {
    test('has the 21 rows of the spec, in order', () {
      expect([for (final p in mg.phrases) p.id], [
        for (final r in _table) r.id,
      ]);
    });

    for (final r in _table) {
      test('${r.id}: effects ${r.effects} x${r.loop}, min ${r.min}, max '
          '${r.max}, ${r.stable ? 'stable' : 'unstable'}, tests ${r.tests}',
          () {
        final p = mg.phrases.firstWhere((p) => p.id == r.id);
        expect(p.effects, r.effects);
        expect(p.loop, r.loop);
        expect(_code(p.min), r.min, reason: 'min');
        expect(_code(p.max), r.max, reason: 'max');
        expect(p.stable, r.stable);
        expect(p.sourceTests, r.tests);
        expect(p.unitsMin, _units(_c(r.min)));
        expect(p.unitsMax, _units(_c(r.max)));
      });
    }

    test('ids are unique', () {
      final ids = [for (final p in mg.phrases) p.id];
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('only click1soft is unstable (test 24 was flagged R1 R2 R4)', () {
      expect([
        for (final p in mg.phrases)
          if (!p.stable) p.id,
      ], ['click1soft']);
    });

    test('min is never longer than max; a single rendition has equal min and '
        'max', () {
      for (final p in mg.phrases) {
        expect(p.unitsMin, lessThanOrEqualTo(p.unitsMax), reason: p.id);
        if (p.sourceTests.length == 1 && p.id != 'click1soft') {
          expect(_code(p.min), _code(p.max), reason: p.id);
        }
      }
    });

    test('the pair and the single 14 are the only rows whose renditions '
        'differ', () {
      expect([
        for (final p in mg.phrases)
          if (_code(p.min) != _code(p.max)) p.id,
      ], ['buzz14', 'pair']);
    });

    test('a single 14 is f (not ff), while a looped or listed 14 is as heard',
        () {
      final b = mg.phrases.firstWhere((p) => p.id == 'buzz14');
      expect(b.min.every((e) => e.dynamic == PatternDynamic.f), isTrue);
      expect(b.max.every((e) => e.dynamic == PatternDynamic.f), isTrue);
      final x2 = mg.phrases.firstWhere((p) => p.id == 'buzz14x2');
      expect(x2.min.single.dynamic, PatternDynamic.ff);
    });

    test('every entry is a legal length; notes have a dynamic, rests none', () {
      for (final p in mg.phrases) {
        for (final e in [...p.min, ...p.max]) {
          expect(kPatternLengths, contains(e.length), reason: p.id);
          expect(e.note, e.dynamic != null, reason: p.id);
        }
        expect(p.min.first.note, isTrue, reason: '${p.id} starts with a note');
        expect(p.max.last.note, isTrue, reason: '${p.id} ends with a note');
      }
    });

    test('every probe test belongs to at least one phrase or gap row', () {
      final covered = {
        for (final p in mg.phrases) ...p.sourceTests,
        for (final g in mg.gaps) ...g.sourceTests,
      };
      expect(covered, {for (var i = 1; i <= 40; i++) i});
    });

    test('effects and loop agree with how the probe wrote each source test',
        () {
      final tests = kWhoopMgPatternProbeSet;
      for (final p in mg.phrases) {
        for (final n in p.sourceTests) {
          final t = tests[n - 1];
          final (effects, loop) = switch (t.style) {
            BuzzStyle.repeat => (t.waveform.effects, t.count),
            BuzzStyle.listed => (t.listedEffects, 1),
            _ => (t.waveform.effects, 1),
          };
          expect(p.effects, effects, reason: '${p.id} test $n effects');
          expect(p.loop, loop, reason: '${p.id} test $n loop');
        }
      }
    });
  });

  group('the WHOOP MG gap table (L6)', () {
    test('has the six rows of the spec, in order', () {
      expect(mg.gaps, hasLength(_gaps.length));
      for (final (i, g) in _gaps.indexed) {
        expect(mg.gaps[i].delayMs, g.delayMs, reason: 'row $i delay');
        expect(mg.gaps[i].minUnits, g.min, reason: 'row $i min');
        expect(mg.gaps[i].maxUnits, g.max, reason: 'row $i max');
        expect(mg.gaps[i].stable, g.stable, reason: 'row $i stable');
        expect(mg.gaps[i].sourceTests, g.tests, reason: 'row $i tests');
      }
    });

    test('only the 100 ms row with the 1..6 spread is unstable', () {
      expect([
        for (final g in mg.gaps)
          if (!g.stable) (g.delayMs, g.minUnits, g.maxUnits),
      ], [(100, 1, 6)]);
    });

    test('each row reads min <= max', () {
      for (final g in mg.gaps) {
        expect(g.minUnits, lessThanOrEqualTo(g.maxUnits));
      }
    });
  });

  group('stable and unstable rows', () {
    test('the profile holds every phrase and every gap, in table order',
        () {
      expect([for (final p in mg.phrases) p.id], [
        for (final r in _table) r.id,
      ]);
      expect(mg.gaps, hasLength(6));
    });

    test('the stable phrases are all but the unstable ones', () {
      final ids = [for (final p in mg.phrases.where((p) => p.stable)) p.id];
      expect(ids, [
        for (final r in _table)
          if (r.stable) r.id,
      ]);
      expect(ids, hasLength(20));
      expect(ids, isNot(contains('click1soft')));
    });

    test('the stable gaps are all but the unstable row', () {
      final gaps = mg.gaps.where((g) => g.stable);
      expect(gaps, hasLength(5));
      expect(gaps.every((g) => g.stable), isTrue);
      expect(
        [for (final g in gaps) (g.delayMs, g.minUnits, g.maxUnits)],
        [(0, 3, 4), (100, 3, 4), (300, 4, 6), (700, 6, 8), (1200, 12, 14)],
      );
    });

    test('the lists do not let a caller change the profile', () {
      final before = mg.phrases.length;
      try {
        mg.phrases.removeLast();
      } on UnsupportedError {
        // fine: unmodifiable
      }
      expect(mg.phrases, hasLength(before));
      expect(mg.phrases, hasLength(before));
    });
  });

  group('the profile registry', () {
    test('whoop-5.0-mg is registered by id', () {
      expect(kHapticProfiles['whoop-5.0-mg'], same(mg));
      expect(kHapticProfiles.keys, ['whoop-5.0-mg']);
    });

    test('an unknown id has no profile', () {
      expect(kHapticProfiles['whoop-4.0'], isNull);
      expect(kHapticProfiles[''], isNull);
    });

    test('gen5 maps to the MG profile; gen4, unknown and null to none', () {
      expect(HapticDeviceProfile.forGeneration('gen5'), same(mg));
      expect(HapticDeviceProfile.forGeneration('gen4'), isNull);
      expect(HapticDeviceProfile.forGeneration('gen6'), isNull);
      expect(HapticDeviceProfile.forGeneration(''), isNull);
      expect(HapticDeviceProfile.forGeneration(null), isNull);
    });
  });

  group('the stable probe input set whoop-mg-pattern-v1', () {
    test('is the 40 tests, in the L6 order, with pinned descriptions', () {
      expect(kWhoopMgPatternProbeSet, hasLength(40));
      expect(_probeDescriptions, hasLength(40));
      expect([
        for (final t in kWhoopMgPatternProbeSet) t.description,
      ], _probeDescriptions);
    });

    test('test number N is the list index plus 1', () {
      for (final (i, t) in kWhoopMgPatternProbeSet.indexed) {
        expect(t.description, _probeDescriptions[i], reason: 'test ${i + 1}');
      }
    });

    test('the pattern probe plays this set by default, in the same order',
        () {
      expect(PatternProbe.defaultTests, hasLength(40));
      for (final (i, t) in kWhoopMgPatternProbeSet.indexed) {
        expect(
          identical(PatternProbe.defaultTests[i], t) ||
              PatternProbe.defaultTests[i].description == t.description,
          isTrue,
          reason: 'test ${i + 1}',
        );
      }
    });

    test('the set cannot be changed by a caller', () {
      expect(
        () => kWhoopMgPatternProbeSet.add(kWhoopMgPatternProbeSet.first),
        throwsUnsupportedError,
      );
    });

    test('the profile names the set it was measured with', () {
      expect(mg.probeSetId, 'whoop-mg-pattern-v1');
    });
  });
}
