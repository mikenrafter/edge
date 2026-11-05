// The confirm sheet the pairing screens share: a title, a sentence, the C1
// comparison, one main button, an optional second choice and "Go back". The
// callers differ only in words and labels, so there is one sheet.
import 'package:flutter/material.dart';

import '../../ble/slot_comparison.dart';
import '../ui2.dart';
import 'pair_widgets.dart';
import 'slot_comparison_view.dart';

/// What the user picked on a [PairChoiceSheet].
enum PairChoice { primary, secondary, back }

class PairChoiceSheet extends StatelessWidget {
  final String title;
  final String? body;
  final SlotComparison comparison;
  final String? bandHeading, sensorHeading;

  /// Why the band column is unavailable (a non-WHOOP band); null when it is not.
  final String? bandUnavailableReason;

  /// The main button. Green when it is the recommended path, soft blue when
  /// it is the deliberate "anyway" one.
  final String primaryLabel;
  final IconData? primaryIcon;
  final bool primaryIsRecommended;

  /// The second choice, a text link under the button. Null hides it.
  final String? secondaryLabel;
  final String backLabel;

  const PairChoiceSheet({
    super.key,
    required this.title,
    this.body,
    required this.comparison,
    this.bandHeading,
    this.sensorHeading,
    this.bandUnavailableReason,
    required this.primaryLabel,
    this.primaryIcon,
    this.primaryIsRecommended = false,
    this.secondaryLabel,
    required this.backLabel,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    void pop(PairChoice v) => Navigator.of(c).pop(v);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x4),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title,
                  key: const ValueKey('choice-title'),
                  style: F.t2.copyWith(color: p.ink)),
              if (body != null) ...[
                const SizedBox(height: S.x2),
                Text(body!, style: F.body.copyWith(color: p.ink2)),
              ],
              const SizedBox(height: S.x4),
              SlotComparisonView(
                  comparison: comparison,
                  bandHeading: bandHeading,
                  sensorHeading: sensorHeading,
                  bandUnavailableReason: bandUnavailableReason),
              const SizedBox(height: S.x4),
              BigButton(primaryLabel,
                  icon: primaryIcon,
                  color: primaryIsRecommended ? C.green : C.blue,
                  soft: !primaryIsRecommended,
                  onTap: () => pop(PairChoice.primary)),
              if (secondaryLabel != null)
                TextLinkButton(secondaryLabel!,
                    onTap: () => pop(PairChoice.secondary)),
              TextLinkButton(backLabel, onTap: () => pop(PairChoice.back)),
            ]),
      ),
    );
  }
}

/// Shows [sheet] from the bottom; null when dismissed without a choice.
Future<PairChoice?> showPairChoiceSheet(BuildContext c, PairChoiceSheet sheet) {
  final p = P.of(c);
  return showModalBottomSheet<PairChoice>(
    context: c,
    backgroundColor: p.card,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => sheet,
  );
}
