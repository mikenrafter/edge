// S5: a paired secondary sensor, said plainly: what role it has, what it sends
// and what it does not. The lists are the sensor column of the slot
// comparison (C1) as lines; "Experimental" is only a small footnote.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/adapters/_registry.dart';
import '../../ble/slot_comparison.dart';
import '../ui2.dart';
import 'pair_text.dart';

class SecondarySensorCard extends StatelessWidget {
  final BandEntry entry;

  /// Whether nobody has checked this sensor's readings against hardware yet.
  final bool experimental;

  const SecondarySensorCard(
      {super.key, required this.entry, this.experimental = false});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = pairL10n(c);
    final side = slotComparisonFor(entry).asSensor;
    final sends = [
      for (final k in DeviceCapability.values)
        if (side.sends.containsKey(k)) k,
    ];
    final doesnt = [
      for (final k in DeviceCapability.values)
        if (side.doesNotSend.contains(k)) k,
    ];
    return Surface(
      key: const ValueKey('secondary-sensor-card'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Pill(l.pairSecondaryPill, C.blue,
            icon: LucideIcons.heartPulse, wrap: true),
        const SizedBox(height: S.x3),
        Text(l.pairSecondaryPaired,
            style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w700)),
        const SizedBox(height: S.x2),
        if (sends.isNotEmpty) ...[
          _Heading(l.slotSendsHeading),
          for (final k in sends)
            _Line('secondary-sends-${k.name}', true, capabilityLabel(l, k)),
        ],
        if (doesnt.isNotEmpty) ...[
          const SizedBox(height: S.x2),
          _Heading(l.slotDoesntSendHeading),
          for (final k in doesnt)
            _Line('secondary-doesnt-${k.name}', false, capabilityLabel(l, k)),
        ],
        if (experimental) ...[
          const SizedBox(height: S.x3),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(LucideIcons.flaskConical, size: 12, color: p.ink3),
            ),
            const SizedBox(width: S.x2),
            Expanded(
              child: Text(l.pairSecondaryExperimental,
                  style: F.over.copyWith(color: p.ink3)),
            ),
          ]),
        ],
      ]),
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  const _Heading(this.text);
  @override
  Widget build(BuildContext c) => Padding(
        padding: const EdgeInsets.only(bottom: S.x1),
        child: Text(text,
            style: F.cap.copyWith(
                color: P.of(c).ink3, fontWeight: FontWeight.w600)),
      );
}

class _Line extends StatelessWidget {
  final String keyName;
  final bool sends;
  final String text;
  const _Line(this.keyName, this.sends, this.text);
  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Padding(
      key: ValueKey(keyName),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Icon(sends ? LucideIcons.check : LucideIcons.x,
              size: 14, color: sends ? p.on(C.green) : p.ink3),
        ),
        const SizedBox(width: S.x2),
        Expanded(
          child: Text(text,
              style: F.body.copyWith(color: sends ? p.ink : p.ink2)),
        ),
      ]),
    );
  }
}
