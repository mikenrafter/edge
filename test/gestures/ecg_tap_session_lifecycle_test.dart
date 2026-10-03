// EcgTapSession lifecycle (review findings G and R).
//
// G: each gesture has a generation; a new gesture never starts its stream while
//    the previous one's stop is still in flight (a late stop would otherwise
//    switch the NEW gesture's stream off).
// R: the 8N tagging interval must cover the time the band actually kept
//    recording. The stream is stopped FIRST, then the interval is written with
//    an end that covers the stop; a slow database can neither lengthen the
//    recording nor leave it outside the interval.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);

StrapEvent _tap({int sec = 0}) => StrapEvent(
      eventId: 14,
      tsEpoch: _t0.millisecondsSinceEpoch ~/ 1000 + sec,
      receivedAt: _t0.add(Duration(seconds: sec, milliseconds: 300)),
      hex: '',
      deviceId: 'band',
    );

LabradorR17 _packet(int sec) => LabradorR17(
      packetType: 43,
      headerSecondary: 0,
      sequence: sec,
      strapSeconds: sec,
      subseconds: 0,
      quality: 0,
      flags: const LabradorFlags(0x0a),
      result: 0,
      s2State: 0,
      progress: 0,
      unreadable: const LabradorUnreadableMask(0),
      averageHr: 0,
      liveHr: 0,
      variabilityRaw: null,
      reserved: 0,
      sampleCount: 100,
      samples: Int16List(100),
      tail: Uint8List(0),
      inner: Uint8List(0),
    );

class _Rig {
  _Rig({
    this.beginGate,
    this.endGate,
    this.recordGate,
    this.strapClock,
  }) {
    session = EcgTapSession(
      beginStream: () async {
        began++;
        log.add('begin');
        final g = beginGate;
        if (g != null && began == 1) await g.future;
        return true;
      },
      endStream: () async {
        ended++;
        log.add('end');
        // A stop takes strap time: the clock moves while it runs.
        stopTakesStrapSec?.call();
        final g = endGate;
        if (g != null && ended == 1) await g.future;
      },
      isStreamAlive: () => alive,
      buzz: (pulses, id) async => true,
      maxTaps: () => 5,
      thresholds: EcgTapThresholds.new,
      onFinished: (count, reason) {
        results.add((count, reason));
        log.add('finished');
      },
      recordSession: (r) async {
        log.add('record');
        records.add(r);
        await recordGate?.future;
      },
      strapNow: strapClock == null ? null : () => strapClock!(),
      now: () => now,
      pollEvery: const Duration(hours: 1),
      beginTimeout: beginTimeout,
      endTimeout: endTimeout,
      recordTimeout: recordTimeout,
    );
  }

  final Completer<void>? beginGate, endGate, recordGate;
  static const Duration beginTimeout = Duration(milliseconds: 40);
  static const Duration endTimeout = Duration(milliseconds: 40);
  static const Duration recordTimeout = Duration(milliseconds: 40);
  int Function()? strapClock;
  void Function()? stopTakesStrapSec;
  bool alive = true;
  DateTime now = _t0;
  late final EcgTapSession session;
  int began = 0, ended = 0;
  final log = <String>[];
  final results = <(int?, String?)>[];
  final records = <EcgGestureRecord>[];

