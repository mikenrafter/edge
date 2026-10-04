// 8AC — the notes -> device commands compiler (spec D).
//
// Targets are written as pattern codes ("N4ff R6 N4f"); the compiler picks
// WHOOP MG commands and the write delays between them so the felt pattern
// lands as close to the target as the measured vocabulary allows. Every test
// here derives its expectation from the profile table or from the spec's
// worked examples; none pins a tie-break the spec does not state.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

PatternDynamic _dyn(String s) =>
    PatternDynamic.values.firstWhere((d) => d.name == s);

/// "N4ff R6 N4f" -> entries. Independent of PatternEntry.parse on purpose.
List<PatternEntry> _c(String code) => [
  for (final tok in code.split(RegExp(r'\s+')).where((t) => t.isNotEmpty))
    tok.startsWith('N')
        ? PatternEntry(
            note: true,
            length: int.parse(RegExp(r'\d+').firstMatch(tok)!.group(0)!),
            dynamic: _dyn(tok.substring(1).replaceAll(RegExp(r'\d+'), '')),
          )
        : PatternEntry(note: false, length: int.parse(tok.substring(1))),
];

/// A rest of [units] sixteenths, split greedily into allowed lengths.
List<PatternEntry> _rest(int units) {
  final out = <PatternEntry>[];
  var left = units;
  for (final l in kPatternLengths.reversed) {
    while (left >= l) {
      out.add(PatternEntry(note: false, length: l));
      left -= l;
    }
  }
  return out;
}

HapticPhrase _phrase(String id) => _mg.phrases.firstWhere((p) => p.id == id);

bool _singleBuzz(HapticPhrase p) => p.effects.length == 1 && p.loop == 1;

List<String> _ids(HapticPlan p) => [for (final s in p.steps) s.phrase.id];

