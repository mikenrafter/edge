// An EcgTapSession rig for the gesture-failure tests: every effect injected, every
// call logged in order. Test-only.
//
// The failure parameters (`bandIdle`, `onFailed`) are passed through
// Function.apply and DROPPED when the session does not have them yet, so a
// build without them still constructs the session and the test fails on what
// it asserts, not on a NoSuchMethodError at construction.
//
// ASSUMED NEW EcgTapSession PARAMETERS (lib/gestures/ecg_tap_session.dart):
//   * `Future<void> Function()? bandIdle`: completes once the band has
//     finished PLAYING everything queued so far: every cue delivered AND its
//     plan ended (the band queue's settle, not the write). The session awaits
//     it after each follow-up cue before the window for the NEXT touch opens
//     (bounded by `buzzTimeout`). Null: the old behaviour (nothing waits).
//   * `void Function(StrapEvent tap, String reason)? onFailed`: called once
//     per FAILED gesture (start_failed, no_stream, link_lost, stalled,
//     sample_gap) with the abandon reason as such (never the "fallback: "
//     form), after the retry (if any) has been used up. Never for a gesture
//     that counted; never for an attempt that is retried.

import 'dart:async';

import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'ecg_trace.dart' show r17;

final DateTime kAkT0 = DateTime.utc(2026, 10, 4, 2, 7, 4, 700);

StrapEvent akDoubleTap({int sec = 0}) => StrapEvent(
      eventId: 14,
      tsEpoch: kAkT0.millisecondsSinceEpoch ~/ 1000 + sec,
      receivedAt: kAkT0.add(Duration(seconds: sec, milliseconds: 107)),
      hex: '',
      deviceId: 'band',
    );

/// A 100-sample packet ending at strap second [sec]; each (from, to) pair is a
/// run of moving samples (contact), sample i being at sec - 1 + i / 100.
LabradorR17 akPacket(int sec, [List<(int, int)> contact = const []]) => r17(
      strapSeconds: sec,
      sequence: sec,
      samples: [
        for (var i = 0; i < 100; i++)
          contact.any((c) => i >= c.$1 && i < c.$2) ? (i.isEven ? 120 : -120) : 0,
      ],
    );

/// What one call of beginStream does: true / false returned, an Exception or
/// Error thrown, a Completer awaited.
typedef AkBegin = Object;

