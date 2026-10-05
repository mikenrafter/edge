// 8AF.6 C: the wiring behind the gesture cues (see gesture_cues_test.dart for
// the cues themselves, played against the virtual MG band).
//
//  - The ECG tap session asks for ONE follow-up cue per count increment (8AI.3:
//    additive, one call each, never a recount of the pulses so far).
//  - AppState._ecgTapBuzz stops building the fixed 300 ms per-tap BuzzSequence
//    for a profiled band and hands the cue to GestureCues; the failure buzz is
//    still the existing long buzz (not a system pattern); the action-done ack
//    goes through ackTap with the confirm cue.
//
// The AppState checks are source guards (AppState needs a whole engine); they
// pin names and bodies, not behaviour.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../phase8/support/dart_source.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 20);

LabradorR17 _packet(int sec, {int contactFrom = 100}) => LabradorR17(
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
      samples: Int16List.fromList([
        for (var i = 0; i < 100; i++)
          i >= contactFrom ? (i.isEven ? 120 : -120) : 0,
      ]),
      tail: Uint8List(0),
      inner: Uint8List(0),
    );

/// A session with the DEFAULT burst setting, buzzing on a virtual clock.
class _Rig {
  _Rig({required int max}) {
    session = EcgTapSession(
      beginStream: () async => true,
      endStream: () async {},
      isStreamAlive: () => true,
      buzz: (pulses, id) async {
        now = now.add(const Duration(milliseconds: 60));
        calls.add(pulses);
        return true;
      },
      maxTaps: () => max,
      thresholds: EcgTapThresholds.new,
      onFinished: (c, r) => results.add((c, r)),
      now: () => now,
      wait: (d) async => now = now.add(d),
      pollEvery: const Duration(hours: 1),
      sensorReacquire: Duration.zero,
    );
  }

  late final EcgTapSession session;
  DateTime now = _t0;
  final calls = <int>[];
  final results = <(int?, String?)>[];

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> fingerOn() async {
    await session.start(
      StrapEvent(
        eventId: 14,
        tsEpoch: _t0.millisecondsSinceEpoch ~/ 1000,
        receivedAt: _t0.add(const Duration(milliseconds: 300)),
        hex: '',
        deviceId: 'band',
      ),
    );
    now = _t0.add(const Duration(milliseconds: 500));
    session.onFrame(_packet(1000));
    now = _t0.add(const Duration(milliseconds: 1500));
    session.onFrame(_packet(1001));
    await settle();
    now = _t0.add(const Duration(seconds: 2));
    session.onFrame(_packet(1002, contactFrom: 0));
    await settle();
  }
}

void main() {
  group('the ECG session asks for one follow-up per increment', () {
    test('a count of 3 is one follow-up call of one pulse', () async {
      final r = _Rig(max: 3);
      await r.fingerOn();
      expect(r.results, [(3, null)]);
      expect(r.calls, [1],
          reason: 'one increment (2 to 3), one follow-up; never a recount');
    });

    test('a count of 2 has no increment, so no follow-up call', () async {
      final r = _Rig(max: 2);
      await r.fingerOn();
      expect(r.results, [(2, null)]);
      expect(r.calls, isEmpty);
    });
  });

  group('AppState wiring (source guards)', () {
    // The cue methods live in the gesture controller (8AJ seam 3); the ack in
    // _onLiveEvent stays in AppState.
    final src = File('lib/state/gesture_controller.dart').readAsStringSync();
    final appSrc = File('lib/state/app_state.dart').readAsStringSync();

    test('every gesture cue is a dispatcher delivery in the band queue', () {
      final body = codeOnly(bodyOf(src, 'Future<bool> _gestureCue('));
      expect(body, contains('_alertDispatcher().dispatch('));
      expect(body, contains('_haptics.asLabWork('));
      for (final f in [
        'Future<bool> _ecgTapStartBuzz(',
        'Future<bool> _ecgTapBuzz(',
        'Future<bool> _ecgTapConfirmBuzz(',
        'Future<bool> _ecgTapFailBuzz(',
      ]) {
        expect(codeOnly(bodyOf(src, f)), contains('_gestureCue('), reason: f);
      }
    });

    test('the failure buzz is the "Gesture failed" cue (8AK), not a fixed '
        'engine buzz', () {
      // Its built-in default is the long buzz it used to be (pairx2, one
      // command [47, 152] looped twice); see test/gestures8ak/d_failed_cue_test.
      final body = codeOnly(bodyOf(src, 'Future<bool> _ecgTapFailBuzz('));
      expect(body, contains('cues.failed'));
      expect(body, isNot(contains('buzzBand')));
    });

    test('the action-done ack goes through ackTap with the confirm cue', () {
      final body = codeOnly(bodyOf(appSrc, 'void _onLiveEvent('));
      expect(body, contains('ackTap('));
      expect(body, contains('gestureCues.confirm'));
    });
  });
}
