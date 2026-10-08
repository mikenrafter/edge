// The per-second view of a kept ECG window (design 04 item 4): what each
// packet's own header bytes said (quality, presence and S2 flags, the reason
// mask, progress). ONE decoder, [ecgSecondOf], reads a packet's `inner` bytes
// through the protocol's R17 parser; the Details timeline, the capture's
// `mask_any` and nothing else go through it (AGENTS 3.8). Pure Dart.

import 'package:openstrap_protocol/openstrap_protocol.dart' show LabradorR17;

import 'ecg_models.dart';

/// One accepted second as the band described it.
class EcgSecond {
  const EcgSecond({
    required this.ordinal,
    required this.placeholder,
    required this.decoded,
    this.sequence,
    this.quality,
    this.presence,
    this.currentS2One,
    this.s2State,
    this.progress,
    this.mask,
  });

  /// Position in the accepted window.
  final int ordinal;

  /// The one empty segment inserted at a sequence jump: no band bytes.
  final bool placeholder;

  /// False when the kept bytes are not a readable R17 packet.
  final bool decoded;
  final int? sequence;

  /// Band-reported, scale unknown.
  final int? quality;
  final bool? presence;
  final bool? currentS2One;
  final int? s2State;
  final int? progress;

  /// The band's reason bits for this second.
  final int? mask;
}

/// The one decoder: a packet's header fields, or an [EcgSecond] with
/// `decoded: false` for a placeholder or bytes that are not an R17 packet.
EcgSecond ecgSecondOf(int ordinal, EcgAcceptedPacket p) {
  if (p.placeholder) {
    return EcgSecond(ordinal: ordinal, placeholder: true, decoded: false);
  }
  final r = LabradorR17.parse(p.inner, allowStored: true);
  if (r == null) {
    return EcgSecond(
      ordinal: ordinal,
      placeholder: false,
      decoded: false,
      sequence: p.sequence,
    );
  }
  return EcgSecond(
    ordinal: ordinal,
    placeholder: false,
    decoded: true,
    sequence: r.sequence,
    quality: r.quality,
    presence: r.presence,
    currentS2One: r.flags.currentS2One,
    s2State: r.s2State,
    progress: r.progress,
    mask: r.unreadable.raw,
  );
}

/// Every second of [packets], in order.
List<EcgSecond> ecgSecondsOf(List<EcgAcceptedPacket> packets) => [
  for (var i = 0; i < packets.length; i++) ecgSecondOf(i, packets[i]),
];

/// Bitwise OR of the reason mask of every decodable second (the capture's
/// `mask_any`, R1'').
int ecgMaskAnyOf(List<EcgAcceptedPacket> packets) {
  var m = 0;
  for (var i = 0; i < packets.length; i++) {
    m |= ecgSecondOf(i, packets[i]).mask ?? 0;
  }
  return m;
}
