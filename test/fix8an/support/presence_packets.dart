// Packet and tap builders shared by the 8AN tests. Existing API only, so a
// test that needs nothing new compiles against today's code.

import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../../support/ecg_trace.dart' show r17;

final DateTime t0 = DateTime.utc(2026, 10, 4, 8);

StrapEvent tapAt({int ms = 300}) => StrapEvent(
      eventId: 14,
      tsEpoch: t0.millisecondsSinceEpoch ~/ 1000,
      receivedAt: t0.add(Duration(milliseconds: ms)),
      hex: '',
      deviceId: 'band',
    );

/// One live packet whose newest sample is at strap second [sec]. [presence]
/// is the band's own flag (flags bit 3); [contact] makes the samples a moving
/// trace (the sample-level contact detector reads it as a finger), otherwise
/// they are all zero. [contactFrom]..[contactTo] (sample indexes, 10 ms each)
/// put the moving trace in part of the packet only: 5..25 is a 200 ms touch.
LabradorR17 presencePacket(
  int sec, {
  bool presence = false,
  bool contact = false,
  int? contactFrom,
  int? contactTo,
  int unreadable = 0,
}) =>
    r17(
      strapSeconds: sec,
      samples: [
        for (var i = 0; i < 100; i++)
          (contact || contactFrom != null) &&
                  i >= (contactFrom ?? 0) &&
                  i < (contactTo ?? 100)
              ? (i.isEven ? 120 : -120)
              : 0,
      ],
      flags: presence ? 0x08 : 0,
      unreadable: unreadable,
    );
