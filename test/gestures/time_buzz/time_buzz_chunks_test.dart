// "Tell the time": the rhythm as band jobs. toBuzzChunks maps the encoder's
// short / long / click onto the band's measured vocabulary (a baked plan for
// the profile) or, for a band with no profile (a 4.0), onto per-tap sequences.
//
// Why chunks: a BuzzSequence holds at most 8 commands (BuzzSequence.maxBakedSteps
// and maxBuzzes) and a 12 PM hour alone is 12 buzzes, so a time is a LIST of
// sequences played back to back inside one gesture. The separator that sits at
// a chunk boundary cannot be a step delay (the player ignores the first step's
// delay), so each chunk carries it as `waitBeforeMs`.
//
// The vocabulary mapping pinned here (MG, HapticDeviceProfile.whoopMg):
//   short  buzz14    [14] x1  ~0.4 s, f
//   long   buzz47x2  [47] x2   0.75 s, ff
//   click  click1    [1]  x1   0.25 s, soft; the lighter quarter tick
// Two or three of one waveform are never merged into a looped phrase (buzz14x2
// and the like play as ONE long note), so every buzz is one command.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/time_buzz.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

const _sh = TimeBuzzElement.short;
const _lg = TimeBuzzElement.long;
const _ck = TimeBuzzElement.click;
const _g = TimeBuzzElement.gap;
const _ps = TimeBuzzElement.pause;

List<TimeBuzzElement> _e(String s) => [
      for (final t in s.trim().split(RegExp(r'\s+')))
        switch (t) {
          'S' => _sh,
          'L' => _lg,
          'C' => _ck,
          'g' => _g,
          'P' => _ps,
          _ => throw ArgumentError('bad token $t'),
        },
    ];

String _rep(String tok, int n) => List.filled(n, tok).join(' g ');

DateTime _t(int h, int m) => DateTime(2026, 10, 7, h, m);

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

// (effects, loop) of a vocabulary phrase.
(List<int>, int) _phrase(String id) {
  final ph = _mg.phrases.firstWhere((p) => p.id == id);
  return (ph.effects, ph.loop);
}

typedef _Cmd = (List<int>, int);

String _show(List<_Cmd> c) => c.map((x) => '${x.$1}x${x.$2}').join(' ');

// The commands of [chunks] on the MG, in order.
List<_Cmd> _mgCommands(List<TimeBuzzChunk> chunks) => [
      for (final c in chunks)
        for (final s in c.sequence.bakedSteps!) (s.effects, s.loop),
    ];

// The commands the elements ask for, as vocabulary phrases.
List<_Cmd> _wanted(List<TimeBuzzElement> es) => [
      for (final e in es)
        if (e == _sh)
          _phrase('buzz14')
        else if (e == _lg)
          _phrase('buzz47x2')
        else if (e == _ck)
          _phrase('click1'),
    ];

// How long the silence is before each command (the first is 0): a step's delay
// inside a chunk, the chunk's waitBeforeMs at its start.
List<int> _waits(List<TimeBuzzChunk> chunks) => [
      for (final c in chunks) ...[
        c.waitBeforeMs,
        for (final s in c.sequence.bakedSteps!.skip(1)) s.delayMs,
      ],
    ];

// What kind of silence the elements put before each command: 'pause', 'gap' or
// 'first'.
List<String> _kinds(List<TimeBuzzElement> es) {
  final out = <String>[];
  var sep = 'first';
  for (final e in es) {
    if (e == _ps) {
      sep = 'pause';
    } else if (e == _g) {
      if (sep != 'pause') sep = 'gap';
    } else {
      out.add(sep);
      sep = 'gap';
    }
  }
  return out;
}

