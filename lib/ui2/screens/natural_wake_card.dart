// Home's acknowledgement card for Natural, Gradual and native alarm wakes.
// The controller owns the pending epoch; all paths use the same dream question.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../wake/wake_controller.dart';
import '../../wake/wake_outcome.dart';
import '../../l10n/app_localizations.dart';
import 'wake_dream_question.dart';
import '../ui2.dart';

class NaturalWakeBuzzingCard extends StatelessWidget {
  const NaturalWakeBuzzingCard({super.key, required this.wake});
  final WakeController wake;

  @override
  Widget build(BuildContext c) => ListenableBuilder(
        listenable: Listenable.merge([wake, wake.naturalBuzzing]),
        builder: (c, _) {
          final buzzing = wake.naturalBuzzing.value;
          if (!buzzing && wake.awaitingWakeEpoch == null) {
            return const SizedBox.shrink();
          }
          final p = P.of(c);
          final l = AppLocalizations.of(c);
          final title = buzzing ? 'Natural Wake is buzzing' : switch (wake.awaitingWakePath) {
            WakePath.natural => l?.wakeJournalNatural ?? 'Natural wake',
            WakePath.gradual => l?.wakeJournalGradual ?? 'Gradual wake',
            WakePath.alarm || null => l?.wakeJournalAlarm ?? 'Alarm',
          };
          return Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  key: const ValueKey('natural-wake-buzzing'),
                  style: F.t2.copyWith(color: p.ink),
                ),
                const SizedBox(height: S.x1),
                Text(
                  'or double-tap the band',
                  style: F.cap.copyWith(color: p.ink2),
                ),
                const SizedBox(height: S.x3),
                BigButton(
                  AppLocalizations.of(c)?.wakeJournalImUp ?? "I'm up",
                  key: const ValueKey('natural-wake-im-up'),
                  icon: LucideIcons.sunrise,
                  // The native alarm at T is not cancelled.
                  onTap: () => acknowledgeWakeAndAsk(c, wake),
                ),
              ],
            ),
          );
        },
      );
}
