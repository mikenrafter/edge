// 8AF.6 C: the gesture response vocabulary on a WHOOP MG, driven through the
// virtual MG band and the real HapticsService (as test/haptics/
// haptics_service_test.dart and haptic_play_start_test.dart wire it).
//
// Spec C: the FIRST buzz of a response is gesture.start (today's pair), every
// later buzz of the same response is gesture.followUp (one fastest single,
// buzz14), chained with the fastest gap (0 ms) in ONE queue job; the final
// "action done" ack is gesture.confirm (buzz47). A user-customised built-in is
// what plays. gen4 (no profile) keeps today's per-tap path.
//
// CONTRACT these tests pin that the spec leaves open (a new file,
// lib/haptics/gesture_cues.dart):
//
//   GestureCues({required HapticsService haptics,
//                BuzzSequence? Function(String systemKey)? patternFor})
//   Future<BuzzDelivery> response(int pulses)  // start + (pulses - 1) follow-ups
//   Future<BuzzDelivery> confirm()             // the action-done ack
//
// [patternFor] is how the system pattern the wearer customised reaches it (the
// keys are the spec's 'gesture.start' / 'gesture.followUp' / 'gesture.confirm');
// null (or no callback) means "the built-in default". The wiring through
// AppState._ecgTapBuzz, ackTap and the ECG session is in
// gesture_cues_wiring_test.dart.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/gestures/tap_ack.dart';
import 'package:openstrap_edge/haptics/gesture_cues.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

import '../support/virtual_mg.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

/// A stored (customised) system pattern: [steps] as stored commands, so what
/// plays is exactly this whatever the compiler would pick.
BuzzSequence _custom(List<(List<int>, int, int)> steps) => BuzzSequence(
      const [0],
      durationsMs: const [500],
      profileId: _mg.id,
      profileVersion: _mg.version,
      bakedSteps: [
        for (final (effects, loop, delay) in steps)
          BakedStep(effects: effects, loop: loop, delayMs: delay),
      ],
    );

(VirtualMgBand, HapticsService) _rig({
  String generation = 'gen5',
}) {
  final band = VirtualMgBand(generation: generation);
  final svc = HapticsService(port: band, allowLong: () => false);
  band.onEvent = svc.onBandEvent;
  return (band, svc);
}

/// What the band was asked to play, as "effects xloop".
List<String> _cmds(VirtualMgBand b) =>
    [for (final w in b.writes) '${w.effects} x${w.loop}'];

/// Every command played, none swallowed, and each one written only once the
/// band was done with the one before it.
void _expectNoOverlap(VirtualMgBand b) {
  expect(b.writes, isNotEmpty);
  expect(b.played, hasLength(b.writes.length),
      reason: 'the band swallowed a command: two overlapped');
  for (var i = 1; i < b.writes.length; i++) {
    final prev = b.writes[i - 1];
    final end = prev.atMs + b.writeToFiredMs + prev.playback.envelopeMs;
    expect(b.writes[i].atMs, greaterThanOrEqualTo(end),
        reason: 'command ${i + 1} was written while command $i still played');
  }
}

/// The fastest gap (0 ms): each command is written the instant the band's
/// ended event for the one before it arrives, with no wait added.
void _expectZeroGap(VirtualMgBand b) {
  for (var i = 1; i < b.writes.length; i++) {
    final prev = b.writes[i - 1];
    final ended = prev.atMs + b.writeToFiredMs + prev.playback.envelopeMs;
    expect(b.writes[i].atMs, ended,
        reason: 'command ${i + 1} should follow the ended event with a 0 ms '
            'gap (the fastest the vocabulary measured)');
  }
}

StrapEvent _tap() {
  final now = DateTime.now();
  return StrapEvent(
    eventId: 14,
    tsEpoch: now.millisecondsSinceEpoch ~/ 1000,
    receivedAt: now,
    hex: '',
    deviceId: 'band',
  );
}

