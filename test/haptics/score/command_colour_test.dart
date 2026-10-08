// Colour = command (haptics display overhaul): every band command a pattern is
// sent as gets its own colour on the staff, so the wearer sees where one
// command ends and the next begins (a variable wait sits there) and how many
// commands the pattern spends of the budget. Notes of one command share its
// colour; rests stay ink. It holds on every device: a 4.0 has one verb and
// still sends one command per tap.
//
// The split is NOT computed again for the picture. `bandCommandOfEntries`
// (haptics/haptic_player.dart) reads the same `_resolve` as the delivery
// (`deliverBandSequence`), the budget (`bandSequenceCommands`) and the stored
// plan (`bandStepsFor`); the tests below pin that, behaviourally and in source.
//
// New API pinned:
//   bandCommandOfEntries(BuzzSequence s, List<PatternEntry> entries,
//       HapticDeviceProfile? profile, {Duration? maxRuntime})  -> List<int?>
//     One value per entry: the command index that plays it, null for a rest
//     and for a note no command plays. A command plays the next pulses of the
//     score (a pulse = a run of adjacent notes), as many as its phrase has;
//     the last command takes what is left. No profile: one pulse per tap.
//   commandColor(int command, P p) -> Color   (ui2/haptic_score.dart)
//   HapticScore(pattern, {unitMs, HapticDeviceProfile? profile, bool allowLong})

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart'
    show kMaxHapticRuntime;
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/score_layout.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/ui2/haptic_score.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show P, buildTheme;

import '../../support/dart_source_lexical.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

BuzzSequence _builtIn(String key) => builtInDefault(key)!.sequence;

List<PatternEntry> _entries(String code) =>
    PatternTranscript.parseCode(code).entries;

// A pattern with the notes [code] and a stored plan of [steps] for the MG.
BuzzSequence _stored(String code, List<BakedStep> steps) => BuzzSequence(
      const [0, 625],
      durationsMs: const [500, 500],
      notes: code,
      profileId: _mg.id,
      profileVersion: _mg.version,
      bakedSteps: steps,
    );

BakedStep _step(List<int> effects, {int loop = 1, int delay = 0}) =>
    BakedStep(effects: effects, loop: loop, delayMs: delay);

const _n = null;

List<int> _commandsUsed(List<int?> of) =>
    ({...of.whereType<int>()}.toList()..sort());

