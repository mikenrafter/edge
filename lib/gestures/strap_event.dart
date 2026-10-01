// strap_event.dart — one event frame from the band, with BOTH clocks kept.
//
// The strap stamps every event with its own RTC (whole seconds + a 1/32768 s
// remainder). The phone stamps when the frame arrived. They differ whenever the
// event came out of flash or a delayed notification, so anything that asks
// "when did this happen" must read [effectiveTime]; anything that asks "is this
// happening now" must read [isLive]. Pure: no clock, no time zone, no DB.
//
// (Named StrapEvent, not BandEvent: BandEvent is the adapter event stream's
// sealed class in lib/ble/adapters/adapter.dart.)

import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

/// Event timestamp sub-second unit: the 32768 Hz RTC crystal.
const int kSubsecUnitsPerSecond = 32768;

/// 2020-01-01T00:00:00Z. An unset strap RTC reads ~0 or a tiny count.
const int kMinPlausibleStrapEpoch = 1577836800;

/// How far ahead of the phone a strap clock may run and still be believed.
const Duration kMaxStrapFutureSkew = Duration(seconds: 60);

/// A tap this recent (by strap clock) is "happening now"; older is replayed.
const Duration kLiveEventWindow = Duration(seconds: 6);

enum EventTimeSource { strap, receipt }

class StrapEvent {
  const StrapEvent({
    required this.eventId,
    required this.tsEpoch,
    this.tsSubsec = 0,
    required this.receivedAt,
    required this.hex,
    required this.deviceId,
    this.name = '',
    this.decoded = const {},
  });

  factory StrapEvent.fromEventInfo(
    proto.EventInfo i, {
    required DateTime receivedAt,
    required String hex,
    required String deviceId,
  }) =>
      StrapEvent(
        eventId: i.eventId,
        tsEpoch: i.tsEpoch,
        tsSubsec: i.tsSubsec,
        receivedAt: receivedAt,
        hex: hex,
        deviceId: deviceId,
        name: i.name,
        decoded: i.decoded,
      );

  /// Null for anything that is not an EVENT frame; never throws.
  static StrapEvent? tryParseHex(
    String hex, {
    required DateTime receivedAt,
    required String deviceId,
    proto.BandProfile profile = proto.BandProfile.gen4,
  }) {
    try {
      final info = proto.parseEvent(proto.hexToBytes(hex), profile: profile);
      if (info == null) return null;
      return StrapEvent.fromEventInfo(
        info,
        receivedAt: receivedAt,
        hex: hex,
        deviceId: deviceId,
      );
    } catch (_) {
      return null;
    }
  }

  final int eventId;
  final int tsEpoch;
  final int tsSubsec;
  final DateTime receivedAt;
  final String hex;
  final String deviceId;
  final String name;
  final Map<String, dynamic> decoded;

  StrapEvent copyWith({String? deviceId}) => StrapEvent(
        eventId: eventId,
        tsEpoch: tsEpoch,
        tsSubsec: tsSubsec,
        receivedAt: receivedAt,
        hex: hex,
        deviceId: deviceId ?? this.deviceId,
        name: name,
        decoded: decoded,
      );

  /// The strap's own instant (UTC). Floors the sub-second; never carries.
  DateTime get strapTime => DateTime.fromMicrosecondsSinceEpoch(
        tsEpoch * 1000000 + (tsSubsec * 1000000) ~/ kSubsecUnitsPerSecond,
        isUtc: true,
      );

  /// Persisted inside claim keys: exact format is pinned.
  String get identity => '$deviceId:$eventId:$tsEpoch:$tsSubsec';

  bool get plausible =>
      tsEpoch >= kMinPlausibleStrapEpoch &&
      tsSubsec >= 0 &&
      tsSubsec < kSubsecUnitsPerSecond &&
      !strapTime.isAfter(receivedAt.toUtc().add(kMaxStrapFutureSkew));

  /// receivedAt - strapTime; null when the strap clock is not believable.
  Duration? get age => plausible ? receivedAt.toUtc().difference(strapTime) : null;

  /// An unbelievable clock counts as live (as before this type existed).
  bool get isLive {
    final a = age;
    return a == null || a <= kLiveEventWindow;
  }

  EventTimeSource get timeSource =>
      plausible ? EventTimeSource.strap : EventTimeSource.receipt;

  DateTime get effectiveTime => plausible ? strapTime : receivedAt.toUtc();
}