void main() {
  group('a response on the MG: start, then single follow-ups', () {
    test('a count of 1 is just the opening cue: the pair, one command', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        final cues = GestureCues(haptics: svc);
        BuzzDelivery? done;
        cues.response(1).then((v) => done = v);
        async.elapse(const Duration(seconds: 20));
        expect(done, BuzzDelivery.complete);
        expect(_cmds(band), ['[47, 152] x1']);
      });
    });

    test('a count of 3 is the pair, then two single buzz14s', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        final cues = GestureCues(haptics: svc);
        BuzzDelivery? done;
        cues.response(3).then((v) => done = v);
        async.elapse(const Duration(seconds: 30));
        expect(done, BuzzDelivery.complete);
        expect(_cmds(band), ['[47, 152] x1', '[14] x1', '[14] x1'],
            reason: 'the double is only the opening cue; the rest are single');
        _expectNoOverlap(band);
        _expectZeroGap(band);
      });
    });

    test('a count of 2 is the pair and one follow-up', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        GestureCues(haptics: svc).response(2);
        async.elapse(const Duration(seconds: 30));
        expect(_cmds(band), ['[47, 152] x1', '[14] x1']);
        _expectNoOverlap(band);
        _expectZeroGap(band);
      });
    });

    test('the follow-up is the fastest single of the vocabulary', () {
      // Pinned against the table, not a literal: a vocabulary change that
      // makes a different single the fastest must re-pick on purpose.
      final fastest = _mg.phrases
          .where((p) => p.stable && p.min.length == 1 && p.max.length == 1)
          .toList()
        ..sort((a, b) => a.unitsMax != b.unitsMax
            ? a.unitsMax.compareTo(b.unitsMax)
            : a.unitsMin.compareTo(b.unitsMin));
      fakeAsync((async) {
        final (band, svc) = _rig();
        GestureCues(haptics: svc).response(2);
        async.elapse(const Duration(seconds: 30));
        expect(band.writes[1].effects, fastest.first.effects);
        expect(band.writes[1].loop, fastest.first.loop);
      });
    });

    test('the whole response is ONE queue job: a job queued behind it waits '
        'for the last follow-up', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        final cues = GestureCues(haptics: svc);
        cues.response(3);
        async.elapse(const Duration(milliseconds: 40));
        expect(svc.pending, 1, reason: 'one job, not one per buzz');
        var seen = -1;
        svc.runJob(1, (job) async {
          seen = band.writes.length;
          return BuzzDelivery.complete;
        });
        async.elapse(const Duration(seconds: 30));
        expect(seen, 3,
            reason: 'nothing else may write between the cues of one response');
      });
    });

    test('a count of 3 spends three commands of the band\'s rolling limit',
        () {
      fakeAsync((async) {
        final (_, svc) = _rig();
        GestureCues(haptics: svc).response(3);
        async.elapse(const Duration(seconds: 30));
        expect(svc.commandsLeft, 27);
      });
    });
  });

  group('the final ack is the confirmation cue', () {
    test('confirm is one buzz47, stronger than the follow-up', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        BuzzDelivery? done;
        GestureCues(haptics: svc).confirm().then((v) => done = v);
        async.elapse(const Duration(seconds: 20));
        expect(done, BuzzDelivery.complete);
        expect(_cmds(band), ['[47] x1']);
      });
    });

    test('ackTap delivers the confirmation instead of the default one-buzz '
        'transport, and only for a live tap where an action ran', () async {
      var defaultBuzzes = 0;
      var confirms = 0;
      final d = AlertDispatcher(
        phone: () async => false,
        band: () async {
          defaultBuzzes++;
          return true;
        },
        isConnected: () => true,
        ledger: MemoryAlertDeliveryLedger(),
      );
      final ran = [
        GestureOutcome(
          action: DeviceAction.markMoment,
          status: GestureStatus.ran,
          timeSource: EventTimeSource.strap,
        ),
      ];
      final ok = await ackTap(d, _tap(), ran, bandDelivery: () async {
        confirms++;
        return BuzzDelivery.complete;
      });
      expect(ok, isTrue);
      expect(confirms, 1);
      expect(defaultBuzzes, 0, reason: 'the confirm replaced the default buzz');

      final failed = [
        GestureOutcome(
          action: DeviceAction.markMoment,
          status: GestureStatus.failed,
          timeSource: EventTimeSource.strap,
        ),
      ];
      expect(
          await ackTap(d, _tap(), failed, bandDelivery: () async {
            confirms++;
            return BuzzDelivery.complete;
          }),
          isFalse);
      expect(confirms, 1, reason: 'no action ran: no confirmation');
    });

    test('through a real service: ackTap with the confirm cue writes one '
        'buzz47 to the MG', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        final cues = GestureCues(haptics: svc);
        final d = AlertDispatcher(
          phone: () async => false,
          band: () async => false,
          isConnected: () => true,
          ledger: MemoryAlertDeliveryLedger(),
        );
        final ran = [
          GestureOutcome(
            action: DeviceAction.logWater,
            status: GestureStatus.ran,
            timeSource: EventTimeSource.strap,
          ),
        ];
        bool? ok;
        ackTap(d, _tap(), ran, bandDelivery: cues.confirm).then((v) => ok = v);
        async.elapse(const Duration(seconds: 20));
        expect(ok, isTrue);
        expect(_cmds(band), ['[47] x1']);
      });
    });
  });

  group('a customised built-in is what plays', () {
    test('start, follow-up and confirm each play the stored pattern', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        final stored = <String, BuzzSequence>{
          // Start becomes one long buzz, follow-up the strong single, confirm
          // two commands with a 300 ms wait between them.
          'gesture.start': _custom([
            ([47], 3, 0),
          ]),
          'gesture.followUp': _custom([
            ([47], 1, 0),
          ]),
          'gesture.confirm': _custom([
            ([14], 1, 0),
            ([1], 1, 300),
          ]),
        };
        final cues = GestureCues(haptics: svc, patternFor: (k) => stored[k]);
        cues.response(3);
        async.elapse(const Duration(seconds: 30));
        expect(_cmds(band), ['[47] x3', '[47] x1', '[47] x1']);
        _expectNoOverlap(band);
        _expectZeroGap(band);

        final before = band.writes.length;
        cues.confirm();
        async.elapse(const Duration(seconds: 30));
        final confirm = band.writes.sublist(before);
        expect([for (final w in confirm) '${w.effects} x${w.loop}'],
            ['[14] x1', '[1] x1']);
        final end = confirm[0].atMs +
            band.writeToFiredMs +
            confirm[0].playback.envelopeMs;
        expect(confirm[1].atMs, end + 300,
            reason: 'the stored 300 ms wait is kept');
      });
    });

    test('a pattern the wearer did not touch (null) still plays the '
        'built-in', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        final cues = GestureCues(
          haptics: svc,
          patternFor: (k) => k == 'gesture.followUp'
              ? _custom([
                  ([47], 1, 0),
                ])
              : null,
        );
        cues.response(2);
        async.elapse(const Duration(seconds: 30));
        expect(_cmds(band), ['[47, 152] x1', '[47] x1']);
      });
    });

    test('a customised two-command follow-up still chains with no wait '
        'between cues', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        final cues = GestureCues(
          haptics: svc,
          patternFor: (k) => k == 'gesture.followUp'
              ? _custom([
                  ([14], 1, 0),
                  ([14], 1, 0),
                ])
              : null,
        );
        cues.response(3);
        async.elapse(const Duration(seconds: 60));
        expect(_cmds(band), [
          '[47, 152] x1',
          '[14] x1',
          '[14] x1',
          '[14] x1',
          '[14] x1',
        ]);
        _expectNoOverlap(band);
        _expectZeroGap(band);
      });
    });
  });

  group('gen4 is unchanged: no profile, today\'s per-tap path', () {
    test('a count of 3 is three plain pulses 300 ms apart', () {
      fakeAsync((async) {
        final (band, svc) = _rig(generation: 'gen4');
        expect(svc.profile, isNull);
        GestureCues(haptics: svc).response(3);
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
        ], [300, 300]);
      });
    });

    test('the confirmation is one plain buzz, no compiled commands', () {
      fakeAsync((async) {
        final (band, svc) = _rig(generation: 'gen4');
        GestureCues(haptics: svc).confirm();
        async.elapse(const Duration(seconds: 10));
        expect(band.writes, hasLength(1));
        expect(band.writes.single.effects, [0]);
      });
    });
  });

  group('not connected', () {
    test('a response writes nothing and says it was rejected', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        band.connected = false;
        BuzzDelivery? done;
        GestureCues(haptics: svc).response(3).then((v) => done = v);
        async.elapse(const Duration(seconds: 20));
        expect(band.writes, isEmpty);
        expect(done, BuzzDelivery.rejected);
      });
    });
  });
}
