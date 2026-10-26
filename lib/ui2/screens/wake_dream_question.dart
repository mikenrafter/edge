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
    builder: (c) => AlertDialog(
      title: Text(l?.wakeDreamQuestion ?? 'How did you wake up?'),
      actions: [
        TextButton(
          onPressed: () async {
            final saving = ack.then((_) => wake.answerDream(epoch, DreamAnswer.dream));
            Navigator.of(c).pop();
            await saving;
          },
          child: Text(l?.wakeDreamFromDream ?? 'From a dream'),
        ),
        TextButton(
          onPressed: () async {
            final saving = ack.then((_) => wake.answerDream(epoch, DreamAnswer.normal));
            Navigator.of(c).pop();
            await saving;
          },
          child: Text(l?.wakeDreamNormally ?? 'Normally'),
        ),
        TextButton(
          onPressed: () => Navigator.of(c).pop(),
          child: Text(l?.wakeDreamSkip ?? 'Skip'),
        ),
      ],
    ),
  );
  await ack;
}
