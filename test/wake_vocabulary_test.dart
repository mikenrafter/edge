// 8AF.6 D: wake on the band's measured vocabulary (not configurable, not in the
// pattern store), driven through the virtual MG band and the real
// HapticsService.
//
//   gradual, steady : buzz14 at every step
//   gradual, ramp   : click1 -> buzz14 -> buzz47 -> buzz47x2 -> buzz47x3, then
//                     it stays at buzz47x3
//   natural / smart : buzz47x3, 0 ms, buzz47x3, 0 ms, buzz47x3 on an MG,
//                     instead of RUN_ALARM; RUN_ALARM stays on gen4 and is the
//                     fallback when the plan cannot be delivered (not
//                     connected: the existing band-native alarm path)
//
// CONTRACT these tests pin that the spec leaves open (a new file,
// lib/haptics/wake_haptics.dart; the plans live in code):
//
//   String gradualPhraseId(GradualPattern pattern, int stepIndex)
//   const List<String> kNaturalWakePhraseIds   // 3 x 'buzz47x3', 0 ms apart
//   WakeHaptics(HapticsService haptics)
//     Future<BuzzDelivery> gradualStep(GradualPattern pattern, int stepIndex,
//         {required BuzzSequence perTap})
//         // MG: the one phrase of that step. No profile (gen4): [perTap] is
//         // delivered exactly as today (the step's own rhythm).
//     Future<BuzzDelivery> natural(
//         {required Future<BuzzDelivery> Function() runAlarm})
//         // MG and deliverable: the plan, [runAlarm] never called. Otherwise
//         // [runAlarm] (the band-native RUN_ALARM) is what runs.
//
// The AppState wiring and the Alarm caption are in
// wake_vocabulary_wiring_test.dart.

import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/haptics/wake_haptics.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';

import 'support/virtual_mg.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

(VirtualMgBand, HapticsService) _rig({String generation = 'gen5'}) {
  final band = VirtualMgBand(generation: generation);
  final svc = HapticsService(port: band, allowLong: () => false);
  band.onEvent = svc.onBandEvent;
  return (band, svc);
}

HapticPhrase _phrase(String id) => _mg.phrases.firstWhere((p) => p.id == id);

