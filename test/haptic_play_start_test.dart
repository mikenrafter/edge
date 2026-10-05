// When does a compiled command start playing on the band? The service
// reports one HapticPlayStart per command: the band's live event 60 when it
// comes within a second of the write, else the write time plus the default
// Bluetooth lead. Driven against the virtual MG band like AppState wires it.

import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

import 'support/virtual_mg.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

/// Two effect-47 commands, the second 700 ms after the first one's end.
BuzzSequence _two() => BuzzSequence(
      const [0],
      durationsMs: const [500],
      profileId: _mg.id,
      profileVersion: _mg.version,
      bakedSteps: [
        BakedStep(effects: const [47], loop: 1, delayMs: 0),
        BakedStep(effects: const [47], loop: 1, delayMs: 700),
      ],
    );

void main() {
  group('start signals from the virtual MG band', () {
    (VirtualMgBand, HapticsService) rig({
      bool wire = true,
      int? backlogAfterMs,
    }) {
      final band = VirtualMgBand(backlogAfterMs: backlogAfterMs);
      final svc = HapticsService(port: band, allowLong: () => false);
      if (wire) band.onEvent = svc.onBandEvent;
      return (band, svc);
    }

    test('one signal per command, in order, at the band\'s own event 60',
        () {
      fakeAsync((async) {
        final t0 = clock.now();
        final (band, svc) = rig();
        final starts = <HapticPlayStart>[];
        svc.deliver(_two(), onStart: starts.add);
        async.elapse(const Duration(seconds: 12));
        expect([for (final s in starts) s.command], [0, 1]);
        expect(starts.every((s) => s.measured), isTrue);
        final fired = [
          for (final e in band.events)
            if (e.$2.eventId == 60) t0.add(Duration(milliseconds: e.$1)),
        ];
        expect(fired, hasLength(2));
        expect([for (final s in starts) s.at], fired);
      });
    });

    test('a signal comes as soon as the 60 does, not a second later', () {
      fakeAsync((async) {
        final (band, svc) = rig();
        final seen = <int>[];
        svc.deliver(
          _two(),
          onStart: (s) => seen.add(async.elapsed.inMilliseconds),
        );
        async.elapse(const Duration(seconds: 12));
        final fired = [
          for (final e in band.events)
            if (e.$2.eventId == 60) e.$1,
        ];
        expect(seen, fired);
      });
    });

    test('with no event 60 the start is the write time plus 300 ms, '
        'reported a second after the write', () {
      fakeAsync((async) {
        final t0 = clock.now();
        final (band, svc) = rig(wire: false);
        final reported = <int>[];
        final starts = <HapticPlayStart>[];
        svc.deliver(_two(), onStart: (s) {
          starts.add(s);
          reported.add(async.elapsed.inMilliseconds);
        });
        async.elapse(const Duration(seconds: 12));
        expect(starts, hasLength(2));
        for (var i = 0; i < 2; i++) {
          final wrote = band.writes[i].atMs;
          expect(starts[i].measured, isFalse);
          expect(starts[i].at,
              t0.add(Duration(
                  milliseconds:
                      wrote + PatternEntrySession.defaultLeadMs)));
          expect(reported[i], wrote + 1000);
        }
      });
    });

    test('old events replayed in a burst are not a start', () {
      fakeAsync((async) {
        final t0 = clock.now();
        final (band, svc) = rig(backlogAfterMs: 200);
        final starts = <HapticPlayStart>[];
        svc.deliver(_two(), onStart: starts.add);
        async.elapse(const Duration(seconds: 12));
        expect(starts, hasLength(2));
        final live = [
          for (final e in band.events)
            if (e.$2.eventId == 60 && e.$2.isLive)
              t0.add(Duration(milliseconds: e.$1)),
        ];
        expect([for (final s in starts) s.at], live);
      });
    });

    test('a 60 more than a second after the write is not that command\'s '
        'start, and the command is not reported twice', () {
      fakeAsync((async) {
        final (band, svc) = rig(wire: false);
        final starts = <HapticPlayStart>[];
        svc.deliver(_two(), onStart: starts.add);
        async.elapse(const Duration(milliseconds: 1200));
        expect(starts, hasLength(1));
        expect(starts.single.measured, isFalse);
        svc.onBandEvent(StrapEvent(
          eventId: 60,
          tsEpoch: clock.now().millisecondsSinceEpoch ~/ 1000,
          receivedAt: clock.now(),
          hex: '',
          deviceId: 'virtual-mg',
        ));
        expect(starts, hasLength(1));
        // Keep the band quiet: nothing else in this test needs the rest.
        band.connected = false;
        async.elapse(const Duration(seconds: 12));
      });
    });

    test('no onStart: delivery is as before', () {
      fakeAsync((async) {
        final (band, svc) = rig();
        svc.deliver(_two());
        async.elapse(const Duration(seconds: 12));
        expect(band.writes, hasLength(2));
        expect(band.writes.every((w) => w.played), isTrue);
      });
    });

    test('a band with no haptic profile (per-tap buzzes) reports nothing',
        () {
      fakeAsync((async) {
        final band = VirtualMgBand(generation: 'gen4');
        final svc = HapticsService(port: band, allowLong: () => false);
        band.onEvent = svc.onBandEvent;
        final starts = <HapticPlayStart>[];
        unawaited(svc.deliver(
          BuzzSequence(const [0, 600], durationsMs: const [100, 100]),
          onStart: starts.add,
        ));
        async.elapse(const Duration(seconds: 12));
        expect(starts, isEmpty);
      });
    });
  });

  test('the preview path passes onStart to the service and the editor can '
      'see it (source guard)', () {
    final app = File('lib/state/app_state.dart').readAsStringSync();
    expect(app, contains('haptics.deliver(s, onStart: onStart)'));
    expect(app, contains('void Function(HapticPlayStart)? onStart'));
  });
}
