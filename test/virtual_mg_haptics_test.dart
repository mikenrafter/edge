// The virtual MG's haptics (test/support/virtual_mg.dart, VirtualMgBand) against
// what the lab logs showed. The band's behaviour is parameterised in code and
// nothing is read from the logs at run time; these tests are the check that the
// parameters still say what docs/hardware/whoop-mg-haptics-and-ecg.md says
// (L3 events and busy/deaf rules, L4 envelopes, L6 phrases and gap rows).

import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';

import 'support/virtual_mg.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;
const int _unit = 125;

MgPlayback _pb(List<int> effects, int loop, {Random? jitter}) =>
    VirtualMgBand.playbackOf(effects, loop, jitter: jitter);

void main() {
  group('event envelopes (L4: event 60 to event 100)', () {
    // The documented ranges, ms.
    final ranges = <String, (List<int>, int, int, int)>{
      '47 alone 0.77-1.03 s': (const [47], 1, 770, 1030),
      '14 alone 0.53-0.91 s': (const [14], 1, 530, 910),
      '1 alone 0.22-0.61 s': (const [1], 1, 220, 610),
      'pair 47+152 1.07-1.36 s': (const [47, 152], 1, 1070, 1360),
    };

    for (final e in ranges.entries) {
      final (effects, loop, lo, hi) = e.value;
      test('${e.key}: the midpoint, and every seeded draw, is inside', () {
        expect(_pb(effects, loop).envelopeMs, inInclusiveRange(lo, hi));
        for (var seed = 0; seed < 50; seed++) {
          expect(_pb(effects, loop, jitter: Random(seed)).envelopeMs,
              inInclusiveRange(lo, hi));
        }
      });
    }

    test('the pair with loop 2 and 3 is about 1.96 s and 2.0 s, not a whole '
        'repeat', () {
      expect(_pb(const [47, 152], 2).envelopeMs, closeTo(1960, 30));
      expect(_pb(const [47, 152], 3).envelopeMs, closeTo(2000, 30));
      expect(_pb(const [47, 152], 2).envelopeMs,
          lessThan(2 * _pb(const [47, 152], 1).envelopeMs));
    });

    test('a single effect with loop 2-3 plays barely longer than loop 1', () {
      for (final e in const [47, 14, 1]) {
        final one = _pb([e], 1).envelopeMs;
        expect(_pb([e], 2).envelopeMs - one, inInclusiveRange(0, 300));
        expect(_pb([e], 3).envelopeMs - one, inInclusiveRange(0, 300));
      }
    });

    test('listed slots add up, and 152 is a buzz that takes time', () {
      expect(_pb(const [47, 152, 47], 1).envelopeMs,
          _pb(const [47], 1).envelopeMs * 2 + _pb(const [152], 1).envelopeMs);
      expect(_pb(const [152], 1).envelopeMs, greaterThan(200));
    });

    test('by default the length is deterministic; a seed varies it inside '
        'the range and repeats for the same seed', () {
      expect(_pb(const [47], 1).envelopeMs, _pb(const [47], 1).envelopeMs);
      final a = [for (var i = 0; i < 5; i++) _pb(const [47], 1, jitter: Random(3 + i)).envelopeMs];
      final b = [for (var i = 0; i < 5; i++) _pb(const [47], 1, jitter: Random(3 + i)).envelopeMs];
      expect(a, b);
      expect(a.toSet().length, greaterThan(1));
    });
  });

  group('events and the busy/deaf rules (L3)', () {
    test('event 60 comes ~15 ms after an accepted write, event 100 when '
        'playback ends', () {
      fakeAsync((async) {
        final band = VirtualMgBand();
        band.buzzMaverickPattern(const [47], 1);
        async.elapse(const Duration(seconds: 3));
        final ev = band.events;
        expect([for (final e in ev) e.$2.eventId], [60, 100]);
        expect(ev[0].$1, 15);
        final gap = ev[1].$1 - ev[0].$1;
        expect(gap, _pb(const [47], 1).envelopeMs);
        expect(gap, inInclusiveRange(770, 1030));
      });
    });

    test('the pair (the engine\'s own buzz) has its 60-to-100 in 1.08-1.50 s',
        () {
      fakeAsync((async) {
        final band = VirtualMgBand();
        band.buzzBand();
        async.elapse(const Duration(seconds: 3));
        final gap = band.events[1].$1 - band.events[0].$1;
        expect(gap, inInclusiveRange(1080, 1500));
      });
    });

    test('a write during playback is answered pending and not played, and '
        'the next one is ignored for ~1.0-1.27 s', () {
      fakeAsync((async) {
        final band = VirtualMgBand();
        band.buzzMaverickPattern(const [47], 1); // plays, busy to ~915
        async.elapse(const Duration(milliseconds: 300));
        band.buzzMaverickPattern(const [47], 1); // during: swallowed
        async.elapse(const Duration(milliseconds: 100));
        band.buzzMaverickPattern(const [47], 1); // deaf: no reply
        async.elapse(const Duration(seconds: 5));
        expect([for (final w in band.writes) w.played], [true, false, false]);
        expect([for (final w in band.writes) w.reply],
            ['pending', 'pending', null]);
        expect(band.events.where((e) => e.$2.eventId == 60), hasLength(1));
      });
    });

    test('the deaf window ends: 0.95 s later still ignored, 1.27 s later '
        'played', () {
      for (final (later, plays) in [(950, false), (1270, true)]) {
        fakeAsync((async) {
          final band = VirtualMgBand();
          band.buzzMaverickPattern(const [47], 1);
          async.elapse(const Duration(milliseconds: 100));
          band.buzzMaverickPattern(const [47], 1); // swallowed at ~100 ms
          async.elapse(Duration(milliseconds: later));
          band.buzzMaverickPattern(const [47], 1);
          async.elapse(const Duration(seconds: 5));
          // At 100 + 950 = 1050 the first has ended (915) but the band is deaf.
          expect(band.writes.last.played, plays, reason: '$later ms after');
        });
      }
    });

    test('a write after the 100 plays, even 30 ms after; one 20 ms before it '
        'is dropped', () {
      for (final (offset, plays) in [(30, true), (-20, false)]) {
        fakeAsync((async) {
          final band = VirtualMgBand();
          band.buzzMaverickPattern(const [47], 1);
          final ends = 15 + _pb(const [47], 1).envelopeMs;
          async.elapse(Duration(milliseconds: ends + offset));
          band.buzzMaverickPattern(const [47], 1);
          async.elapse(const Duration(seconds: 5));
          expect(band.writes.last.played, plays, reason: 'offset $offset');
        });
      }
    });

    test('late-backlog mode delivers OLD events in a burst, which are not '
        'live', () {
      fakeAsync((async) {
        final band = VirtualMgBand(backlogAfterMs: 200);
        band.buzzMaverickPattern(const [47], 1);
        async.elapse(const Duration(seconds: 3));
        final old = band.events.where((e) => !e.$2.isLive).toList();
        final live = band.events.where((e) => e.$2.isLive).toList();
        expect(old, hasLength(6));
        expect(live.map((e) => e.$2.eventId), [60, 100]);
        expect(old.every((e) => e.$2.age! > const Duration(seconds: 15)), isTrue);
      });
    });

    test('gen4: a short pulse, no events, never a pattern command', () {
      fakeAsync((async) {
        final band = VirtualMgBand(generation: 'gen4');
        band.buzzBand();
        expect(band.buzzMaverickPattern(const [47], 1), completion(isFalse));
        async.elapse(const Duration(seconds: 3));
        expect(band.writes, hasLength(1));
        expect(band.writes.single.played, isTrue);
        expect(band.events, isEmpty);
      });
    });
  });

  group('every whoopMg phrase through the emulator (L6)', () {
    for (final p in _mg.phrases) {
      test('${p.id}: felt span within ${p.unitsMin}..${p.unitsMax} units '
          '(+-1), event 100 within the player\'s own wait', () {
        final pb = _pb(p.effects, p.loop);
        expect(pb.feltMs,
            inInclusiveRange((p.unitsMin - 1) * _unit, (p.unitsMax + 1) * _unit));
        // The event envelope is at least the felt span and ends within the
        // 1.5 s the player waits past a phrase's longest felt span.
        expect(pb.envelopeMs, greaterThanOrEqualTo(pb.feltMs));
        expect(pb.envelopeMs, lessThanOrEqualTo(p.unitsMax * _unit + 1500));

        // And through the band itself: one play, its events and span.
        fakeAsync((async) {
          final band = VirtualMgBand();
          band.buzzMaverickPattern(p.effects, p.loop);
          async.elapse(const Duration(seconds: 10));
          expect(band.events.map((e) => e.$2.eventId), [60, 100]);
          expect(band.events[1].$1 - band.events[0].$1, pb.envelopeMs);
        });
      });
    }
  });

  group('gap rows: writing after the 100 with a delay (L6)', () {
    // Silence felt between two commands: the second one's event 60 less the
    // first one's felt end. Gap tests 33-40 wrote effect 14 then 47.
    int silenceMs(int firstEffect, int secondEffect, int delayMs) {
      late int silence;
      fakeAsync((async) {
        final band = VirtualMgBand();
        band.buzzMaverickPattern([firstEffect], 1);
        final w = band.writes.single;
        final endsAt = 15 + w.playback.envelopeMs;
        async.elapse(Duration(milliseconds: endsAt + delayMs));
        band.buzzMaverickPattern([secondEffect], 1);
        async.elapse(const Duration(seconds: 5));
        final second = band.writes[1];
        expect(second.played, isTrue);
        final firstFeltEnd = 15 + w.playback.feltMs;
        silence = second.firedMs(15) - firstFeltEnd;
      });
      return silence;
    }

    for (final g in _mg.gaps) {
      test('delay ${g.delayMs} ms${g.stable ? '' : ' (unstable row)'}: silence '
          'within ${g.minUnits}..${g.maxUnits} units (+-1)', () {
        for (final first in const [14, 47]) {
          final s = silenceMs(first, 47, g.delayMs);
          expect(s,
              inInclusiveRange((g.minUnits - 1) * _unit, (g.maxUnits + 1) * _unit),
              reason: 'after $first');
        }
      });
    }
  });

  group('the older command-time model still serves the lab probe tests', () {
    test('command(atMs) with no playMs keeps its busyMs', () {
      final b = VirtualMgHaptics();
      expect(b.command(0), 'pending');
      expect(b.command(1400), 'pending'); // still busy: swallowed
      expect(b.played, 1);
    });

    test('playMs sets how long that command keeps the band busy', () {
      final b = VirtualMgHaptics();
      b.command(0, playMs: 500);
      b.command(600);
      expect(b.played, 2);
    });
  });
}