void main() {
  group('on the MG vocabulary (a baked plan per chunk)', () {
    test('the phrases the mapping names exist and are what the doc says', () {
      expect(_show([_phrase('buzz14')]), '[14]x1');
      expect(_show([_phrase('buzz47x2')]), '[47]x2');
      expect(_show([_phrase('click1')]), '[1]x1');
    });

    test('15:08 count is 3 long then a click: one chunk, one baked plan for '
        'the profile', () {
      final es = _e('L g L g L P C');
      final chunks = toBuzzChunks(es, _mg);
      expect(chunks, hasLength(1));
      final s = chunks.single.sequence;
      expect(s.profileId, _mg.id);
      expect(s.profileVersion, _mg.version);
      expect(s.bakedSteps, isNotNull);
      expect(_show(_mgCommands(chunks)),
          _show([_phrase('buzz47x2'), _phrase('buzz47x2'), _phrase('buzz47x2'), _phrase('click1')]));
    });

    test('the delays: 0 first, a gap between buzzes of a group, exactly 1000 '
        'after a pause', () {
      final chunks = toBuzzChunks(_e('L g L g L P C'), _mg);
      final steps = chunks.single.sequence.bakedSteps!;
      expect(chunks.single.waitBeforeMs, 0);
      expect(steps[0].delayMs, 0);
      for (final i in [1, 2]) {
        expect(steps[i].delayMs, greaterThanOrEqualTo(_mg.minVibrationGapMs),
            reason: 'step $i: a gap is at least the vocabulary minimum');
        expect(steps[i].delayMs, lessThan(kTimeBuzzPauseMs),
            reason: 'step $i: a gap is shorter than the pause');
      }
      expect(steps[3].delayMs, kTimeBuzzPauseMs);
    });

    test('binary 15:08: short, short, long, long, the PM long, the AM/PM '
        'pause, a click', () {
      final chunks = toBuzzChunks(
          encodeTime(_t(15, 8), TimeBuzzMode.binary), _mg);
      expect(_show(_mgCommands(chunks)), _show(_wanted(_e('S g S g L g L P L P C'))));
    });

    test('a time of 8 commands or fewer is one chunk', () {
      for (final es in [
        _e('S g S g S'),
        _e('L g L g L P C'),
        encodeTime(_t(15, 8), TimeBuzzMode.binary),
        _e(_rep('L', 8)),
      ]) {
        expect(toBuzzChunks(es, _mg), hasLength(1),
            reason: 'bandCommandsFor = ${bandCommandsFor(es)}');
      }
    });

    test('12:44 count (15 commands) is split into chunks of at most 8, in '
        'order, with every command kept', () {
      final es = encodeTime(_t(12, 44), TimeBuzzMode.count);
      final chunks = toBuzzChunks(es, _mg);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.sequence.bakedSteps!.length,
            inInclusiveRange(1, BuzzSequence.maxBakedSteps));
        expect(c.sequence.profileId, _mg.id);
      }
      expect(_show(_mgCommands(chunks)), _show(_wanted(es)));
      expect(_mgCommands(chunks), hasLength(15));
    });

    test('the silences survive the split: the first command waits 0, every '
        'pause is 1000, every gap is at least the minimum and under the '
        'pause (at a chunk boundary too)', () {
      for (final mode in TimeBuzzMode.values) {
        for (final (h, m) in [(12, 44), (0, 53), (10, 53), (22, 38), (15, 8), (3, 0)]) {
          final es = encodeTime(_t(h, m), mode);
          final chunks = toBuzzChunks(es, _mg);
          final waits = _waits(chunks);
          final kinds = _kinds(es);
          final at = '$h:$m in $mode';
          expect(waits, hasLength(kinds.length), reason: at);
          expect(chunks.first.waitBeforeMs, 0, reason: at);
          for (final c in chunks) {
            expect(c.sequence.bakedSteps!.first.delayMs, 0,
                reason: '$at: a chunk\'s first step has no delay of its own');
          }
          for (var i = 0; i < kinds.length; i++) {
            switch (kinds[i]) {
              case 'first':
                expect(waits[i], 0, reason: '$at command $i');
              case 'pause':
                expect(waits[i], kTimeBuzzPauseMs, reason: '$at command $i');
              default:
                expect(waits[i], greaterThanOrEqualTo(_mg.minVibrationGapMs),
                    reason: '$at command $i');
                expect(waits[i], lessThan(kTimeBuzzPauseMs),
                    reason: '$at command $i');
            }
          }
        }
      }
    });

    test('the commands written equal bandCommandsFor, for every hour in every '
        'mode (and no chunk is over the limit)', () {
      for (final mode in TimeBuzzMode.values) {
        for (var h = 0; h < 24; h++) {
          for (final m in [0, 8, 53]) {
            final es = encodeTime(_t(h, m), mode);
            final chunks = toBuzzChunks(es, _mg);
            expect(_mgCommands(chunks), hasLength(bandCommandsFor(es)),
                reason: '$h:$m in $mode');
            expect(_show(_mgCommands(chunks)), _show(_wanted(es)),
                reason: '$h:$m in $mode');
            for (final c in chunks) {
              expect(c.sequence.bakedSteps!.length,
                  lessThanOrEqualTo(BuzzSequence.maxBakedSteps));
            }
          }
        }
      }
    });

    test('nothing to play is no chunks', () {
      expect(toBuzzChunks(const [], _mg), isEmpty);
      expect(toBuzzChunks(const [], null), isEmpty);
    });
  });

  group('with no profile (a 4.0): per-tap sequences', () {
    // The gap before the tap at [i] of a sequence, from its offsets.
    int releaseGap(BuzzSequence s, int i) =>
        s.offsetsMs[i] - s.offsetsMs[i - 1] - s.durationsMs[i - 1];

    test('no baked plan, no profile: one tap per buzz', () {
      final chunks = toBuzzChunks(_e('L g L g L P C'), null);
      expect(chunks, hasLength(1));
      final s = chunks.single.sequence;
      expect(s.bakedSteps, isNull);
      expect(s.profileId, isNull);
      expect(s.length, 4);
    });

    test('long holds longer than short, short holds longer than a click', () {
      final s = toBuzzChunks(
              encodeTime(_t(15, 8), TimeBuzzMode.binary), null)
          .single
          .sequence; // S S L L L C
      expect(s.length, 6);
      final d = s.durationsMs;
      expect(d[0], d[1], reason: 'the two shorts hold the same');
      expect(d[2], d[3]);
      expect(d[3], d[4], reason: 'a long is a long, the PM marker included');
      expect(d[2], greaterThan(d[0]), reason: 'long > short');
      expect(d[0], greaterThan(d[5]), reason: 'short > click');
      expect(d[5], greaterThanOrEqualTo(0));
    });

    test('release gaps: a pause is exactly 1000 ms, a gap is audible (>= '
        '100 ms) and under the pause', () {
      final s = toBuzzChunks(_e('L g S P C g C'), null).single.sequence;
      expect(s.length, 4);
      expect(releaseGap(s, 1), inInclusiveRange(100, kTimeBuzzPauseMs - 1));
      expect(releaseGap(s, 2), kTimeBuzzPauseMs);
      expect(releaseGap(s, 3), inInclusiveRange(100, kTimeBuzzPauseMs - 1));
    });

    test('12:44 is split into sequences of at most 8 taps, nothing lost, and '
        'the silences survive the split', () {
      for (final mode in TimeBuzzMode.values) {
        for (final (h, m) in [(12, 44), (0, 53), (10, 53), (15, 8)]) {
          final es = encodeTime(_t(h, m), mode);
          final chunks = toBuzzChunks(es, null);
          final at = '$h:$m in $mode';
          var taps = 0;
          final waits = <int>[];
          for (final c in chunks) {
            final s = c.sequence;
            expect(s.length, inInclusiveRange(1, BuzzSequence.maxBuzzes),
                reason: at);
            taps += s.length;
            waits.add(c.waitBeforeMs);
            for (var i = 1; i < s.length; i++) {
              waits.add(releaseGap(s, i));
            }
          }
          expect(taps, bandCommandsFor(es), reason: at);
          expect(chunks.first.waitBeforeMs, 0, reason: at);
          final kinds = _kinds(es);
          expect(waits, hasLength(kinds.length), reason: at);
          for (var i = 0; i < kinds.length; i++) {
            switch (kinds[i]) {
              case 'first':
                expect(waits[i], 0, reason: '$at tap $i');
              case 'pause':
                expect(waits[i], kTimeBuzzPauseMs, reason: '$at tap $i');
              default:
                expect(waits[i], inInclusiveRange(100, kTimeBuzzPauseMs - 1),
                    reason: '$at tap $i');
            }
          }
        }
      }
    });
  });
}
