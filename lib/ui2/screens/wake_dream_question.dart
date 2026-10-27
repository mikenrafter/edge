// One question flow for every Home wake acknowledgement. The controller owns
// the occurrence; the modal captures its epoch before stopping the wake.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../wake/wake_controller.dart';
import '../../wake/wake_outcome.dart';

Future<void> acknowledgeWakeAndAsk(
  BuildContext context,
  WakeController wake,
) async {
  final epoch = wake.awaitingWakeEpoch;
  final navigator = Navigator.of(context);
  // Start stopping now, independently of the optional question. Answers wait
  // for the durable ack, while SQLite latency never delays the question.
  final ack = wake.acknowledgeWake(cancelNative: false);
  if (epoch == null || !navigator.mounted) {
    await ack;
    return;
  }
  await showDialog<void>(
    context: navigator.context,
    builder: (c) {
      Future<void> answer(DreamAnswer answer) async {
        final saving = ack.then((_) => wake.answerDream(epoch, answer));
        Navigator.of(c).pop();
        await saving;
      }

      return WakeDreamQuestionDialog(
        onDream: () => answer(DreamAnswer.dream),
        onNormal: () => answer(DreamAnswer.normal),
        onSkip: () => Navigator.of(c).pop(),
      );
    },
  );
  await ack;
}

/// How did you wake up? Asked after I'm up on every wake path.
class WakeDreamQuestionDialog extends StatelessWidget {
  const WakeDreamQuestionDialog({
    super.key,
    required this.onDream,
    required this.onNormal,
    required this.onSkip,
  });
  final VoidCallback onDream;
  final VoidCallback onNormal;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    return AlertDialog(
      title: Text(l?.wakeDreamQuestion ?? 'How did you wake up?'),
      actions: [
        TextButton(
          onPressed: onDream,
          child: Text(l?.wakeDreamFromDream ?? 'From a dream'),
        ),
        TextButton(
          onPressed: onNormal,
          child: Text(l?.wakeDreamNormally ?? 'Normally'),
        ),
        TextButton(
          onPressed: onSkip,
          child: Text(l?.wakeDreamSkip ?? 'Skip'),
        ),
      ],
    );
  }
}
