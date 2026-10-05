// StrapEvent — the value object that replaces the positional
// `EventSink(int eventId, int tsEpoch, String hex)` callback.
//
// (The roadmap calls it `BandEvent`; that name is already taken by the sealed
// adapter-event class in lib/ble/adapters/adapter.dart, so the contract uses
// `StrapEvent`. See test/gestures/gestures_contract.md.)
//
// Everything here is pure: no clock, no time zone, no DB. Fixed instants only.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

// A fixed instant that does not depend on today's date or the machine zone.
final DateTime _t0 = DateTime.utc(2026, 3, 14, 12, 0, 0);
final int _t0Sec = _t0.millisecondsSinceEpoch ~/ 1000;

StrapEvent _ev({
  int eventId = 14,
  int? tsEpoch,
  int tsSubsec = 0,
  DateTime? receivedAt,
  String hex = '',
  String deviceId = 'dev-a',
}) =>
    StrapEvent(
      eventId: eventId,
      tsEpoch: tsEpoch ?? _t0Sec,
      tsSubsec: tsSubsec,
      receivedAt: receivedAt ?? _t0,
      hex: hex,
      deviceId: deviceId,
    );

/// A real-shaped EVENT (0x30) inner frame:
/// `[type][seq][u16 id][u32 unix][u16 subsec][u16 body len][body…]`.
String _eventHex(int id, int ts, int subsec, {List<int> body = const []}) {
  final b = Uint8List(12 + body.length);
  final v = ByteData.sublistView(b);
  b[0] = 0x30;
  b[1] = 0x07;
  v.setUint16(2, id, Endian.little);
  v.setUint32(4, ts, Endian.little);
  v.setUint16(8, subsec, Endian.little);
  v.setUint16(10, body.length, Endian.little);
  b.setRange(12, b.length, body);
  return [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
}

void main() {
  group('strapTime — whole seconds plus subsec/32768, microsecond precision', () {
    test('subsec 0 is exactly the whole second, as a UTC instant', () {
      final t = _ev().strapTime;
      expect(t.isUtc, isTrue);
      expect(t.microsecondsSinceEpoch, _t0Sec * 1000000);
    });

    test('the unit is 1/32768 s: 16384 is exactly half a second', () {
      expect(_ev(tsSubsec: 16384).strapTime.microsecondsSinceEpoch,
          _t0Sec * 1000000 + 500000);
    });

    test('known conversions floor to the microsecond', () {
      // 1/32768 s = 30.517578125 us.
      const expected = {
        1: 30,
        2: 61,
        3: 91,
        8192: 250000,
        24576: 750000,
        32767: 999969,
      };
      expected.forEach((subsec, micros) {
        expect(_ev(tsSubsec: subsec).strapTime.microsecondsSinceEpoch,
            _t0Sec * 1000000 + micros,
            reason: 'subsec $subsec');
      });
    });

    test('every legal subsec stays inside its own second and never goes backwards',
        () {
      var prev = -1;
      for (var s = 0; s < 32768; s++) {
        final us = _ev(tsSubsec: s).strapTime.microsecondsSinceEpoch;
        expect(us - _t0Sec * 1000000, (s * 1000000) ~/ 32768, reason: '$s');
        expect(us ~/ 1000000, _t0Sec, reason: 'subsec $s carried a second');
        expect(us, greaterThanOrEqualTo(prev));
        prev = us;
      }
    });

    test('receipt time never leaks into the strap time', () {
      final a = _ev(receivedAt: _t0).strapTime;
      final b = _ev(receivedAt: _t0.add(const Duration(days: 3))).strapTime;
      expect(a, b);
    });
  });

  group('identity — stable across re-delivery', () {
    test('exact format: device:eventId:tsEpoch:tsSubsec', () {
      expect(_ev(tsSubsec: 123).identity, 'dev-a:14:$_t0Sec:123');
    });

    test('a re-sent event (different receipt time, different bytes) is the same occurrence',
        () {
      final first = _ev(tsSubsec: 77, receivedAt: _t0, hex: 'aa');
      final resent = _ev(
          tsSubsec: 77,
          receivedAt: _t0.add(const Duration(hours: 9)),
          hex: 'bb');
      expect(resent.identity, first.identity);
    });

    test('parsing the same frame at two receive times gives one identity', () {
      final hex = _eventHex(14, _t0Sec, 4242);
      final a = StrapEvent.tryParseHex(hex, receivedAt: _t0, deviceId: 'd')!;
      final b = StrapEvent.tryParseHex(hex,
          receivedAt: _t0.add(const Duration(minutes: 5)), deviceId: 'd')!;
      expect(a.identity, b.identity);
    });

    test('each component distinguishes occurrences', () {
      final base = _ev(tsSubsec: 5).identity;
      expect(_ev(tsSubsec: 6).identity, isNot(base), reason: 'subsec');
      expect(_ev(tsSubsec: 5, tsEpoch: _t0Sec + 1).identity, isNot(base),
          reason: 'epoch');
      expect(_ev(tsSubsec: 5, eventId: 7).identity, isNot(base),
          reason: 'event id');
      expect(_ev(tsSubsec: 5, deviceId: 'dev-b').identity, isNot(base),
          reason: 'device');
    });
  });

  group('plausible — is the strap clock believable?', () {
    test('thresholds are published constants', () {
      expect(kMinPlausibleStrapEpoch, 1577836800); // 2020-01-01T00:00:00Z
      expect(kMaxStrapFutureSkew, const Duration(seconds: 60));
      expect(kLiveEventWindow, const Duration(seconds: 6));
      expect(kSubsecUnitsPerSecond, 32768);
    });

    test('a normal live tap is plausible', () {
      expect(_ev().plausible, isTrue);
    });

    test('an unset RTC is not: epoch 0 and anything before 2020', () {
      expect(_ev(tsEpoch: 0).plausible, isFalse);
      expect(_ev(tsEpoch: 1000).plausible, isFalse);
      expect(
          _ev(tsEpoch: kMinPlausibleStrapEpoch - 1, receivedAt: _t0)
              .plausible,
          isFalse);
      expect(
          _ev(tsEpoch: kMinPlausibleStrapEpoch, receivedAt: _t0).plausible,
          isTrue);
    });

    test('a clock ahead of the phone by up to 60 s is tolerated, not beyond',
        () {
      // Strap time is _t0 (subsec 0); receipt exactly 60 s earlier.
      final exactly60 = DateTime.utc(2026, 3, 14, 11, 59, 0);
      expect(_ev(receivedAt: exactly60).plausible, isTrue);
      final justOver = exactly60.subtract(const Duration(microseconds: 1));
      expect(_ev(receivedAt: justOver).plausible, isFalse);
    });

    test('a strap clock two hours ahead is implausible', () {
      expect(_ev(tsEpoch: _t0Sec + 7200).plausible, isFalse);
    });

    test('a long outage is NOT implausible: 3 and 40 days old are real clocks',
        () {
      expect(_ev(tsEpoch: _t0Sec - 3 * 86400).plausible, isTrue);
      expect(_ev(tsEpoch: _t0Sec - 40 * 86400).plausible, isTrue);
    });

    test('a corrupt subsec (>= 32768 or negative) is implausible', () {
      expect(_ev(tsSubsec: 32768).plausible, isFalse);
      expect(_ev(tsSubsec: 65535).plausible, isFalse);
      expect(_ev(tsSubsec: -1).plausible, isFalse);
      expect(_ev(tsSubsec: 32767).plausible, isTrue);
    });
  });

  group('age / isLive / timeSource', () {
    test('age is receipt minus strap time, with the subsec counted', () {
      final e = _ev(
          tsSubsec: 16384, receivedAt: _t0.add(const Duration(seconds: 2)));
      expect(e.age, const Duration(seconds: 1, milliseconds: 500));
    });

    test('age is null when the strap clock is not plausible', () {
      expect(_ev(tsEpoch: 0).age, isNull);
    });

    test('live window is 6 s inclusive, to the microsecond', () {
      expect(_ev(receivedAt: _t0.add(const Duration(seconds: 6))).isLive,
          isTrue);
      expect(
          _ev(receivedAt: _t0.add(const Duration(seconds: 6, microseconds: 1)))
              .isLive,
          isFalse);
      expect(_ev(receivedAt: _t0).isLive, isTrue);
    });

    test('subsec moves the boundary: 0.5 s of subsec buys 0.5 s of age', () {
      final late = _t0.add(const Duration(seconds: 6, milliseconds: 500));
      expect(_ev(receivedAt: late).isLive, isFalse);
      expect(_ev(tsSubsec: 16384, receivedAt: late).isLive, isTrue);
    });

    test('a strap clock slightly ahead (still plausible) counts as live', () {
      expect(
          _ev(tsEpoch: _t0Sec + 30).isLive, isTrue); // 30 s ahead of receipt
    });

    test('an implausible clock is treated as live and says it used the receipt',
        () {
      final e = _ev(tsEpoch: 0);
      expect(e.isLive, isTrue);
      expect(e.timeSource, EventTimeSource.receipt);
      expect(e.effectiveTime, _t0.toUtc());
    });

    test('a plausible clock is the time source and the effective time', () {
      final e = _ev(tsSubsec: 16384, receivedAt: _t0.add(const Duration(hours: 5)));
      expect(e.timeSource, EventTimeSource.strap);
      expect(e.effectiveTime, e.strapTime);
      expect(e.isLive, isFalse);
    });
  });

  group('construction from the wire', () {
    test('tryParseHex reads id, whole seconds and subsec from the frame', () {
      final hex = _eventHex(14, _t0Sec, 29491);
      final e = StrapEvent.tryParseHex(hex,
          receivedAt: _t0, deviceId: 'dev-a')!;
      expect(e.eventId, 14);
      expect(e.tsEpoch, _t0Sec);
      expect(e.tsSubsec, 29491);
      expect(e.hex, hex, reason: 'raw hex is kept verbatim for diagnostics');
      expect(e.deviceId, 'dev-a');
      expect(e.receivedAt, _t0);
      expect(e.name, 'DOUBLE_TAP');
      expect(e.decoded['double_tap'], isTrue);
    });

    test('fromEventInfo carries the protocol parser\'s tsSubsec through', () {
      final hex = _eventHex(14, _t0Sec, 1234);
      final info = proto.parseEvent(proto.hexToBytes(hex))!;
      expect(info.tsSubsec, 1234); // the protocol already decodes it
      final e = StrapEvent.fromEventInfo(info,
          receivedAt: _t0, hex: hex, deviceId: 'dev-a');
      expect(e.tsSubsec, 1234);
      expect(e.tsEpoch, info.tsEpoch);
      expect(e.eventId, info.eventId);
    });

    test('a real strap frame (charging on) parses to the protocol\'s numbers',
        () {
      const hex = '30b707003c8c7b6acc6c0000';
      final info = proto.parseEvent(proto.hexToBytes(hex))!;
      final e = StrapEvent.tryParseHex(hex, receivedAt: _t0, deviceId: 'd')!;
      expect(e.eventId, 7);
      expect(e.tsEpoch, info.tsEpoch);
      expect(e.tsSubsec, info.tsSubsec);
    });

    test('anything that is not an event frame is null, never a made-up event',
        () {
      expect(StrapEvent.tryParseHex('', receivedAt: _t0, deviceId: 'd'),
          isNull);
      expect(StrapEvent.tryParseHex('zz', receivedAt: _t0, deviceId: 'd'),
          isNull);
      // A historical-data record (0x2f), not an event.
      expect(
          StrapEvent.tryParseHex('2f128000394801a6e5776a00',
              receivedAt: _t0, deviceId: 'd'),
          isNull);
    });

    test('copyWith swaps the device and nothing else', () {
      final a = _ev(tsSubsec: 9, hex: 'ab');
      final b = a.copyWith(deviceId: 'dev-b');
      expect(b.deviceId, 'dev-b');
      expect(b.tsSubsec, 9);
      expect(b.hex, 'ab');
      expect(b.receivedAt, a.receivedAt);
      expect(b.identity, isNot(a.identity));
    });
  });
}
