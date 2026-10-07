// natural_wake_card.dart — shown on Home while Natural Wake is repeating its
// buzz. The repeat has no other off switch the wearer can see: this button is
// "I'm up" (an explicit acknowledgement; the native alarm at T stays armed), and
// a double tap on the band does the same. Gone the moment the repeat stops.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../wake/wake_controller.dart';
import '../ui2.dart';

class NaturalWakeBuzzingCard extends StatelessWidget {
  const NaturalWakeBuzzingCard({super.key, required this.wake});
  final WakeController wake;

  @override
  Widget build(BuildContext c) => ValueListenableBuilder<bool>(
        valueListenable: wake.naturalBuzzing,
        builder: (c, buzzing, _) {
          if (!buzzing) return const SizedBox.shrink();
          final p = P.of(c);
          return Padding(
            padding: const EdgeInsets.only(top: S.x3),
            child: Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Natural Wake is buzzing',
                      key: const ValueKey('natural-wake-buzzing'),
                      style: F.t2.copyWith(color: p.ink)),
                  const SizedBox(height: S.x1),
                  Text('or double-tap the band',
                      style: F.cap.copyWith(color: p.ink2)),
                  const SizedBox(height: S.x3),
                  BigButton(
                    "I'm up",
                    key: const ValueKey('natural-wake-im-up'),
                    icon: LucideIcons.sunrise,
                    // The native alarm at T is not cancelled.
                    onTap: () => wake.acknowledgeWake(cancelNative: false),
                  ),
                ],
              ),
            ),
          );
        },
      );
}
