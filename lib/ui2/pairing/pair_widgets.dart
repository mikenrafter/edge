// Small pieces the pairing screens share: a numbered step, an outline button,
// a text link and a tappable icon row. Kept in one file so the screens read
// alike; none of them knows anything about pairing itself.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui2.dart';

/// A numbered step: a round badge and the instruction beside it.
class PairStepRow extends StatelessWidget {
  final int number;
  final String text;
  const PairStepRow(this.number, this.text, {super.key});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration:
              BoxDecoration(color: p.wash(C.blue), shape: BoxShape.circle),
          child: Text('$number',
              style: F.cap
                  .copyWith(color: p.on(C.blue), fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: S.x3),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(text, style: F.body.copyWith(color: p.ink)),
          ),
        ),
      ]),
    );
  }
}

/// A full-width outlined button. [quiet] is the muted grey one ("I can't pair
/// my band"); otherwise it takes [color]'s ink (a red "Unpair band").
class OutlineAction extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final bool quiet;
  final VoidCallback? onTap;
  const OutlineAction(this.label,
      {super.key, this.icon, this.color = C.blue, this.quiet = false, this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final ink = quiet ? p.ink2 : p.on(color);
    return Pressable(
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(minHeight: quiet ? S.tap : 52),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: R.rMd,
          border: Border.all(color: quiet ? p.line : ink, width: 1.5),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: quiet ? 16 : 18, color: ink),
            const SizedBox(width: S.x2),
          ],
          Flexible(
            child: Text(label,
                textAlign: TextAlign.center,
                style: (quiet
                        ? F.body.copyWith(fontWeight: FontWeight.w600)
                        : F.head)
                    .copyWith(color: ink)),
          ),
        ]),
      ),
    );
  }
}

/// Centred blue text that acts as a link.
class TextLinkButton extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  const TextLinkButton(this.text, {super.key, this.onTap});

  @override
  Widget build(BuildContext c) => Pressable(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: S.x3),
          child: Center(
            child: Text(text,
                textAlign: TextAlign.center,
                style: F.body.copyWith(
                    color: P.of(c).on(C.blue), fontWeight: FontWeight.w600)),
          ),
        ),
      );
}

/// A card row: an icon tile, a title with one line beneath, a trailing icon.
class ChoiceRow extends StatelessWidget {
  final IconData icon, trailing;
  final String title, sub;
  final VoidCallback? onTap;
  const ChoiceRow(this.icon, this.title, this.sub,
      {super.key, this.trailing = LucideIcons.externalLink, this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(S.x3),
        decoration: BoxDecoration(
            color: p.card2,
            borderRadius: R.rLg,
            border: Border.all(color: p.line)),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration:
                BoxDecoration(color: p.wash(C.blue), borderRadius: R.rMd),
            child: Icon(icon, size: 22, color: p.on(C.blue)),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: F.body
                          .copyWith(color: p.ink, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(sub, style: F.cap.copyWith(color: p.ink2)),
                ]),
          ),
          const SizedBox(width: S.x2),
          Icon(trailing, size: 18, color: p.ink3),
        ]),
      ),
    );
  }
}
