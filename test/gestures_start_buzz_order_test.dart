// 8AI G5 (red): the gesture-start buzz goes out the moment the gesture message
// arrives, and ECG monitoring starts right after, without waiting on the buzz.
//
// Why (user report): with the delays the wearer's hand has to be on the ECG
// sensor already when the stream starts, otherwise the touch counts as a
// double tap, not a triple. Today the first buzz is the count after the first
// touch window, and nothing buzzes at the tap.
//
// ASSUMED API (lib/gestures/ecg_tap_session.dart, EcgTapSession):
//   * A new optional constructor parameter
//       `Future<bool> Function(String eventId)? startBuzz`
//     "the gesture-start cue". `start(tap)` calls it ONCE, synchronously,
//     before it calls `beginStream`, as soon as the tap is accepted (after the
//     one-gesture-at-a-time and prior-stop checks, so a tap that is ignored
//     does not buzz). The event id is a non-empty string identifying this
//     gesture (so the alert dispatcher's claim dedupes a re-delivered tap).
//   * `start` does NOT await the returned future: `beginStream` is called in
//     the same turn the buzz was started, and `start` completes when the
//     stream command has gone out, whether or not the buzz has finished. A
//     start buzz that throws, or answers false, is logged to `step` and
//     changes nothing else about the gesture.
//   * The gesture controller wires it (lib/state/gesture_controller.dart
//     `_newEcgSession()` = EcgTapSession(...)) to the gesture start cue through the same
//     dispatcher path as the count buzz (`startBuzz: ...`).
//
// Failure mode today: EcgTapSession has no `startBuzz`, so every test that
// builds the rig with it fails at construction; the source guards fail on the
// missing wiring.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source_lexical.dart';
import 'support/ecg_tap_session_start_buzz_rig.dart';

void main() {
  group('the start buzz comes first', () {
    test('it is sent when the tap arrives, before the ECG stream is asked to '
        'start', () async {
      final rig = SessionRig();
      await rig.session.start(doubleTap());
      expect(rig.order.take(2), ['startBuzz', 'beginStream'],
          reason: 'the cue goes out first, then the stream is started');
      expect(rig.startBuzzIds, hasLength(1));
      expect(rig.startBuzzIds.single, isNotEmpty);
    });

    test('it is sent in the same turn: nothing is awaited between the tap and '
        'the buzz', () {
      final rig = SessionRig();
      // Not awaited: only the synchronous part of start() has run.
      unawaited(rig.session.start(doubleTap()));
      expect(rig.startBuzzIds, hasLength(1),
          reason: 'start() must call the start buzz before its first await');
    });

    test('a second tap while the gesture runs does not buzz again', () async {
      final rig = SessionRig();
      await rig.session.start(doubleTap());
      await rig.session.start(doubleTap(sec: 1));
      expect(rig.startBuzzIds, hasLength(1));
      expect(rig.began, 1);
    });
  });

  group('ECG start does not wait for the buzz', () {
    test('a start buzz that is still playing does not hold up the stream',
        () async {
      final buzz = Completer<bool>();
      final rig = SessionRig(startBuzz: (_) => buzz.future);
      await rig.session
          .start(doubleTap())
          .timeout(const Duration(seconds: 2), onTimeout: () {
        fail('start() waited for the start buzz to finish');
      });
      expect(rig.began, 1, reason: 'the stream command went out');
      expect(buzz.isCompleted, isFalse, reason: 'the buzz is still pending');
      expect(rig.results, isEmpty, reason: 'and the gesture is still running');
      expect(rig.session.active, isTrue);
      buzz.complete(true); // let the pending future go
      await pumpEventQueue();
      expect(rig.session.active, isTrue);
    });

    test('the stream is asked to start before the buzz has had a chance to '
        'finish, however long it takes', () async {
      final buzz = Completer<bool>();
      final rig = SessionRig(startBuzz: (_) => buzz.future);
      unawaited(rig.session.start(doubleTap()));
      await pumpEventQueue();
      expect(rig.order, ['startBuzz', 'beginStream']);
      expect(buzz.isCompleted, isFalse);
      buzz.complete(false);
    });

    test('a start buzz that throws does not stop the gesture', () async {
      final rig = SessionRig(startBuzz: (_) => throw StateError('no band'));
      await rig.session.start(doubleTap());
      expect(rig.began, 1);
      expect(rig.results, isEmpty);
      expect(rig.session.active, isTrue);
    });

    test('a start buzz that fails asynchronously does not stop it either',
        () async {
      final rig = SessionRig(
          startBuzz: (_) => Future<bool>.error(StateError('late failure')));
      await rig.session.start(doubleTap());
      await pumpEventQueue();
      expect(rig.began, 1);
      expect(rig.results, isEmpty);
      expect(rig.session.active, isTrue);
    });

    test('a start buzz that says false (not written) does not stop it',
        () async {
      final rig = SessionRig(startBuzz: (_) async => false);
      await rig.session.start(doubleTap());
      expect(rig.began, 1);
      expect(rig.session.active, isTrue);
    });

    test('a stream that cannot start still gets its start buzz: the tap was '
        'heard', () async {
      final rig = SessionRig(startOk: false);
      try {
        await rig.session.start(doubleTap());
      } catch (_) {
        // With the double-tap fallback off the start may throw; either way:
      }
      expect(rig.startBuzzIds, hasLength(1));
    });
  });

  group('wiring (source guards)', () {
    test('AppState wires the start buzz into the session it builds', () {
      // Built in the gesture controller since 8AJ seam 3.
      final src = File('lib/state/gesture_controller.dart').readAsStringSync();
      final ctor = codeOnly(bodyOf(src, 'EcgTapSession _newEcgSession()'));
      expect(ctor, contains('startBuzz:'),
          reason: 'the ECG tap session is given the gesture-start cue');
    });
  });
}
