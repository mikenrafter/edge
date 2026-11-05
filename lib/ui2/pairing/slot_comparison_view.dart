// C1: what a device gives as a band and as a secondary sensor, as rows of
// capability label + two check/dash marks. One widget, one file, so the
// comparison style can be swapped (toggle, difference-first, chips) without
// touching a screen. The facts come from `slotComparisonFor`; this only draws.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/slot_comparison.dart';
import '../ui2.dart';
import 'pair_text.dart';

/// One matrix row: null on a side means that side does not send it.
typedef SlotRow = ({
  DeviceCapability capability,
  CapabilityStatus? band,
  CapabilityStatus? sensor,
});

/// The rows of [c], in capability order: everything either side sends, plus
/// what a secondary sensor does not send (so "Doesn't send" stays visible).
///
/// A device that is a band at all also records through a workout, so the band
/// column of a workout line is a plain check whenever the band side sends
/// anything. (`slotComparisonFor` lists only whole-day outputs on the band
/// side, by G2's decision.)
List<SlotRow> slotRowsFor(SlotComparison c) {
  final bandSends = c.asBand.sends.isNotEmpty;
  CapabilityStatus? bandStatus(DeviceCapability k) =>
      c.asBand.sends[k] ??
      (bandSends && kSessionCapabilities.contains(k)
          ? const CapabilityStatus(CapabilityKind.native)
          : null);
  return [
    for (final k in DeviceCapability.values)
      if (bandStatus(k) != null ||
          c.asSensor.sends.containsKey(k) ||
          c.asSensor.doesNotSend.contains(k))
        (capability: k, band: bandStatus(k), sensor: c.asSensor.sends[k]),
  ];
}

class SlotComparisonView extends StatelessWidget {
  final SlotComparison comparison;

  /// Column headings; default "Band" / "Sensor".
  final String? bandHeading, sensorHeading;

  /// Non-null when the device cannot be the main band: the band column is
  /// shown as unavailable and this is the reason, in words.
  final String? bandUnavailableReason;

  const SlotComparisonView({
    super.key,
    required this.comparison,
    this.bandHeading,
    this.sensorHeading,
    this.bandUnavailableReason,
  });

  static const double _markWidth = 76;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = pairL10n(c);
    final unavailable = bandUnavailableReason;
    final rows = [
      for (final r in slotRowsFor(comparison))
        unavailable == null
            ? r
            : (capability: r.capability, band: null, sensor: r.sensor),
    ];
    Widget heading(String t) => SizedBox(
          width: _markWidth,
          child: Text(t,
              textAlign: TextAlign.center,
              style: F.cap.copyWith(
                  color: p.ink3, fontWeight: FontWeight.w600)),
        );
    return Container(
      decoration: BoxDecoration(
        color: p.card2,
        borderRadius: R.rLg,
        border: Border.all(color: p.line),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3),
          child: Row(children: [
            const Spacer(),
            heading(bandHeading ?? l.slotBandHeading),
            heading(sensorHeading ?? l.slotSensorHeading),
          ]),
        ),
        for (final r in rows) ...[
          Divider(color: p.line, height: 1),
          _Row(r, l.slotSendsHeading, l.slotDoesntSendHeading,
              bandMarkLabel: unavailable),
        ],
        if (unavailable != null || comparison.asSensor.sends.isEmpty) ...[
          Divider(color: p.line, height: 1),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (unavailable != null)
                    Text(unavailable,
                        key: const ValueKey('slot-band-unavailable'),
                        style: F.cap.copyWith(color: p.ink3)),
                  if (unavailable != null && comparison.asSensor.sends.isEmpty)
                    const SizedBox(height: S.x2),
                  if (comparison.asSensor.sends.isEmpty)
                    Text(l.slotSensorSendsNothing,
                        key: const ValueKey('slot-sensor-sends-nothing'),
                        style: F.cap.copyWith(color: p.ink3)),
                ]),
          ),
        ],
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  final SlotRow row;
  final String sends, doesntSend;

  /// Replaces the band mark's spoken label when the band column is unavailable.
  final String? bandMarkLabel;
  const _Row(this.row, this.sends, this.doesntSend, {this.bandMarkLabel});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = pairL10n(c);
    final k = row.capability.name;
    // The reason of whichever side carries one (the band side, in practice).
    final status = row.band ?? row.sensor;
    final reason = status == null ? null : capabilityReason(l, status);
    Widget mark(String side, CapabilityStatus? s, {String? label}) => SizedBox(
          width: SlotComparisonView._markWidth,
          child: Semantics(
            key: ValueKey('slot-$side-$k'),
            label: label ?? (s != null ? sends : doesntSend),
            excludeSemantics: true,
            child: Icon(s != null ? LucideIcons.check : LucideIcons.minus,
                size: 18, color: s != null ? p.on(C.green) : p.ink3),
          ),
        );
    return Padding(
      key: ValueKey('slot-row-$k'),
      padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(capabilityLabel(l, row.capability),
                    style: F.body.copyWith(color: p.ink)),
                if (reason != null)
                  Text(reason, style: F.cap.copyWith(color: p.ink3)),
              ]),
        ),
        mark('band', row.band, label: bandMarkLabel),
        mark('sensor', row.sensor),
      ]),
    );
  }
}