void main() {
  group('the plans, as phrase ids', () {
    test('steady is buzz14 at every step', () {
      for (var i = 0; i < 12; i++) {
        expect(gradualPhraseId(GradualPattern.steady, i), 'buzz14',
            reason: 'step $i');
      }
    });

    test('ramp climbs click1, buzz14, buzz47, buzz47x2, buzz47x3 and stays '
        'there', () {
      expect([
        for (var i = 0; i < 9; i++) gradualPhraseId(GradualPattern.ramp, i),
      ], [
        'click1',
        'buzz14',
        'buzz47',
        'buzz47x2',
        'buzz47x3',
        'buzz47x3',
        'buzz47x3',
        'buzz47x3',
        'buzz47x3',
      ]);
    });

    test('every id is a stable phrase of the measured MG vocabulary', () {
      final ids = {
        for (var i = 0; i < 6; i++) gradualPhraseId(GradualPattern.ramp, i),
        gradualPhraseId(GradualPattern.steady, 0),
        ...kNaturalWakePhraseIds,
      };
      for (final id in ids) {
        final p = _mg.phrases.where((p) => p.id == id);
        expect(p, hasLength(1), reason: id);
        expect(p.single.stable, isTrue, reason: id);
      }
    });

    test('natural wake is three buzz47x3', () {
      expect(kNaturalWakePhraseIds, ['buzz47x3', 'buzz47x3', 'buzz47x3']);
    });
  });

  group('gradual steps on the MG', () {
    // A step is cadence apart (3 min here): the band is idle and the rolling
    // command limit has room for every step of a run.
    const cadence = Duration(minutes: 3);
    final perTap = BuzzSequence([0, 600]);

    List<String> play(GradualPattern pattern, int steps) {
      final out = <String>[];
      fakeAsync((async) {
        final (band, svc) = _rig();
        final wake = WakeHaptics(svc);
        for (var i = 0; i < steps; i++) {
          final before = band.writes.length;
          wake.gradualStep(pattern, i, perTap: perTap);
          async.elapse(cadence);
          final w = band.writes.sublist(before);
          expect(w, hasLength(1), reason: 'step $i is one command');
          expect(w.single.played, isTrue, reason: 'step $i');
          out.add('${w.single.effects} x${w.single.loop}');
        }
      });
      return out;
    }

    test('steady plays the effect-14 single every step', () {
      final p = _phrase('buzz14');
      expect(play(GradualPattern.steady, 4),
          List.filled(4, '${p.effects} x${p.loop}'));
    });

    test('ramp plays the phrase of each step, then stays at the last', () {
      String of(String id) => '${_phrase(id).effects} x${_phrase(id).loop}';
      expect(play(GradualPattern.ramp, 7), [
        of('click1'),
        of('buzz14'),
        of('buzz47'),
        of('buzz47x2'),
        of('buzz47x3'),
        of('buzz47x3'),
        of('buzz47x3'),
      ]);
    });

    test('a step is no longer the per-tap buzz pair', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        WakeHaptics(svc).gradualStep(GradualPattern.ramp, 4, perTap: perTap);
        async.elapse(cadence);
        expect(band.writes.map((w) => w.effects),
            isNot(contains(const [47, 152])),
            reason: 'the old per-tap path writes the 47+152 pair per buzz');
        expect(band.writes, hasLength(1));
      });
    });
  });

  group('natural / smart wake on the MG', () {
    test('three buzz47x3, each written the instant the one before ended, '
        'and no RUN_ALARM', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        var runAlarm = 0;
        BuzzDelivery? done;
        WakeHaptics(svc).natural(runAlarm: () async {
          runAlarm++;
          return BuzzDelivery.complete;
        }).then((v) => done = v);
        async.elapse(const Duration(seconds: 30));
        expect(done, BuzzDelivery.complete);
        expect(runAlarm, 0, reason: 'delivered: the band-native alarm is not '
            'also run');
        final p = _phrase('buzz47x3');
        expect([for (final w in band.writes) '${w.effects} x${w.loop}'],
            List.filled(3, '${p.effects} x${p.loop}'));
        expect(band.played, hasLength(3));
        for (var i = 1; i < 3; i++) {
          final prev = band.writes[i - 1];
          expect(band.writes[i].atMs,
              prev.atMs + band.writeToFiredMs + prev.playback.envelopeMs,
              reason: 'a 0 ms gap');
        }
      });
    });

    test('it is one queue job: nothing else writes in the middle', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        WakeHaptics(svc).natural(runAlarm: () async => BuzzDelivery.complete);
        async.elapse(const Duration(milliseconds: 40));
        expect(svc.pending, 1);
        var seen = -1;
        svc.runJob(1, (job) async {
          seen = band.writes.length;
          return BuzzDelivery.complete;
        });
        async.elapse(const Duration(seconds: 30));
        expect(seen, 3);
      });
    });

    test('not connected: the plan cannot be delivered, RUN_ALARM runs once',
        () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        band.connected = false;
        var runAlarm = 0;
        BuzzDelivery? done;
        WakeHaptics(svc).natural(runAlarm: () async {
          runAlarm++;
          return BuzzDelivery.complete;
        }).then((v) => done = v);
        async.elapse(const Duration(seconds: 30));
        expect(band.writes, isEmpty);
        expect(runAlarm, 1);
        expect(done, BuzzDelivery.complete,
            reason: 'the result is the fallback\'s');
      });
    });
  });

  group('gen4 is unchanged', () {
    test('natural wake runs RUN_ALARM and writes no compiled command', () {
      fakeAsync((async) {
        final (band, svc) = _rig(generation: 'gen4');
        expect(svc.profile, isNull);
        var runAlarm = 0;
        WakeHaptics(svc).natural(runAlarm: () async {
          runAlarm++;
          return BuzzDelivery.complete;
        });
        async.elapse(const Duration(seconds: 30));
        expect(runAlarm, 1);
        expect(band.writes, isEmpty);
      });
    });

    test('a gradual step plays the step\'s own per-tap rhythm', () {
      fakeAsync((async) {
        final (band, svc) = _rig(generation: 'gen4');
        WakeHaptics(svc).gradualStep(GradualPattern.ramp, 3,
            perTap: BuzzSequence([0, 600, 1200]));
        async.elapse(const Duration(seconds: 10));
        expect(band.writes, hasLength(3));
        expect([for (final w in band.writes) w.effects], [
          [0],
          [0],
          [0],
        ]);
        expect([
          for (var i = 1; i < 3; i++)
            band.writes[i].atMs - band.writes[i - 1].atMs,
        ], [600, 600]);
      });
    });
  });

  group('not configurable, not in the pattern store', () {
    test('the module keeps its plans in code: no store, no settings', () {
      final f = File('lib/haptics/wake_haptics.dart');
      expect(f.existsSync(), isTrue);
      final src = f.readAsStringSync();
      expect(src, isNot(contains('pattern_store')));
      expect(src, isNot(contains('settings_repository')));
      expect(src, isNot(contains('systemKey')));
    });
  });
}
