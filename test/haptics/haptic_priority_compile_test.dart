// 8AF.5, spec B: the compiler with an any-loudness cell and the rhythm /
// dynamics priority, and the player's notes fallback that uses it.
//
// Targets are pattern codes on the WHOOP MG profile. The scenarios are derived
// from the profile table, not from a tie-break: "N3mp" can be met by
// click1x2 (three 16th notes at mf: right timing, one step too loud) or by
// click1 (two 16th notes at mp: right loudness, one 16th short).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

List<PatternEntry> _c(String code) => PatternTranscript.parseCode(code).entries;

HapticPlan _plan(
  String code, {
  HapticPriority? priority,
  bool extended = false,
}) =>
    priority == null
        ? compile(_c(code), _mg, extended: extended)!
        : compile(_c(code), _mg, extended: extended, priority: priority)!;

/// How many cells of the plan's scored rendition (the shortest felt) are notes.
int _feltNotes(HapticPlan p) =>
    timeline(p.feltMin).where((c) => c != null).length;

void main() {
  group('priority: rhythm is today', () {
    test('rhythm is the default: no priority and rhythm give the same plan',
        () {
      for (final code in ['N3mp', 'N4mf', 'N4mf R1 N4mf', 'N4ff R6 N4f']) {
        final a = _plan(code);
        final b = _plan(code, priority: HapticPriority.rhythm);
        expect(b.cost, a.cost, reason: code);
        expect(b.summary, a.summary, reason: code);
        expect(b.feltMin, a.feltMin, reason: code);
        expect(b.feltMax, a.feltMax, reason: code);
      }
    });

    test('the costs are the old ones: cells 4, loudness 1', () {
      // N3mp: exact timing one step loud on three cells = 3.
      expect(_plan('N3mp', priority: HapticPriority.rhythm).cost, 3);
      // N2mp is click1 exactly.
      expect(_plan('N2mp', priority: HapticPriority.rhythm).cost, 0);
    });
  });

  group('priority: which plan wins', () {
    test('rhythm keeps the timing: three notes in the three cells, one step '
        'too loud', () {
      final p = _plan('N3mp', priority: HapticPriority.rhythm);
      expect(timeline(p.feltMin).length, 3);
      expect(_feltNotes(p), 3, reason: 'the note fills all three cells');
      expect(
        timeline(p.feltMin).whereType<PatternDynamic>(),
        everyElement(isNot(PatternEntry.parse('N1mp').dynamic)),
        reason: 'and it is not the written loudness',
      );
    });

    test('dynamics keeps the loudness: mp as written, one 16th short', () {
      final p = _plan('N3mp', priority: HapticPriority.dynamics);
      expect(
        timeline(p.feltMin).whereType<PatternDynamic>(),
        everyElement(PatternEntry.parse('N1mp').dynamic),
      );
      expect(_feltNotes(p), 2, reason: 'one cell short, not the wrong loudness');
    });

    test('the same target gives different plans under the two priorities', () {
      final r = _plan('N3mp', priority: HapticPriority.rhythm);
      final d = _plan('N3mp', priority: HapticPriority.dynamics);
      expect(d.summary, isNot(r.summary));
      expect(d.feltMin, isNot(r.feltMin));
    });

    test('a target the band can play exactly is the same under both', () {
      for (final code in ['N4ff', 'N2mp']) {
        final r = _plan(code, priority: HapticPriority.rhythm);
        final d = _plan(code, priority: HapticPriority.dynamics);
        expect(d.exact, r.exact, reason: code);
        expect(d.cost, r.cost, reason: code);
        expect(d.feltMax, r.feltMax, reason: code);
      }
    });

    test('dynamics still never invents loudness: written mf stays mf when it '
        'can', () {
      final d = _plan('N2mf R2 N2mf', priority: HapticPriority.dynamics);
      expect(d.exact, isTrue);
      expect(d.cost, 0);
    });
  });

  group('an any cell', () {
    test('costs nothing for loudness against any phrase', () {
      for (final code in ['N4*', 'N3*', 'N2*', 'N8*', 'N1*']) {
        for (final prio in HapticPriority.values) {
          final p = _plan(code, priority: prio);
          // Same target with a loudness written: never cheaper than any.
          final loud = code.replaceAll('*', 'pp');
          expect(
            p.cost,
            lessThanOrEqualTo(_plan(loud, priority: prio).cost),
            reason: '$code under $prio',
          );
        }
      }
      // N4* is met by effect 47 or 14 at no cost, exact.
      final p = _plan('N4*');
      expect(p.cost, 0);
      expect(p.exact, isTrue);
    });

    test('a pattern of any notes costs what the same timing costs at a '
        'loudness the band has', () {
      for (final prio in HapticPriority.values) {
        final anyPlan = _plan('N2* R2 N2*', priority: prio);
        final mfPlan = _plan('N2mf R2 N2mf', priority: prio);
        expect(anyPlan.cost, mfPlan.cost, reason: '$prio');
        expect(anyPlan.cost, 0);
      }
    });

    test('any is not a position on the loudness scale: no step distance, so '
        'N3* costs 0 where N3pp costs more', () {
      expect(_plan('N3*').cost, 0);
      expect(_plan('N3pp').cost, greaterThan(0));
      expect(_plan('N3*', priority: HapticPriority.dynamics).cost, 0);
    });

    test('asWritten: an any note is written as played by any loudness', () {
      final p = _plan('N4*');
      expect(p.exact, isTrue);
      expect(p.asWritten, isTrue,
          reason: 'effect 47 plays N4ff and N4* accepts every loudness');
      // The pair is felt as 2 to 3 units, so even with any it is not as
      // written: any forgives loudness, not timing.
      expect(_plan('N2* R2 N2*').asWritten, isFalse);
    });

    test('a written loudness the band cannot play is still not as written',
        () {
      expect(_plan('N4mf').asWritten, isFalse);
    });

    test('a mix of any and written notes keeps the written ones scored', () {
      final p = _plan('N4* R3 N4pp');
      expect(p.exact, isFalse, reason: 'N4pp is not in the vocabulary');
      expect(p.cost, greaterThan(0));
    });

    test('leading and trailing rests around any are ignored as before', () {
      expect(_plan('R2 N4* R4').cost, 0);
    });
  });

  group('timeline keeps the any cell distinct', () {
    test('an any cell is a note, not a rest, and not one of the six', () {
      final t = timeline(_c('N2* R1 N1mf'));
      expect(t, hasLength(4));
      expect(t[0], isNotNull);
      expect(t[0], t[1]);
      expect(t[2], isNull);
      expect(t[0], isNot(t[3]));
    });
  });

  group('delivery: the notes fallback uses the stored priority', () {
    BuzzSequence stored(HapticPriority priority) => BuzzSequence(
          const [0],
          durationsMs: const [500],
          notes: 'N3mp',
          profileId: _mg.id,
          profileVersion: _mg.version,
          priority: priority,
        );

    Future<List<List<int>>> played(BuzzSequence s) async {
      final writes = <List<int>>[];
      await deliverBandSequence(
        s,
        profile: _mg,
        buzz: () async => true,
        writePattern: (effects, loop) async {
          writes.add([...effects, loop]);
          return true;
        },
        waitEnded: (_) async => true,
        isConnected: () => true,
      );
      return writes;
    }

    test('rhythm plays the three-cell plan, dynamics the soft two-cell one',
        () async {
      final rhythm = _plan('N3mp', priority: HapticPriority.rhythm);
      final dynamics = _plan('N3mp', priority: HapticPriority.dynamics);
      final r = await played(stored(HapticPriority.rhythm));
      final d = await played(stored(HapticPriority.dynamics));
      List<List<int>> want(HapticPlan p) => [
            for (final s in p.steps) [...s.phrase.effects, s.phrase.loop],
          ];
      expect(r, want(rhythm));
      expect(d, want(dynamics));
      expect(r, isNot(d));
    });

    test('a stored sequence without a priority plays as rhythm', () async {
      final plain = BuzzSequence(
        const [0],
        durationsMs: const [500],
        notes: 'N3mp',
        profileId: _mg.id,
        profileVersion: _mg.version,
      );
      final r = await played(plain);
      expect(r, await played(stored(HapticPriority.rhythm)));
    });
  });

  group('each step knows where in the target it starts (8AF.5 E)', () {
    List<int> starts(String code) =>
        [for (final st in _plan(code).steps) st.startUnit];

    test('one command starts at the first note', () {
      expect(starts('N4ff'), [0]);
    });

    test('a leading rest is part of the position: R2 N4ff starts at 2', () {
      expect(starts('R2 N4ff'), [2]);
    });

    test('a second command starts after the rest that the wait covers', () {
      // effect 47 (4 cells), 3 cells of rest, click1x2 (3 cells).
      final p = _plan('N4ff R3 N3mf');
      expect(p.steps, hasLength(2));
      expect(starts('N4ff R3 N3mf'), [0, 7]);
    });

    test('with a leading rest the later steps move with it', () {
      expect(starts('R1 N4ff R3 N3mf'), [1, 8]);
    });

    test('three commands: the starts follow each rest', () {
      final p = _plan('N4ff R3 N4ff R4 N4ff');
      expect(p.steps, hasLength(3));
      expect(starts('N4ff R3 N4ff R4 N4ff'), [0, 7, 15]);
    });
  });
}
