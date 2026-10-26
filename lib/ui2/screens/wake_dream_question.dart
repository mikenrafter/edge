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
  final l = AppLocalizations.of(context);
  // Start stopping now, independently of the optional question. Answers wait
  // for the durable ack, while SQLite latency never delays the question.
  final ack = wake.acknowledgeWake(cancelNative: false);
  if (epoch == null || !navigator.mounted) {
    await ack;
    return;
  }
  await showDialog<void>(
    context: navigator.context,
    builder: (c) => WakeDreamQuestionDialog(
      onAnswer: (answer) async {
        final saving = ack.then((_) => wake.answerDream(epoch, answer));
        Navigator.of(c).pop();
        await saving;
      },
      onSkip: () => Navigator.of(c).pop(),
    ),
  );
  await ack;
}

/// How did you wake up? Asked after I'm up on every wake path.
class WakeDreamQuestionDialog extends StatelessWidget {
  const WakeDreamQuestionDialog({
    super.key,
    required this.onAnswer,
    required this.onSkip,
  });
  final Future<void> Function(DreamAnswer answer) onAnswer;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    return AlertDialog(
      title: Text(l?.wakeDreamQuestion ?? 'How did you wake up?'),
      actions: [
        TextButton(
          onPressed: () => onAnswer(DreamAnswer.dream),
          child: Text(l?.wakeDreamFromDream ?? 'From a dream'),
        ),
        TextButton(
          onPressed: () => onAnswer(DreamAnswer.normal),
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
