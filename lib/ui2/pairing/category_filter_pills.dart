// K3: filter pills over a device list ("All · Straps · Rings · Watches · …").
// One widget, one file, so the list grouping can be swapped for another style
// (accordions, plain headers) without touching a screen.
import 'package:flutter/material.dart';

import '../../ble/adapters/_registry.dart';
import '../ui2.dart';
import 'pair_text.dart';

/// [entries] narrowed to [kind]; null keeps them all.
List<BandEntry> filterByKind(Iterable<BandEntry> entries, DeviceKind? kind) => [
  for (final e in entries)
    if (kind == null || e.kind == kind) e,
];

class CategoryFilterPills extends StatelessWidget {
  /// The kind of every entry currently in the list (repeats are fine). Only
  /// kinds that appear get a pill; they show in [DeviceKind] order.
  final Iterable<DeviceKind> kinds;

  /// The chosen kind; null means All. Set by a tap, listened to by the screen.
  final ValueNotifier<DeviceKind?> selection;

  const CategoryFilterPills({
    super.key,
    required this.kinds,
    required this.selection,
  });

  @override
  Widget build(BuildContext c) {
    final present = {...kinds};
    final shown = [
      for (final k in DeviceKind.values)
        if (present.contains(k)) k,
    ];
    // One kind (or none) has nothing to filter between.
    if (shown.length < 2) return const SizedBox.shrink();
    final l = pairL10n(c);
    return ValueListenableBuilder<DeviceKind?>(
      valueListenable: selection,
      builder: (_, selected, _) => Wrap(
        spacing: S.x2,
        runSpacing: S.x2,
        children: [
          _Pill(const ValueKey('pill-all'), l.pairKindAll, selected == null,
              () => selection.value = null),
          for (final k in shown)
            _Pill(ValueKey('pill-${k.name}'), deviceKindLabel(l, k),
                selected == k, () => selection.value = k),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;
  const _Pill(Key key, this.text, this.selected, this.onTap) : super(key: key);

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Semantics(
      selected: selected,
      child: Pressable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? Color.alphaBlend(p.wash(C.blue), p.card) : null,
            borderRadius: R.rPill,
            border: Border.all(
                color: selected ? p.on(C.blue).withValues(alpha: .7) : p.line),
          ),
          child: Text(text,
              style: F.cap.copyWith(
                  color: selected ? p.ink : p.ink2,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
        ),
      ),
    );
  }
}