void main() {
  group('timeline', () {
    test('one cell per sixteenth; notes carry their dynamic, rests are null',
        () {
      expect(timeline(_c('N2mf R1 N1ff')), [
        PatternDynamic.mf,
        PatternDynamic.mf,
        null,
        PatternDynamic.ff,
      ]);
    });

    test('dotted lengths and longer rests', () {
      final t = timeline(_c('N3p R4 N12pp'));
      expect(t, hasLength(19));
      expect(t.sublist(0, 3), everyElement(PatternDynamic.p));
      expect(t.sublist(3, 7), everyElement(isNull));
      expect(t.sublist(7), everyElement(PatternDynamic.pp));
    });

    test('empty target -> empty timeline', () {
      expect(timeline(const []), isEmpty);
    });

    test('two adjacent notes are indistinguishable from one long note', () {
      expect(timeline(_c('N1mf N1mf N1mf')), timeline(_c('N3mf')));
    });
  });

  group('compile: the vocabulary round-trips', () {
    test('every stable phrase: its own min and max rendition is one exact step',
        () {
      final stable = _mg.phrases.where((p) => p.stable);
      expect(stable, isNotEmpty);
      for (final p in stable) {
        for (final target in [p.min, p.max]) {
          final plan = compile(target, _mg);
          expect(plan, isNotNull, reason: p.id);
          expect(plan!.exact, isTrue, reason: '${p.id} $target');
          expect(plan.cost, 0, reason: p.id);
          expect(plan.steps, hasLength(1), reason: p.id);
          expect(plan.steps.single.delayMs, 0, reason: p.id);
          final used = plan.steps.single.phrase;
          // contains() on a list of lists compares by identity, so match the
          // cells with equals instead.
          expect(
            timeline(target),
            anyOf(equals(timeline(used.min)), equals(timeline(used.max))),
            reason: '${p.id}: the chosen phrase must feel the same',
          );
          expect(used.stable, isTrue, reason: p.id);
          expect(plan.usesUnstable, isFalse, reason: p.id);
        }
      }
    });

    test('trailing target rests cost nothing', () {
      for (final p in _mg.phrases.where((p) => p.stable)) {
        final plan = compile([...p.min, ..._rest(7)], _mg);
        expect(plan!.exact, isTrue, reason: p.id);
        expect(plan.steps, hasLength(1), reason: p.id);
      }
    });

    test('single-buzz pair x every stable gap row, every rest length inside',
        () {
      final singles = _mg.phrases.where((p) => p.stable).where(_singleBuzz);
      final gaps = _mg.gaps.where((g) => g.stable);
      expect(singles.length, greaterThanOrEqualTo(2));
      expect(gaps, isNotEmpty);
      var checked = 0;
      for (final p in singles) {
        for (final q in singles) {
          for (final g in gaps) {
            for (var k = g.minUnits; k <= g.maxUnits; k++) {
              final target = [...p.min, ..._rest(k), ...q.min];
              final plan = compile(target, _mg);
              final why = '${p.id} + ${q.id}, rest $k, gap ${g.delayMs} ms';
              expect(plan, isNotNull, reason: why);
              expect(plan!.exact, isTrue, reason: why);
              expect(plan.steps, hasLength(2), reason: why);
              expect(plan.steps[0].delayMs, 0, reason: why);
              // Two stable rows may both cover k (0 ms and 100 ms both feel
              // 3..4 units); the tie goes to the lower delay.
              final expected = gaps
                  .where((r) => r.minUnits <= k && k <= r.maxUnits)
                  .map((r) => r.delayMs)
                  .reduce((a, b) => a < b ? a : b);
              expect(plan.steps[1].delayMs, expected, reason: why);
              checked++;
            }
          }
        }
      }
      expect(checked, greaterThan(0));
    });

    test('N4ff R6 N4f -> effect 47, then 300 ms after it ends, effect 14', () {
      {
        final plan = compile(_c('N4ff R6 N4f'), _mg)!;
        expect(_ids(plan), ['buzz47', 'buzz14']);
        expect(plan.steps[0].delayMs, 0);
        expect(plan.steps[1].delayMs, 300,
            reason: 'stable beats lower delay; 6 units is in the 300 ms row');
        expect(plan.exact, isTrue);
        // Exact, so the only cost is the penalty for the second command.
        expect(plan.cost, 2);
        expect(plan.usesUnstable, isFalse);
        expect(plan.steps[0].phrase.effects, [47]);
        expect(plan.steps[1].phrase.effects, [14]);
      }
    });

    test('the plan feels like the shortest and longest the band can do', () {
      final plan = compile(_c('N4ff R6 N4f'), _mg)!;
      // The 300 ms row feels 4..6 units; buzz14 is 3..4 units long.
      expect(timeline(plan.feltMin), timeline(_c('N4ff R4 N3f')));
      expect(timeline(plan.feltMax), timeline(_c('N4ff R6 N4f')));
    });

    test('summary names the commands and the waits', () {
      final plan = compile(_c('N4ff R6 N4f'), _mg)!;
      expect(plan.summary,
          '2 commands: effect 47, then 300 ms after it ends, effect 14');
      final one = compile(_c('N4ff'), _mg)!;
      expect(one.summary, contains('effect 47'));
      expect(one.summary, isNot(contains('commands')));
      expect(one.summary, isNot(contains('after it ends')));
    });
  });

  group('compile: unstable parts are always on the table, stable preferred', () {
    test('a target only click1soft matches takes click1soft, exactly', () {
      final soft = _phrase('click1soft');
      expect(soft.stable, isFalse);
      final plan = compile(soft.min, _mg)!;
      expect(plan.exact, isTrue);
      expect(plan.usesUnstable, isTrue);
      expect(_ids(plan), ['click1soft']);
    });

    test('N4ff R1 N4ff needs the unstable 100 ms gap row', () {
      final target = _c('N4ff R1 N4ff');
      final plan = compile(target, _mg)!;
      expect(plan.exact, isTrue);
      expect(plan.usesUnstable, isTrue);
      expect(plan.steps, hasLength(2));
      expect(plan.steps[1].delayMs, 100);
    });

    test('a stable phrase\'s own rendition never takes an unstable phrase',
        () {
      for (final p in _mg.phrases.where((p) => p.stable)) {
        for (final target in [p.min, p.max]) {
          final plan = compile(target, _mg)!;
          expect(plan.usesUnstable, isFalse, reason: p.id);
          for (final s in plan.steps) {
            expect(s.phrase.stable, isTrue, reason: '${p.id} -> ${s.phrase.id}');
          }
        }
      }
    });

    test('every stable phrase\'s own shortest rendition is exact', () {
      for (final p in _mg.phrases.where((p) => p.stable)) {
        final plan = compile(p.min, _mg)!;
        expect(plan.exact, isTrue, reason: p.id);
      }
    });
  });

  group('compile: edges', () {
    test('leading rests are ignored', () {
      final bare = compile(_c('N4ff R6 N4f'), _mg)!;
      final lead =
          compile([..._rest(13), ..._c('N4ff R6 N4f')], _mg)!;
      expect(_ids(lead), _ids(bare));
      expect([for (final s in lead.steps) s.delayMs],
          [for (final s in bare.steps) s.delayMs]);
      expect(lead.cost, bare.cost);
      expect(lead.exact, isTrue);
      expect(lead.steps.first.delayMs, 0);
    });

    test('empty target and rests-only target -> null', () {
      expect(compile(const [], _mg), isNull);
            expect(compile(_c('R4 R8'), _mg), isNull);
    });

    test('maxCommands caps the steps (and the plan is then not exact)', () {
      final target = _c('N4ff R4 N4ff R4 N4ff R4 N4ff');
      final free = compile(target, _mg)!;
      expect(free.exact, isTrue);
      expect(free.steps.length, greaterThanOrEqualTo(2));
      final one = compile(target, _mg, maxCommands: 1)!;
      expect(one.steps, hasLength(1));
      expect(one.exact, isFalse);
      final two = compile(target, _mg, maxCommands: 2)!;
      expect(two.steps.length, lessThanOrEqualTo(2));
    });

    test('the default cap is 8 commands', () {
      final target = <PatternEntry>[
        for (var i = 0; i < 12; i++) ..._c('N4ff R4'),
      ];
      final plan = compile(target, _mg)!;
      expect(plan.steps.length, lessThanOrEqualTo(8));
    });

    test('deterministic: the same target compiles to the same plan', () {
      final target = _c('N2mf R3 N6ff R5 N1pp R2 N4f');
      {
        final a = compile(target, _mg)!;
        final b = compile(target, _mg)!;
        expect(_ids(b), _ids(a));
        expect([for (final s in b.steps) s.delayMs],
            [for (final s in a.steps) s.delayMs]);
        expect(b.cost, a.cost);
        expect(b.exact, a.exact);
        expect(b.summary, a.summary);
        expect(b.usesUnstable, a.usesUnstable);
      }
    });

    test('the first step never waits', () {
      final plan = compile(_c('N4ff R6 N4f R12 N4ff'), _mg)!;
      expect(plan.steps.first.delayMs, 0);
    });
  });

  group('compile: dynamics cost', () {
    // No WHOOP MG phrase feels four mf cells in a row, so N4mf is only ever
    // approximated; with dynamicWeight 0 loudness is free and a 4-unit buzz
    // matches exactly.
    test('dynamicWeight scales the loudness cost; 0 makes it free', () {
      final target = _c('N4mf');
      final free =
          compile(target, _mg, dynamicWeight: 0)!;
      final one = compile(target, _mg, dynamicWeight: 1)!;
      final two = compile(target, _mg, dynamicWeight: 2)!;
      expect(free.exact, isTrue);
      expect(free.cost, 0);
      expect(one.exact, isFalse);
      expect(one.cost, greaterThan(0));
      expect(two.cost, greaterThanOrEqualTo(one.cost));
    });

    test('dynamicWeight defaults to 1', () {
      final target = _c('N4mf');
      final dflt = compile(target, _mg)!;
      final one = compile(target, _mg, dynamicWeight: 1)!;
      expect(dflt.cost, one.cost);
      expect(dflt.exact, one.exact);
    });
  });

  group('compile: rests longer than 14 units extrapolate', () {
    test('delay = 1200 + (units - 13) x 125', () {
      for (final units in [15, 16, 20, 30]) {
        {
          final target = [
            ..._phrase('buzz47').min,
            ..._rest(units),
            ..._phrase('buzz47').min,
          ];
          final plan = compile(target, _mg)!;
          final why = 'rest $units';
          expect(plan.exact, isTrue, reason: why);
          expect(plan.steps, hasLength(2), reason: why);
          expect(plan.steps[1].delayMs, 1200 + (units - 13) * 125,
              reason: why);
          expect(plan.usesUnstable, isFalse,
              reason: 'waiting longer only lengthens silence: $why');
        }
      }
    });

    test('14 units is still the measured 1200 ms row', () {
      final target = [
        ..._phrase('buzz47').min,
        ..._rest(14),
        ..._phrase('buzz47').min,
      ];
      final plan = compile(target, _mg)!;
      expect(plan.exact, isTrue);
      expect(plan.steps[1].delayMs, 1200);
    });
  });

  group('compile: the command penalty (prefer one command)', () {
    test('cost adds 2 per command beyond the first; exact stays true', () {
      final one = compile(_c('N4ff'), _mg)!;
      expect(one.steps, hasLength(1));
      expect(one.cost, 0);
      final two = compile(_c('N4ff R6 N4f'), _mg)!;
      expect(two.steps, hasLength(2));
      expect(two.cost, 2);
      expect(two.exact, isTrue, reason: 'exact ignores the penalty');
      final four =
          compile(_c('N4ff R4 N4ff R4 N4ff R4 N4ff'), _mg)!;
      expect(four.exact, isTrue);
      expect(four.cost, 2 * (four.steps.length - 1));
    });

    test('commandPenalty 0 gives the old raw cost', () {
      final plan = compile(_c('N4ff R6 N4f'), _mg, commandPenalty: 0)!;
      expect(plan.cost, 0);
      expect(plan.exact, isTrue);
    });

    test('a heavy penalty makes one approximate command beat an exact pair',
        () {
      final plan = compile(_c('N4ff R6 N4f'), _mg, commandPenalty: 100)!;
      expect(plan.steps, hasLength(1));
      expect(plan.exact, isFalse);
      expect(plan.cost, greaterThan(0));
      expect(plan.cost, lessThan(100));
    });

    test('exact is still decided by cell mismatches, not by cost', () {
      for (final penalty in [0, 1, 2, 3]) {
        final plan = compile(_c('N4ff R6 N4f'), _mg, commandPenalty: penalty)!;
        expect(plan.exact, isTrue, reason: 'penalty $penalty');
        expect(plan.cost, penalty, reason: 'penalty $penalty');
      }
    });

    test('the penalty never changes whether an unreachable target is exact',
        () {
      // A 10-unit rest falls between the 700 ms and 1200 ms rows.
      final off = compile(_c('N4ff R8 R2 N4ff'), _mg)!;
      expect(off.exact, isFalse);
      final off0 = compile(_c('N4ff R8 R2 N4ff'), _mg, commandPenalty: 0)!;
      expect(off0.exact, isFalse);
    });
  });

  group('compile: runtime and the runtime cap', () {
    test('kMaxHapticRuntime is 10 seconds', () {
      expect(kMaxHapticRuntime, const Duration(seconds: 10));
    });

    test('runtimeMs is the longest felt timeline times the unit', () {
      final plan = compile(_c('N4ff R6 N4f'), _mg)!;
      expect(plan.runtimeMs, timeline(plan.feltMax).length * _mg.unitMs);
      expect(plan.runtimeMs, 14 * 125);
      final one = compile(_c('N4ff'), _mg)!;
      expect(one.runtimeMs, 4 * 125);
    });

    test('no cap by default: a long target still compiles', () {
      final target = _c('N4ff R12 N4ff R12 N4ff R12 N4ff R12 N4ff');
      expect(compile(target, _mg), isNotNull);
    });

    test('a target longer than the cap gives null', () {
      final target = _c('N4ff R12 N4ff R12 N4ff R12 N4ff R12 N4ff R12 N4ff');
      final free = compile(target, _mg)!;
      expect(free.runtimeMs, greaterThan(5000));
      expect(compile(target, _mg, maxRuntimeMs: 5000),
          isNull);
      expect(compile(_c('N4ff R6 N4f'), _mg, maxRuntimeMs: 100),
          isNull);
    });

    test('a plan at or under the cap is returned, over it never is', () {
      final targets = [
        _c('N4ff R6 N4f'),
        _c('N4ff R4 N4ff R4 N4ff'),
        _c('N2mf R3 N6ff R5 N1pp R2 N4f'),
        _c('N12mf R12 N12mf'),
      ];
      for (final target in targets) {
        for (final cap in [250, 500, 1000, 1500, 2000, 3000, 4000, 8000]) {
          final plan =
              compile(target, _mg, maxRuntimeMs: cap);
          if (plan != null) {
            expect(plan.runtimeMs, lessThanOrEqualTo(cap),
                reason: '$target cap $cap');
          }
        }
        final roomy = compile(target, _mg, maxRuntimeMs: 1000000)!;
        final free = compile(target, _mg)!;
        expect(roomy.summary, free.summary);
        expect(roomy.cost, free.cost);
      }
    });

    test('the cap is inclusive', () {
      final plan = compile(_c('N4ff R6 N4f'), _mg)!;
      expect(
          compile(_c('N4ff R6 N4f'), _mg, maxRuntimeMs: plan.runtimeMs),
          isNotNull);
    });
  });
}
