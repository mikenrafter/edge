// A minimal EcgTapSession rig for the start-buzz tests: every effect injected,
// every call logged in order. Test-only.
//
// The new `startBuzz` parameter is passed through Function.apply, so a build
// without it fails the test that needs it (NoSuchMethodError at construction)
// instead of the whole file at compile time.

import 'dart:async';

import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';

final DateTime kT0 = DateTime.utc(2026, 10, 3, 8);

StrapEvent doubleTap({int sec = 0}) => StrapEvent(
      eventId: 14,
      tsEpoch: kT0.millisecondsSinceEpoch ~/ 1000 + sec,
      receivedAt: kT0.add(Duration(seconds: sec, milliseconds: 300)),
      hex: '',
      deviceId: 'band',
    );

class SessionRig {
  SessionRig({
    this.startBuzz,
    this.beginGate,
    this.startOk = true,
  }) {
    session = Function.apply(EcgTapSession.new, const [], {
      #beginStream: () async {
        order.add('beginStream');
        began++;
        await beginGate?.future;
        return startOk;
      },
      #endStream: () async {
        ended++;
      },
      #isStreamAlive: () => true,
      #buzz: (int pulses, String id) async {
        order.add('countBuzz');
        return true;
      },
      #maxTaps: () => 3,
      #thresholds: () => EcgTapThresholds(),
      #onFinished: (int? count, String? reason) => results.add((count, reason)),
      #step: steps.add,
      #now: () => kT0,
      #wait: (Duration d) async {},
      #pollEvery: const Duration(hours: 1),
      #startBuzz: (String eventId) {
        order.add('startBuzz');
        startBuzzIds.add(eventId);
        return startBuzz?.call(eventId) ?? Future<bool>.value(true);
      },
    }) as EcgTapSession;
  }

  /// What the start buzz does when called: a pending future, a throw, false...
  final Future<bool> Function(String eventId)? startBuzz;

  /// Holds the ECG stream start until completed.
  final Completer<void>? beginGate;
  final bool startOk;

  late final EcgTapSession session;
  final order = <String>[];
  final startBuzzIds = <String>[];
  final results = <(int?, String?)>[];
  final steps = <String>[];
  int began = 0, ended = 0;
}
