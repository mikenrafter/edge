// 8AK A: no haptic write ever overlaps the ECG stream start (PREPARE).
//
// The 2026-10-04 lab log: four of five gestures failed at PREPARE, the stream
// start refused after the engine's 5 s timeout. In every one the band had
// answered the start cue's first buzz before PREPARE began, and a second buzz
// reply (the cue's next write) came 1.1 to 2.0 s after the tap, in the middle
// of PREPARE; the one start that worked had its PREPARE answered only after
// that reply. So the likely cause is a command written while the band
// vibrates, answered late or never. The start cue (written and played out) and
// the stream start (PREPARE + START) must take turns, and no other alert may
// write into the middle of the start either.
//
// The mechanism is one source, the band queue: AppState runs the stream start
// as an exclusive job (HapticsService.runExclusive) behind the start cue, ahead
// of waiting alerts, and the queue writes nothing else until it is done.
//
// Failure mode before: the start ran beside the cue (nothing held either back).

import 'dart:io';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/gesture_cues.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';

import '../phase8/support/dart_source.dart';
import '../support/virtual_mg.dart';

(VirtualMgBand, HapticsService) _rig() {
  final band = VirtualMgBand();
  final svc = HapticsService(port: band, allowLong: () => false);
  band.onEvent = svc.onBandEvent;
  return (band, svc);
}

void main() {
  test('the stream start runs after the start cue has been played, and no '
      'alert writes into it', () {
    fakeAsync((async) {
      final (band, svc) = _rig();
      final t0 = clock.now();
      int ms() => clock.now().difference(t0).inMilliseconds;
      int? from, to;
      final cues = GestureCues(haptics: svc);
      cues.start();
      // The stream start (PREPARE + START: seconds of commands).
      svc.runExclusive<void>(() async {
        from = ms();
        await Future<void>.delayed(const Duration(seconds: 3));
        to = ms();
      });
      // An alert asked for during the start (a follow-up cue stands in).
      cues.followUp();
      async.elapse(const Duration(seconds: 30));
      expect(from, isNotNull, reason: 'the start ran');
      final startCue = band.writes.first;
      final cuePlanEnd =
          startCue.atMs + band.writeToFiredMs + startCue.playback.envelopeMs;
      expect(from!, greaterThanOrEqualTo(cuePlanEnd),
          reason: 'not before the start cue finished playing');
      for (final w in band.writes.skip(band.writes.indexOf(startCue) + 1)) {
        expect(w.atMs >= to! || w.atMs < from!, isTrue,
            reason: 'a haptic write at ${w.atMs} ms landed inside the start '
                '($from to $to ms)');
      }
      expect(band.writes.any((w) => w.atMs >= to!), isTrue,
          reason: 'the cue held back plays once the start is done');
    });
  });

  test('the start goes ahead of an alert that was already waiting, never in '
      'front of what is playing', () {
    fakeAsync((async) {
      final (band, svc) = _rig();
      final t0 = clock.now();
      int ms() => clock.now().difference(t0).inMilliseconds;
      final cues = GestureCues(haptics: svc);
      cues.start(); // playing
      cues.confirm(); // waiting
      int? from;
      svc.runExclusive<void>(() async => from = ms());
      async.elapse(const Duration(seconds: 30));
      final first = band.writes.first;
      expect(from!, greaterThanOrEqualTo(
          first.atMs + band.writeToFiredMs + first.playback.envelopeMs));
      expect(band.writes.length, 2);
      expect(band.writes.last.atMs, greaterThanOrEqualTo(from!),
          reason: 'the waiting alert plays after the start, not before it');
    });
  });

  test('a start that throws hands the error back and frees the band', () {
    fakeAsync((async) {
      final (band, svc) = _rig();
      Object? error;
      svc
          .runExclusive<void>(() async => throw StateError('prepare refused'))
          .catchError((Object e) => error = e);
      GestureCues(haptics: svc).followUp();
      async.elapse(const Duration(seconds: 10));
      expect(error, isA<StateError>());
      expect(band.writes, hasLength(1), reason: 'the next cue still played');
    });
  });

  test('the gesture controller starts the stream through it, behind the '
      'start cue\'s write (source guard)', () {
    final src = File('lib/state/gesture_controller.dart').readAsStringSync();
    final a = src.indexOf('Future<bool> _beginEcgForTap()');
    final body = codeOnly(src.substring(a, src.indexOf('_startCueSent;', a)));
    expect(body.indexOf('_startCueWritten()'), greaterThan(0));
    expect(body.indexOf('_startCueWritten()'),
        lessThan(body.indexOf('haptics.runExclusive')));
    expect(body, contains('beginEcgForTap('));
    final code = codeOnly(src);
    expect(code, contains('_startCueSent = _gestureCue('),
        reason: 'the start cue is the one the stream start waits for');
  });
}