void main() {
  group('bandCommandOfEntries: which command plays each note (an MG)', () {
    test('a stored two-command plan: one note each, the rest between is null',
        () {
      final s = _stored('N4mf R2 N4mf', [_step([47]), _step([14], delay: 300)]);
      expect(bandCommandOfEntries(s, _entries('N4mf R2 N4mf'), _mg),
          [0, _n, 1]);
      expect(bandSequenceCommands(s, _mg), 2);
    });

    test('the stored plan wins over what the notes would compile to', () {
      // These notes compile to two buzzes, but the rule was saved as ONE
      // command (the arc, three pulses): the picture shows what is sent.
      final s = _stored('N4mf R2 N4mf', [_step([47, 152, 47])]);
      expect(bandSequenceCommands(s, _mg), 1);
      expect(bandCommandOfEntries(s, _entries('N4mf R2 N4mf'), _mg),
          [0, _n, 0]);
    });

    test('a command the profile has no phrase for plays one pulse', () {
      final s = _stored('N4* R4 N4*', [_step([99]), _step([99], delay: 300)]);
      expect(bandCommandOfEntries(s, _entries('N4* R4 N4*'), _mg),
          [0, _n, 1]);
    });

    test('SOS: a pair-of-pairs, three single buzzes, a pair-of-pairs', () {
      final s = _builtIn('preset.sos');
      final e = scoreEntriesOf(s);
      // pairx2 plays three pulses, buzz47x2 one each (x3), pairx2 three again.
      expect(bandCommandOfEntries(s, e, _mg),
          [0, _n, 0, _n, 0, _n, 1, _n, 2, _n, 3, _n, 4, _n, 4, _n, 4]);
      expect(bandSequenceCommands(s, _mg), 5);
    });

    test('Hip hip hooray: each pulse is its own click or buzz', () {
      final s = _builtIn('preset.hip_hip_hooray_x2');
      expect(bandCommandOfEntries(s, scoreEntriesOf(s), _mg),
          [0, _n, 1, _n, 2, _n, 3, _n, 4, _n, 5]);
    });

    test('a command that plays five pulses owns five notes', () {
      // Snooze cancelled: one long buzz, then arc1x3 for the five clicks.
      final s = _builtIn('alarm.snooze.cancelled');
      expect(bandCommandOfEntries(s, scoreEntriesOf(s), _mg),
          [0, _n, 1, _n, 1, _n, 1, _n, 1, _n, 1]);
    });

    test('adjacent notes are one pulse: a phrase of two clicks is one note',
        () {
      final s = _builtIn('breath.hold'); // 'N1mp N1mp', one click1 command
      expect(bandCommandOfEntries(s, scoreEntriesOf(s), _mg), [0, 0]);
    });

    test('a rest gets null at the start and the end too', () {
      final s = _stored('R4 N4* R4', [_step([47])]);
      expect(bandCommandOfEntries(s, _entries('R4 N4* R4'), _mg),
          [_n, 0, _n]);
    });

    test('a rule with no stored plan: the notes compile, the compile is read',
        () {
      // 12 + 4 rest sixteenths between the notes: two commands and a long wait.
      final notes = _entries('N4* R12 R4 N4*');
      final s = tapsFromNotes(notes).copyWith(
        notes: notes.join(' '),
        profileId: _mg.id,
        profileVersion: _mg.version,
      );
      expect(s.bakedSteps, isNull);
      expect(bandSequenceCommands(s, _mg), 2);
      expect(bandCommandOfEntries(s, notes, _mg), [0, _n, _n, 1]);
    });

    test('a tapped rhythm with no notes is compiled from its taps', () {
      final s = BuzzSequence(const [0, 500, 1000],
          durationsMs: const [125, 125, 125]);
      final got = bandCommandOfEntries(s, scoreEntriesOf(s), _mg);
      expect(got.length, 5);
      expect(got.whereType<int>().length, 3);
      expect(_commandsUsed(got).length, bandSequenceCommands(s, _mg));
    });

    test('the commands are in order along the score, one run each', () {
      for (final key in builtInKeys()) {
        final s = _builtIn(key);
        final got = bandCommandOfEntries(s, scoreEntriesOf(s), _mg);
        final sent = got.whereType<int>().toList();
        for (var i = 1; i < sent.length; i++) {
          expect(sent[i], greaterThanOrEqualTo(sent[i - 1]), reason: key);
          expect(sent[i] - sent[i - 1], lessThanOrEqualTo(1), reason: key);
        }
        final e = scoreEntriesOf(s);
        for (var i = 0; i < e.length; i++) {
          expect(got[i] == null, !e[i].note, reason: '$key entry $i');
        }
      }
    });
  });

  group('it is the delivery\'s own split', () {
    test('the commands it names are exactly the ones the budget counts', () {
      for (final key in builtInKeys()) {
        final s = _builtIn(key);
        final got = bandCommandOfEntries(s, scoreEntriesOf(s), _mg);
        final n = bandSequenceCommands(s, _mg);
        expect(_commandsUsed(got), [for (var i = 0; i < n; i++) i],
            reason: '$key: $n commands counted');
        expect(bandStepsFor(s, _mg)!.length, n, reason: key);
      }
    });

    test('the cap and the long-sequence switch change both the same way', () {
      // Twelve seconds of notes with no stored plan: capped, a 10 s rhythm is
      // sent tap by tap; uncapped it is compiled.
      final notes = _entries(List.filled(6, 'N12* R4').join(' '));
      final s = tapsFromNotes(notes).copyWith(
        notes: notes.join(' '),
        profileId: _mg.id,
        profileVersion: _mg.version,
      );
      for (final cap in [kMaxHapticRuntime, null]) {
        final n = bandSequenceCommands(s, _mg, maxRuntime: cap);
        final got = bandCommandOfEntries(s, notes, _mg, maxRuntime: cap);
        expect(_commandsUsed(got).length, n, reason: 'cap $cap');
      }
    });

    test('source: it goes through _resolve, like the three others', () {
      final src = File('lib/haptics/haptic_player.dart').readAsStringSync();
      for (final sig in [
        'List<int?> bandCommandOfEntries(',
        'int bandSequenceCommands(',
        'List<BakedStep>? bandStepsFor(',
        'Future<BuzzDelivery> deliverBandSequence(',
      ]) {
        expect(codeOnly(bodyOf(src, sig)), contains('_resolve('),
            reason: '$sig must read the one resolver');
      }
    });

    test('source: the picture does not compile or read the plan itself', () {
      for (final f in [
        'lib/ui2/haptic_score.dart',
        'lib/haptics/score_layout.dart',
      ]) {
        final code = codeOnly(File(f).readAsStringSync());
        expect(code, isNot(contains('compile(')), reason: f);
        expect(code, isNot(contains('planForTaps(')), reason: f);
        expect(code, isNot(contains('bakedSteps')), reason: f);
        expect(code, isNot(contains('bandStepsFor(')), reason: f);
      }
      expect(codeOnly(File('lib/ui2/haptic_score.dart').readAsStringSync()),
          contains('bandCommandOfEntries('));
    });
  });

  group('a 4.0 (no profile): one command per tap, still coloured', () {
    test('three taps are three commands', () {
      final s = BuzzSequence(const [0, 500, 1000],
          durationsMs: const [125, 125, 125]);
      expect(bandSequenceCommands(s, null), 3);
      expect(bandCommandOfEntries(s, scoreEntriesOf(s), null),
          [0, _n, 1, _n, 2]);
    });

    test('notes written for an MG are sent as the taps they make', () {
      // tapsFromNotes: a run of notes is one press, so N4 R4 N4 is two taps.
      final s = BuzzSequence(const [0, 1000],
          durationsMs: const [500, 500], notes: 'N4mf R4 N4mf');
      expect(bandCommandOfEntries(s, _entries('N4mf R4 N4mf'), null),
          [0, _n, 1]);
      final run = BuzzSequence(const [0],
          durationsMs: const [1000], notes: 'N4mf N4mf');
      expect(bandCommandOfEntries(run, _entries('N4mf N4mf'), null), [0, 0],
          reason: 'adjacent notes are one press');
    });

    test('SOS keeps eight taps: the ninth pulse is never sent', () {
      final s = _builtIn('preset.sos');
      expect(s.length, 8);
      expect(bandSequenceCommands(s, null), 8);
      final got = bandCommandOfEntries(s, scoreEntriesOf(s), null);
      expect(got, [0, _n, 1, _n, 2, _n, 3, _n, 4, _n, 5, _n, 6, _n, 7, _n, _n]);
    });

    test('a profile that cannot play the rhythm falls back to taps, the same '
        'as the delivery', () {
      // Notes of another device's profile: the band plays the taps.
      final s = BuzzSequence(const [0, 1000],
          durationsMs: const [500, 500],
          notes: 'N4mf R4 N4mf',
          profileId: 'some-other-band');
      expect(bandSequenceCommands(s, _mg), isNonZero);
      expect(_commandsUsed(bandCommandOfEntries(s, _entries('N4mf R4 N4mf'), _mg))
              .length,
          bandSequenceCommands(s, _mg));
    });
  });

  test('lexicon: the new terms are defined where AGENTS.md section 6 says', () {
    final lexicon = File('docs/lexicon.md').readAsStringSync();
    for (final term in ['Band command', 'Pulse', 'Score']) {
      expect(lexicon, contains('**$term**'), reason: 'docs/lexicon.md: $term');
    }
  });

  group('the palette', () {
    final themes = {'light': const P(false), 'dark': const P(true)};

    int cycle(P p) {
      for (var i = 1; i < 40; i++) {
        if (commandColor(i, p) == commandColor(0, p)) return i;
      }
      fail('the palette never cycles');
    }

    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
      return (hi + .05) / (lo + .05);
    }

    for (final e in themes.entries) {
      final p = e.value;
      group(e.key, () {
        test('at least six colours, then it cycles', () {
          final n = cycle(p);
          expect(n, greaterThanOrEqualTo(6));
          for (var i = 0; i < 3 * n; i++) {
            expect(commandColor(i, p), commandColor(i % n, p));
          }
        });

        test('every colour in a cycle is different, so neighbours always are',
            () {
          final n = cycle(p);
          expect({for (var i = 0; i < n; i++) commandColor(i, p)}, hasLength(n));
          for (var i = 0; i < 3 * n; i++) {
            expect(commandColor(i, p), isNot(commandColor(i + 1, p)));
          }
        });

        test('each is told apart from the others at a glance', () {
          final n = cycle(p);
          for (var i = 0; i < n; i++) {
            for (var j = i + 1; j < n; j++) {
              final a = commandColor(i, p), b = commandColor(j, p);
              final d = ((a.r - b.r) * 255) * ((a.r - b.r) * 255) +
                  ((a.g - b.g) * 255) * ((a.g - b.g) * 255) +
                  ((a.b - b.b) * 255) * ((a.b - b.b) * 255);
              expect(d, greaterThan(30 * 30), reason: 'colours $i and $j');
            }
          }
        });

        test('each has 3:1 contrast against the card it is drawn on', () {
          for (var i = 0; i < cycle(p); i++) {
            expect(contrast(commandColor(i, p), p.card),
                greaterThanOrEqualTo(3.0),
                reason: 'colour $i on ${e.key}');
          }
        });

        test('none is the ink the rests are drawn in', () {
          for (var i = 0; i < cycle(p); i++) {
            expect(commandColor(i, p), isNot(p.ink));
            expect(commandColor(i, p), isNot(p.ink2));
          }
        });

        test('opaque', () {
          for (var i = 0; i < cycle(p); i++) {
            expect(commandColor(i, p).a, 1.0);
          }
        });
      });
    }

    test('it is drawn from the theme\'s own accents, not a private palette',
        () {
      final src = codeOnly(File('lib/ui2/haptic_score.dart').readAsStringSync());
      expect(src, contains('C.'), reason: 'theme accents (C.blue ...)');
      expect(RegExp(r'Color\(0x[0-9A-Fa-f]{8}\)').hasMatch(src), isFalse,
          reason: 'no hand-picked hex colours in the painter');
    });
  });

  group('what the staff draws', () {
    const staff = ValueKey('haptic-score-staff');

    Future<void> pump(WidgetTester t, BuzzSequence s,
        {HapticDeviceProfile? profile,
        Brightness brightness = Brightness.light,
        double width = 360}) {
      return t.pumpWidget(MaterialApp(
        theme: buildTheme(brightness),
        home: Scaffold(
          body: Center(
            child: SizedBox(
                width: width, child: HapticScore(s, profile: profile)),
          ),
        ),
      ));
    }

    // The note heads are drawn with drawOval: in order, one oval per head, in
    // the colour of its command.
    dynamic heads(P p, List<int> commands) {
      final m = paints;
      for (final c in commands) {
        // Paint keeps 8 bits per channel: compare as ARGB.
        final want = commandColor(c, p).toARGB32();
        m.something((method, args) =>
            method == #drawOval && (args[1] as Paint).color.toARGB32() == want);
      }
      return m;
    }

    dynamic anyHeadIn(Color ink) => paints
      ..something((method, args) =>
          method == #drawOval &&
          (args[1] as Paint).color.toARGB32() == ink.toARGB32());

    testWidgets('an MG: two commands, two colours, in order', (t) async {
      final s = _stored('N4mf R2 N4mf', [_step([47]), _step([14], delay: 300)]);
      await pump(t, s, profile: _mg);
      expect(t.renderObject(find.byKey(staff)), heads(const P(false), [0, 1]));
      expect(t.renderObject(find.byKey(staff)),
          isNot(anyHeadIn(const P(false).ink)),
          reason: 'no note is left in ink');
    });

    testWidgets('notes of one command share its colour (SOS, five commands)',
        (t) async {
      await pump(t, _builtIn('preset.sos'), profile: _mg);
      // Ten heads: the dotted quarter that crosses the first bar line is two
      // tied pieces of one command.
      expect(t.renderObject(find.byKey(staff)),
          heads(const P(false), [0, 0, 0, 1, 1, 2, 3, 4, 4, 4]));
    });

    testWidgets('a 4.0 still colours by command: one colour per tap', (t) async {
      final s = BuzzSequence(const [0, 500, 1000],
          durationsMs: const [125, 125, 125]);
      await pump(t, s);
      expect(t.renderObject(find.byKey(staff)), heads(const P(false), [0, 1, 2]));
    });

    testWidgets('a 4.0 with notes: a colour per press', (t) async {
      final s = BuzzSequence(const [0, 1000],
          durationsMs: const [500, 500], notes: 'N4mf R4 N4mf');
      await pump(t, s);
      expect(t.renderObject(find.byKey(staff)), heads(const P(false), [0, 1]));
    });

    testWidgets('dark theme: the same commands in the dark palette', (t) async {
      final s = _stored('N4mf R2 N4mf', [_step([47]), _step([14], delay: 300)]);
      await pump(t, s, profile: _mg, brightness: Brightness.dark);
      expect(t.renderObject(find.byKey(staff)), heads(const P(true), [0, 1]));
    });

    testWidgets('the layout the painter draws carries the commands', (t) async {
      final s = _builtIn('preset.sos');
      await pump(t, s, profile: _mg);
      final layout = (t.widget<CustomPaint>(find.byKey(staff)).painter!
              as HapticScorePainter)
          .layout;
      expect([for (final g in layout.glyphs.where((g) => !g.rest)) g.command],
          [0, 0, 0, 1, 1, 2, 3, 4, 4, 4]);
      expect(
          [for (final g in layout.glyphs.where((g) => g.rest)) g.command],
          everyElement(isNull));
    });

    testWidgets('the number of colours drawn is the number the budget counts',
        (t) async {
      for (final key in ['preset.two_pulses', 'preset.sos', 'tasker.6']) {
        final s = _builtIn(key);
        await pump(t, s, profile: _mg);
        final layout = (t.widget<CustomPaint>(find.byKey(staff)).painter!
                as HapticScorePainter)
            .layout;
        final used = {
          for (final g in layout.glyphs)
            if (g.command != null) g.command,
        };
        expect(used.length, bandSequenceCommands(s, _mg), reason: key);
      }
    });
  });
}
