// Shared rig for the 8AN fast-path tests: presence packets and an
// EcgTapSession on a virtual clock whose band queue the test controls.
//
// ASSUMED API (new, to be written by the green phases):
//  * lib/gestures/ecg_tap_mode.dart: `enum EcgTapMode { accurate, fast }`.
//  * EcgTapSession gains optional ctor params `EcgTapMode Function()? tapMode`
//    (null = accurate), `Future<bool> Function()? beginFastStream` (called
//    INSTEAD of `beginStream` in fast mode) and `int? presenceFallbackPackets`
//    (null = `kEcgPresenceFallbackPackets`).
//  * EcgGestureRecord gains `bool fellBackToSamples` (default false: the
//    presence veto was lifted because the band never reported presence).

import 'dart:async';

import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_mode.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';

import 'presence_packets.dart';

class FastRig {
  FastRig({
    this.max = 5,
    EcgTapThresholds? th,
    this.mode = EcgTapMode.fast,
    this.bandQueue = true,
    this.fallbackPackets,
    this.beginFast,
    this.throwOnFinish = false,
    Duration beginTimeout = const Duration(seconds: 15),
  }) {
    session = EcgTapSession(
      tapMode: () => mode,
      beginStream: () async {
        beganAccurate++;
        return true;
      },
      beginFastStream: () async {
        beganFast++;
        return await beginFast?.call() ?? true;
      },
      endStream: () async => ended++,
      isStreamAlive: () => alive,
      startBuzz: (id) async {
        cues.add('start');
        return true;
      },
      buzz: (pulses, id) async {
        cues.add('follow');
        playing = Completer<void>();
        return true;
      },
      confirmBuzz: (id) async {
        cues.add('confirm');
        return true;
      },
      // The band queue: a follow-up is "playing" until the test says so.
      bandIdle: bandQueue ? () => playing?.future ?? Future<void>.value() : null,
      maxTaps: () => max,
      thresholds: () => th ?? EcgTapThresholds(),
      onFinished: (c, r) {
        results.add((c, r));
        if (throwOnFinish) throw StateError('listener failed');
      },
      recordSession: (r) async => records.add(r),
      step: steps.add,
      now: () => now,
      wait: (_) async {},
      pollEvery: const Duration(hours: 1),
      beginTimeout: beginTimeout,
      presenceFallbackPackets: fallbackPackets,
    );
  }

  final int max;
  final EcgTapMode mode;
  final bool bandQueue;
  final bool throwOnFinish;
  final int? fallbackPackets;
  final Future<bool> Function()? beginFast;
  late final EcgTapSession session;
  bool alive = true;
  DateTime now = t0;
  int beganAccurate = 0, beganFast = 0, ended = 0;
  final cues = <String>[];
  final results = <(int?, String?)>[];
  final records = <EcgGestureRecord>[];
  final steps = <String>[];
  Completer<void>? playing;

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> begin() async {
    now = t0.add(const Duration(milliseconds: 300));
    await session.start(tapAt());
    await settle();
  }

  /// The band finished playing the follow-up cue.
  Future<void> cuePlayed() async {
    final p = playing;
    playing = null;
    if (p != null && !p.isCompleted) p.complete();
    await settle();
  }

  /// A packet ending at strap second [sec], received 2.8 s after the tap plus
  /// one second per second of strap time after 1000.
  Future<void> feed(
    int sec, {
    bool presence = false,
    bool contact = false,
    int? from,
    int? to,
    int unreadable = 0,
  }) async {
    now = t0.add(Duration(milliseconds: 2800 + (sec - 1000) * 1000));
    session.onFrame(presencePacket(sec,
        presence: presence,
        contact: contact,
        contactFrom: from,
        contactTo: to,
        unreadable: unreadable));
    await settle();
  }

  /// Packets for a gesture of [n] taps (2..5) in fast mode: one touch (a whole
  /// packet of contact with presence) per follow-up, a lift packet after each,
  /// the follow-up cue played before the next packet, then absent packets until
  /// the window runs out (the sample counter's reacquire + confirm is about
  /// 1.7 s after the cue). Returns the next free strap second.
  Future<int> playCount(int n) async {
    var sec = 1000;
    final touches = n - 2;
    for (var i = 0; i < touches; i++) {
      await feed(sec++, presence: true, contact: true);
      if (results.isNotEmpty) return sec; // reached max: done at once
      await feed(sec++); // the lift, while the cue still plays
      await cuePlayed();
    }
    for (var i = 0; i < 4 && results.isEmpty; i++) {
      await feed(sec++);
    }
    return sec;
  }
}
