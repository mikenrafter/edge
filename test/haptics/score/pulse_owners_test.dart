// Who plays each pulse of a target, in the branch a plan takes when its
// commands' own pulses do not add up to the target's (the cap bit, or a pulse
// was merged or dropped): each pulse goes to the command whose felt notes
// overlap it most, the nearest one when none does, null when no command feels
// a note. Forced here with hand-built plans whose pulse counts differ from the
// target's, then through the compiler and the score colouring.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/score_layout.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/ui2/haptic_score.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

HapticPhrase _phrase(String id) => _mg.phrases.firstWhere((p) => p.id == id);

// A phrase that feels nothing: a rest.
final HapticPhrase _silent = HapticPhrase(
  id: 'silent',
  effects: const [0],
  loop: 1,
  min: PatternTranscript.parseCode('R2').entries,
  max: PatternTranscript.parseCode('R2').entries,
  sourceTests: const [],
);

HapticStep _step(HapticPhrase p, int startUnit) =>
    HapticStep(phrase: p, delayMs: 0, startUnit: startUnit);

// The target as the compiler sees it: leading rests trimmed, [first] of them.
({List<PatternDynamic?> cells, int first}) _target(String code) {
  final all = timeline(PatternTranscript.parseCode(code).entries);
  final first = all.indexWhere((c) => c != null);
  final last = all.lastIndexWhere((c) => c != null);
  return (cells: all.sublist(first, last + 1), first: first);
}

List<int?> _owners(String code, List<HapticStep> steps) {
  final t = _target(code);
  return pulseOwnersOf(steps, t.cells, t.first);
}

