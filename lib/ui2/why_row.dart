// The explanation row shared by Home and health observations.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'ui2.dart';

class WhyRow extends StatelessWidget {
  final String id, title, body;
  final Color color;
  final IconData icon;
  final VoidCallback? onTap;
  final bool fullText;
  const WhyRow({super.key,required this.id, required this.title, required this.body,
      required this.color, required this.icon, this.onTap, this.fullText = false});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final panel = Container(key: ValueKey('home-why:$id'),
      padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
      decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(key: ValueKey('home-why-icon:$id'), width: 32, height: 32,
          decoration: BoxDecoration(color: p.on(color).withValues(alpha: .14), shape: BoxShape.circle),
          child: Icon(icon, size: 17, color: p.on(color))),
        const SizedBox(width: S.x2),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(title, key: ValueKey('home-why-title:$id'), maxLines: fullText ? null : 1, overflow: fullText ? null : TextOverflow.ellipsis,
            style: F.body.copyWith(fontWeight: FontWeight.w600, color: p.ink)),
          const SizedBox(height: 2),
          Text(body, key: ValueKey('home-why-body:$id'), maxLines: fullText ? null : 2, overflow: fullText ? null : TextOverflow.ellipsis,
            style: F.cap.copyWith(color: p.ink2)),
        ])),
        const SizedBox(width: S.x1),
        if (onTap != null) Icon(LucideIcons.chevronRight, size: 17, color: p.ink3),
      ]));
    return onTap == null ? panel : Pressable(onTap: onTap, child: panel);
  }
}

