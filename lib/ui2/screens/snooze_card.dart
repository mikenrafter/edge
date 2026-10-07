// snooze_card.dart — Home's snooze card: "Snoozed until HH:MM" and an "I'm up"
// button that dismisses. Same pattern as natural_wake_card.dart: it listens to
// the controller's status and is gone the moment no snooze is live. While the
// re-alarm itself buzzes it says so, with the same button.
//
// Pinned by test/alarm_snooze/snooze_ui_test.dart.

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../alarm/snooze/snooze_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../ui2.dart';

class SnoozeCard extends StatelessWidget {
  const SnoozeCard({super.key, required this.status, required this.onImUp});

  /// [SnoozeController.status].
  final ValueListenable<SnoozeStatus> status;

  /// "I'm up" ([SnoozeController.imUp]).
  final Future<void> Function() onImUp;

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext c) => ValueListenableBuilder<SnoozeStatus>(
        valueListenable: status,
        builder: (c, s, _) {
          final snoozed = s.phase == SnoozePhase.snoozed;
          if (!snoozed && s.phase != SnoozePhase.reAlarming) {
            return const SizedBox.shrink();
          }
          final l = AppLocalizations.of(c);
          final p = P.of(c);
          final until = s.until;
          final headline = snoozed && until != null
              ? (l?.snoozeCardUntil(_hhmm(until)) ??
                  'Snoozed until ${_hhmm(until)}')
              : (l?.snoozeCardBuzzing ?? 'Your alarm is buzzing again');
          return Padding(
            padding: const EdgeInsets.only(top: S.x3),
            child: Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(headline,
                      key: const ValueKey('snooze-headline'),
                      style: F.t2.copyWith(color: p.ink)),
                  if (!snoozed) ...[
                    const SizedBox(height: S.x1),
                    Text(l?.snoozeCardHint ?? 'or double-tap the band',
                        style: F.cap.copyWith(color: p.ink2)),
                  ],
                  const SizedBox(height: S.x3),
                  BigButton(
                    l?.snoozeImUp ?? "I'm up",
                    key: const ValueKey('snooze-im-up'),
                    icon: LucideIcons.sunrise,
                    onTap: () => onImUp(),
                  ),
                ],
              ),
            ),
          );
        },
      );
}

/// The card for Home, or null with no AppState above (a golden): the same
/// null-safe insertion as the Natural Wake card, used as `?snoozeCardFor(c)`
/// at both of Home's list sites.
Widget? snoozeCardFor(BuildContext c) {
  try {
    final snooze = c.read<AppState>().snooze;
    return SnoozeCard(status: snooze.status, onImUp: snooze.imUp);
  } on ProviderNotFoundException {
    return null;
  }
}