void main() {
  group('the exact branch, for contrast', () {
    test('pulses that add up are handed out in order, positions unused', () {
      // One pulse each: 1 + 1 = 2 pulses; both steps claim to start at 0.
      expect(
        _owners('N4ff R4 N4ff', [
          _step(_phrase('buzz47'), 0),
          _step(_phrase('buzz47'), 0),
        ]),
        [0, 1],
      );
    });
  });

  group('the overlap branch (the commands\' pulses do not add up)', () {
    test('a pulse goes to the command that overlaps it most', () {
      // Three target pulses, two single-pulse commands: 2 != 3.
      // A (0-3) and C (10-13) are played by their commands.
      final o = _owners('N4ff R3 N2mf R1 N4ff', [
        _step(_phrase('buzz47'), 0),
        _step(_phrase('buzz47'), 10),
      ]);
      expect(o.first, 0);
      expect(o.last, 1);
    });

    test('the larger overlap wins, even for a later command', () {
      // One pulse, cells 0-7: the first command feels 4 of them, the second
      // (a x2 buzz starting at 2) feels 6.
      expect(
        _owners('N8ff', [
          _step(_phrase('buzz47'), 0),
          _step(_phrase('buzz47x2'), 2),
        ]),
        [1],
      );
    });

    test('equal overlap: the earlier command', () {
      expect(
        _owners('N4ff', [
          _step(_phrase('buzz47'), 0),
          _step(_phrase('buzz47'), 0),
        ]),
        [0],
      );
    });

    test('a pulse no command overlaps goes to the nearest felt note', () {
      // B (cells 7-8) is 4 cells after the first command's last note and 2
      // before the second command's first.
      expect(
        _owners('N4ff R3 N2mf R1 N4ff', [
          _step(_phrase('buzz47'), 0),
          _step(_phrase('buzz47'), 10),
        ]),
        [0, 1, 1],
      );
      // And the other way round: 2 after the first, 4 before the second.
      expect(
        _owners('N4ff R1 N2mf R3 N4ff', [
          _step(_phrase('buzz47'), 0),
          _step(_phrase('buzz47'), 10),
        ]),
        [0, 0, 1],
      );
    });

    test('a tie of distance goes to the earlier command', () {
      // B (cells 6-7) is 3 from the end of the first and 3 from the start of
      // the second (cells 10-13).
      expect(
        _owners('N4ff R2 N2mf R2 N4ff', [
          _step(_phrase('buzz47'), 0),
          _step(_phrase('buzz47'), 10),
        ]),
        [0, 0, 1],
      );
    });

    test('the leading rests the target lost shift the commands\' positions',
        () {
      // The same score behind two rests: startUnit counts from the first
      // entry, so every position is 2 later and the answer is unchanged.
      expect(
        _owners('R2 N4ff R3 N2mf R1 N4ff', [
          _step(_phrase('buzz47'), 2),
          _step(_phrase('buzz47'), 12),
        ]),
        [0, 1, 1],
      );
    });

    test('a pulse nothing plays is null: no command, or only silence', () {
      expect(_owners('N4ff R4 N4ff', const []), [null, null]);
      expect(
        _owners('N4ff R4 N4ff', [_step(_silent, 0)]),
        [null, null],
        reason: 'one command that feels no note covers nothing',
      );
    });
  });

  group('through the compiler', () {
    test('a cap on the commands merges pulses: owners are by overlap', () {
      final entries = PatternTranscript.parseCode(
        'N2ff R3 N2ff R3 N2ff R3 N2ff',
      ).entries;
      final plan = compile(entries, _mg, maxCommands: 1)!;
      final t = _target('N2ff R3 N2ff R3 N2ff R3 N2ff');
      final perCommand = [
        for (final s in plan.steps) pulseRuns(timeline(s.phrase.min)).length,
      ];
      expect(
        perCommand.fold<int>(0, (a, b) => a + b),
        isNot(pulseRuns(t.cells).length),
        reason: 'this plan has fewer pulses than the target',
      );
      expect(plan.pulseOwners, hasLength(4));
      expect(plan.pulseOwners, everyElement(0), reason: 'one command');
      expect(plan.pulseOwners, pulseOwnersOf(plan.steps, t.cells, t.first));
    });
  });

  group('the colouring shows exactly those owners', () {
    // Fourteen separate pulses a variety of rests apart: more than the eight
    // commands of the cap, so the plan's pulses do not add up to the target's.
    // Longer than 10 s, so it is played with the cap lifted.
    const code = 'N3mf R4 N3ff R3 N3mf R4 N4ff R1 N1ff R8 N3mf R1 N4ff R4 '
        'N3ff R8 N2mf R6 N1mf R6 N3mf R8 N1ff R1 N2ff R8 N2ff';

    test('the commands a delivery writes carry the compiler\'s owners', () {
      final entries = PatternTranscript.parseCode(code).entries;
      final plan = compile(entries, _mg, dynamicWeight: 1)!;
      final perCommand = [
        for (final s in plan.steps) pulseRuns(timeline(s.phrase.min)).length,
      ];
      final pulses = pulseRuns(timeline(entries)).length;
      expect(perCommand.fold<int>(0, (a, b) => a + b), isNot(pulses),
          reason: 'the overlap branch decided these owners');
      expect(plan.pulseOwners, hasLength(pulses));

      final s = tapsFromNotes(entries).copyWith(
        notes: entries.join(' '),
        profileId: _mg.id,
        profileVersion: _mg.version,
      );
      final commands = bandCommandOfEntries(s, entries, _mg, maxRuntime: null);
      var k = 0;
      for (var i = 0; i < entries.length; i++) {
        if (entries[i].note) {
          expect(commands[i], plan.pulseOwners[k], reason: 'note $k');
          k++;
        } else {
          expect(commands[i], isNull);
        }
      }
      expect(k, pulses);
    });

    test('and the painter draws each head in its command\'s colour', () {
      final entries = PatternTranscript.parseCode(code).entries;
      final s = tapsFromNotes(entries).copyWith(
        notes: entries.join(' '),
        profileId: _mg.id,
        profileVersion: _mg.version,
      );
      final commands = bandCommandOfEntries(s, entries, _mg, maxRuntime: null);
      final layout =
          ScoreLayout.fit(entries, width: 4000, commands: commands);
      // Command n is the colour 0xFF0000nn + 1: distinct, and back to n.
      Color of(int c) => Color(0xFF000000 + (c + 1));
      final rec = _HeadRecorder();
      HapticScorePainter(layout, ink: const Color(0xFF111111), commandColor: of)
          .paint(rec, ui.Size(4000, layout.height));
      final expected = [
        for (final g in layout.glyphs)
          if (!g.rest) of(commands[g.entryIndex]!).toARGB32(),
      ];
      expect(rec.heads, expected);
      expect(rec.heads.toSet().length, greaterThan(2),
          reason: 'more than one command is shown');
    });
  });
}

// The colour of every note head painted, in order.
class _HeadRecorder implements Canvas {
  final heads = <int>[];
  @override
  void drawOval(Rect r, Paint p) => heads.add(p.color.toARGB32());
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