  Future<void> settle([int ms = 0]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> steady(int sec) async {
    now = _t0.add(const Duration(milliseconds: 500));
    session.onFrame(_packet(sec));
    now = _t0.add(const Duration(milliseconds: 1500));
    session.onFrame(_packet(sec + 1));
    await settle();
  }
}

void main() {
  group('G: generations and the stop in flight', () {
    test('each started gesture is a new generation; an ignored tap is not',
        () async {
      final r = _Rig();
      final g0 = r.session.generation;
      await r.session.start(_tap());
      final g1 = r.session.generation;
      expect(g1, g0 + 1);
      await r.session.start(_tap(sec: 1)); // ignored: one gesture at a time
      expect(r.session.generation, g1);
      r.alive = false;
      r.session.poll();
      await r.settle();
      r.alive = true;
      await r.session.start(_tap(sec: 5));
      expect(r.session.generation, g1 + 1);
    });

    test('a start that times out leaves the generation dead (active false)',
        () async {
      final gate = Completer<void>();
      final r = _Rig(beginGate: gate);
      final gen = r.session.generation;
      // 8X: fallback on (the default): a failed start does not throw.
      await r.session.start(_tap());
      expect(r.session.active, isFalse);
      expect(r.session.generation, gen + 1);
      expect(r.ended, 1, reason: 'the late stream is stopped');
      gate.complete();
    });

    test('a new gesture waits for the previous stop before it starts a stream',
        () async {
      final stop = Completer<void>();
      final r = _Rig(endGate: stop);
      await r.session.start(_tap());
      await r.steady(1000);
      r.alive = false;
      r.session.poll(); // gesture 1 ends; its stop hangs
      await r.settle();
      expect(r.ended, 1);
      expect(r.session.active, isFalse);
      r.alive = true;
      final second = r.session.start(_tap(sec: 5));
      await r.settle();
      expect(r.began, 1, reason: 'still waiting for the earlier stop');
      stop.complete();
      await second;
      expect(r.began, 2);
      expect(r.log.indexOf('end'), lessThan(r.log.lastIndexOf('begin')));
      expect(r.session.active, isTrue);
    });

    test('a stop that never answers cannot hold the next gesture past '
        'endTimeout', () async {
      final r = _Rig(endGate: Completer<void>());
      await r.session.start(_tap());
      await r.steady(1000);
      r.alive = false;
      r.session.poll();
      final second = r.session.start(_tap(sec: 5));
      await second;
      expect(r.began, 2);
      expect(r.session.active, isTrue);
    });
  });

  group('R: the stream stops before the interval is written', () {
    test('stop, then record', () async {
      final r = _Rig();
      await r.session.start(_tap());
      await r.steady(1000);
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.log, ['begin', 'finished', 'end', 'record']);
    });

    test('a database that hangs cannot delay the stop', () async {
      final r = _Rig(recordGate: Completer<void>());
      await r.session.start(_tap());
      await r.steady(1000);
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.ended, 1, reason: 'stopped before the write was even tried');
      expect(r.records, hasLength(1));
      expect(r.session.active, isFalse);
    });

    test('a slow stop widens the interval to cover the time it took', () async {
      var strap = 1002; // strap clock seconds, as strapNow reports them
      final r = _Rig(strapClock: () => strap);
      r.stopTakesStrapSec = () => strap += 9;
      await r.session.start(_tap());
      // Strap time is a packet's NEWEST sample: packets 1000 and 1001 cover
      // 999.0 .. 1001.0.
      await r.steady(1000);
      r.alive = false;
      r.session.poll();
      await r.settle();
      final g = r.records.single;
      expect(g.strapStart, 999);
      // Strap now after the stop is 1011 (floor); the recording may have run
      // until 1011.999..., so the end is rounded UP: 1012.
      expect(g.strapEnd, 1012);
    });

    test('with no strap clock the end is still the last packet end', () async {
      final r = _Rig();
      await r.session.start(_tap());
      await r.steady(1000);
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.records.single.strapEnd, 1001);
    });

    test('a packet-less abandon (stream never delivered) is still bounded by '
        'the strap clock at stop', () async {
      var strap = 7000;
      final r = _Rig(strapClock: () => strap);
      r.stopTakesStrapSec = () => strap += 4;
      await r.session.start(_tap());
      r.alive = false;
      r.session.poll();
      await r.settle();
      final g = r.records.single;
      expect(g.strapStart, 7000);
      expect(g.strapEnd, 7005);
    });

    test('a start that times out stops the stream before recording', () async {
      final gate = Completer<void>();
      final r = _Rig(beginGate: gate);
      await r.session.start(_tap()); // fallback on: ends with count 2, no throw
      expect(r.log, ['begin', 'finished', 'end', 'record']);
      expect(r.records.single.reason, contains('start_failed'));
      gate.complete();
    });

    test('a start that is refused does not call endStream (nothing to stop)',
        () async {
      // beginStream false -> StateError, stream never up.
      final r = _Rig();
      final s2 = EcgTapSession(
        beginStream: () async => false,
        endStream: () async => r.ended++,
        isStreamAlive: () => true,
        buzz: (_, _) async => true,
        maxTaps: () => 3,
        thresholds: EcgTapThresholds.new,
        onFinished: (_, _) {},
        recordSession: (rec) async => r.records.add(rec),
        now: () => _t0,
      );
      await s2.start(_tap()); // fallback on: no throw, the gesture just ends
      expect(r.ended, 0);
      expect(r.records, hasLength(1));
    });

    test('latches are clear after the exit and the next gesture starts',
        () async {
      final r = _Rig();
      await r.session.start(_tap());
      await r.steady(1000);
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.session.active, isFalse);
      r.alive = true;
      await r.session.start(_tap(sec: 9));
      expect(r.session.active, isTrue);
    });
  });
}