class AkEcgRig {
  AkEcgRig({
    this.max = 5,
    this.begins = const <AkBegin>[true],
    EcgTapThresholds? thresholds,
    this.useBandIdle = false,
    this.holdFollowUps = false,
    this.holdStart = false,
    this.reportFailures = false,
    this.startHangs = false,
    this.confirm = true,
    this.failCue = true,
    this.reacquire = Duration.zero,
    Duration buzzTimeout = const Duration(seconds: 15),
  }) : _th = thresholds {
    final named = <Symbol, dynamic>{
      #beginStream: () async {
        began++;
        log.add('begin');
        final b = begins[(began - 1).clamp(0, begins.length - 1)];
        if (b is Completer<bool>) return await b.future;
        if (b is Exception) throw b;
        if (b is Error) throw b;
        return b as bool;
      },
      #endStream: () async {
        ended++;
        log.add('end');
      },
      #isStreamAlive: () => alive,
      #startBuzz: (String id) {
        cues.add(('start', id));
        log.add('start');
        if (holdStart) busy = true;
        if (startHangs) return Completer<bool>().future;
        return Future<bool>.value(true);
      },
      #buzz: (int pulses, String id) async {
        pulseArgs.add(pulses);
        cues.add(('follow', id));
        log.add('follow');
        if (holdFollowUps) busy = true;
        return true;
      },
      if (confirm)
        #confirmBuzz: (String id) async {
          cues.add(('confirm', id));
          log.add('confirm');
          return true;
        },
      if (failCue)
        #failBuzz: (String id) async {
          cues.add(('fail', id));
          log.add('fail');
          return true;
        },
      #maxTaps: () => max,
      #thresholds: () => _th ?? EcgTapThresholds(),
      #onFinished: (int? c, String? r) => results.add((c, r)),
      #recordSession: (EcgGestureRecord r) async => records.add(r),
      #step: steps.add,
      #now: () => now,
      #wait: (Duration d) async => waits.add(d),
      #pollEvery: const Duration(hours: 1),
      #sensorReacquire: reacquire,
      #beginTimeout: const Duration(milliseconds: 40),
      #endTimeout: const Duration(milliseconds: 40),
      #recordTimeout: const Duration(milliseconds: 40),
      #buzzTimeout: buzzTimeout,
    };
    final extras = <Symbol, dynamic>{
      if (useBandIdle) #bandIdle: _bandIdle,
      if (reportFailures)
        #onFailed: (StrapEvent tap, String reason) {
          failures.add(reason);
          failureTaps.add(tap);
        },
    };
    try {
      session = Function.apply(EcgTapSession.new, const [], {...named, ...extras})
          as EcgTapSession;
    } on NoSuchMethodError {
      session =
          Function.apply(EcgTapSession.new, const [], named) as EcgTapSession;
    }
  }

  late final EcgTapSession session;
  final int max;
  final List<AkBegin> begins;
  final EcgTapThresholds? _th;
  final bool useBandIdle, holdFollowUps, holdStart, reportFailures, startHangs;
  final bool confirm, failCue;
  final Duration reacquire;

  bool alive = true;
  DateTime now = kAkT0;
  int began = 0, ended = 0, idleCalls = 0;
  final log = <String>[];
  final cues = <(String, String)>[];
  final pulseArgs = <int>[];
  final results = <(int?, String?)>[];
  final records = <EcgGestureRecord>[];
  final steps = <String>[];
  final waits = <Duration>[];
  final failures = <String>[];
  final failureTaps = <StrapEvent>[];

  List<String> get names => [for (final c in cues) c.$1];

  // The virtual band: busy while a held cue "plays" (see holdFollowUps /
  // holdStart) until [endCue] says its plan ended.
  bool busy = false;
  final List<Completer<void>> _idleWaiters = [];

  Future<void> _bandIdle() {
    idleCalls++;
    if (!busy) return Future<void>.value();
    final c = Completer<void>();
    _idleWaiters.add(c);
    return c.future;
  }

  /// The held cue's plan ended: the band is idle again.
  Future<void> endCue() async {
    busy = false;
    for (final c in _idleWaiters) {
      if (!c.isCompleted) c.complete();
    }
    _idleWaiters.clear();
    await settle();
  }

  Future<void> settle() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Feed packet [sec]; the phone gets it 0.5 s + (sec - 1000) s after t0, so
  /// the sample clock and the phone clock run in step.
  Future<void> frame(int sec, [List<(int, int)> contact = const []]) async {
    now = kAkT0.add(Duration(milliseconds: 500 + (sec - 1000) * 1000));
    session.onFrame(akPacket(sec, contact));
    await settle();
  }

  Future<void> tap() => session.start(akDoubleTap());

  /// Two quiet packets: steady, and the first window opens at sample time
  /// 1001.5 (2.5 s after the first sample, 1000.5 + settle... see the g8 rig).
  Future<void> steady() async {
    await frame(1000);
    await frame(1001);
  }

  // The contact mask fills a packet from its first to its last contact
  // sample. Each touch is one run reaching the end of its packet.

  /// Touch 3 from 1001.6 (engages 1001.8), lifted at 1002.0.
  Future<void> touchThree() => frame(1002, [(60, 100)]);

  /// Touch 4 from 1002.25 (engages 1002.45), lifted at 1003.0.
  Future<void> touchFour() => frame(1003, [(25, 100)]);

  /// Touch 5 from 1003.25 (engages 1003.45): the max.
  Future<void> touchFive() => frame(1004, [(25, 100)]);
}
