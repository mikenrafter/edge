// WHY / CLAIM(alert-handoff): debug assertions cannot prove release refusal.
// Run with stock `dart run`, whose assertions are disabled by default.
import 'dart:io';

import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

Future<void> main() async {
  var assertions = false;
  assert(assertions = true);
  if (assertions) throw StateError('Run this probe without assertions');
  final logs = <String>[];
  var writes = 0;
  final queue = BandHapticQueue(ledger: BandCommandLedger(), log: logs.add);
  Future<BuzzDelivery> job(BandJobToken _) async {
    writes++;
    return BuzzDelivery.complete;
  }
  final result = await queue.run(job, commands: 1,
      timeout: const Duration(seconds: 1), settle: Duration.zero);
  if (result != BuzzDelivery.rejected || writes != 0 || queue.pending != 0 ||
      !logs.any((line) => line.contains('missing alert handoff'))) {
    throw StateError('Unowned release job was not refused and logged: $result $logs');
  }
  final lab = await queue.run(job, commands: 1, lab: true,
      timeout: const Duration(seconds: 1), settle: Duration.zero);
  if (lab != BuzzDelivery.complete || writes != 1) {
    throw StateError('Lab positive control did not run');
  }
  stdout.writeln('RELEASE_HANDOFF_RESULT PASS');
}
