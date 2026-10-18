// beginEcgForTap (review finding G): starting the ECG stream for a tap gesture
// must not outlive the gesture, and must never stop an ECG the gesture did not
// start.
//
// Future.timeout() does not cancel the work behind it. The session gives up on
// a slow start after ~15 s and finishes, but the start was still awaiting the
// wrist lookup and would then start the stream for a session that was already
// gone, running unconsumed until the controller's own 120 s capture limit. The
// session's generation is checked after EVERY await; a start that completes for
// a dead gesture stops the capture it started, and only that capture (identified
// by the controller's capture epoch).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/gestures/ecg_tap_begin.dart';

class _Ecg {
  bool capturing = false;
  int epoch = 0;
  int begun = 0, cancelled = 0;
  bool alive = true; // the gesture generation is current
  Completer<EcgWrist?>? wristGate;
  Completer<void>? beginGate;
  EcgWrist? wrist = EcgWrist.left;
  bool beginFails = false;
  final notes = <String>[];

  Future<bool> run() => beginEcgForTap(
        isCurrent: () => alive,
        isCapturing: () => capturing,
        lookupWrist: () async {
          final g = wristGate;
          if (g != null) return g.future;
          return wrist;
        },
        begin: (w) async {
          // The controller's synchronous part: new epoch, lease taken.
          begun++;
          epoch++;
          if (!beginFails) capturing = true;
          await beginGate?.future;
        },
        captureEpoch: () => epoch,
        cancel: () async {
          cancelled++;
          epoch++;
          capturing = false;
        },
        note: notes.add,
      );
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('a live gesture: the stream starts and the capture is kept', () async {
    final e = _Ecg();
    expect(await e.run(), isTrue);
    expect((e.begun, e.cancelled, e.capturing), (1, 0, true));
  });

  test('an ECG reading already in progress is left alone', () async {
    final e = _Ecg()..capturing = true;
    expect(await e.run(), isFalse);
    expect((e.begun, e.cancelled, e.capturing), (0, 0, true));
  });

  test('no remembered wrist: false, the lab is told, nothing started',
      () async {
    final e = _Ecg()..wrist = null;
    expect(await e.run(), isFalse);
    expect(e.begun, 0);
    expect(e.notes.join(), contains('No wrist remembered'));
  });

  test('the gesture ended during the wrist lookup: the stream is never '
      'started', () async {
    final e = _Ecg()..wristGate = Completer<EcgWrist?>();
    final f = e.run();
    await _settle();
    e.alive = false; // the session timed out and finished
    e.wristGate!.complete(EcgWrist.left);
    expect(await f, isFalse);
    expect((e.begun, e.cancelled), (0, 0));
    expect(e.notes.join(), contains('ended'));
  });

  test('someone else started an ECG during the wrist lookup: not touched',
      () async {
    final e = _Ecg()..wristGate = Completer<EcgWrist?>();
    final f = e.run();
    await _settle();
    e.capturing = true; // the user opened the ECG screen
    e.epoch++;
    e.wristGate!.complete(EcgWrist.left);
    expect(await f, isFalse);
    expect((e.begun, e.cancelled, e.capturing), (0, 0, true));
  });

  test('the gesture ended while begin() was running: the late capture is '
      'stopped, once', () async {
    final e = _Ecg()..beginGate = Completer<void>();
    final f = e.run();
    await _settle();
    expect(e.capturing, isTrue, reason: 'the capture really started');
    e.alive = false;
    e.beginGate!.complete();
    expect(await f, isFalse);
    expect((e.cancelled, e.capturing), (1, false));
    expect(e.notes.join(), contains('stopped'));
  });

  test('the gesture ended and the capture is no longer ours: not stopped',
      () async {
    final e = _Ecg()..beginGate = Completer<void>();
    final f = e.run();
    await _settle();
    // Our capture was cancelled and the user began their own.
    e.epoch += 2;
    e.capturing = true;
    e.alive = false;
    e.beginGate!.complete();
    expect(await f, isFalse);
    expect((e.cancelled, e.capturing), (0, true));
  });

  test('a live gesture whose capture was replaced by someone else is not '
      'reported as started', () async {
    final e = _Ecg()..beginGate = Completer<void>();
    final f = e.run();
    await _settle();
    e.epoch += 1; // cancelled and replaced
    e.beginGate!.complete();
    expect(await f, isFalse);
    expect(e.cancelled, 0);
  });

  test('begin() that did not take a capture is false and cancels nothing',
      () async {
    final e = _Ecg()..beginFails = true;
    expect(await e.run(), isFalse);
    expect((e.begun, e.cancelled), (1, 0));
  });

  test('a throwing begin() reaches the caller (the session fails the start)',
      () async {
    await expectLater(
      beginEcgForTap(
        isCurrent: () => true,
        isCapturing: () => false,
        lookupWrist: () async => EcgWrist.left,
        begin: (_) async => throw StateError('radio'),
        captureEpoch: () => 0,
        cancel: () async {},
      ),
      throwsStateError,
    );
  });
}
