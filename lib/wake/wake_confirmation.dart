// Turns observed wake events into the persisted confirmation that makes a
// sleep block final (see lib/compute/sleep_block_policy.dart). One recorder for
// every call site: the foreground hook, the band-movement check, and the alarm
// paths (fired, acknowledged, Natural Wake fired), foreground or headless.

import 'dart:async';

import '../compute/sleep_block_policy.dart';

enum WakeEvidenceKind {
  appOpened,
  bandMovement,
  alarmFired,
  alarmAcknowledged,
  naturalWake,
}

typedef WakeEvidenceEvent = ({WakeEvidenceKind kind, int sec});

/// Persistence the recorder works against, so evidence survives a restart (an
/// alarm that fired while the app was dead still counts when it is opened).
abstract interface class WakeConfirmationStore {
  /// Onset (epoch seconds) of the sleep block in progress or just ended; null
  /// when no block is known (nothing to confirm).
  Future<int?> sleepOnsetSec();

  /// The block's confirmed wake, or null while it is open.
  Future<int?> confirmedWakeSec();

  /// Every event noted for the block so far.
  Future<List<WakeEvidenceEvent>> evidence();

  Future<void> addEvidence(WakeEvidenceKind kind, int sec);

  /// Marks the block final at [sec]; [basis] is the evidence that completed it.
  Future<void> confirmWake(int sec, {required WakeEvidenceKind basis});
}

class WakeConfirmationRecorder {
  WakeConfirmationRecorder(this.store);

  final WakeConfirmationStore store;

  // Notes from one isolate run one at a time: two overlapping calls would both
  // read "not confirmed yet" and both write (check-then-record). Across
  // isolates the store's first-write-wins is the guard.
  Future<void> _tail = Future<void>.value();

  /// Notes one observed event at [at]. Returns the confirmed moment when this
  /// event completed the double confirmation (and saved it), else null.
  Future<int?> note(WakeEvidenceKind kind, DateTime at) {
    final run = _tail.then((_) => _note(kind, at.millisecondsSinceEpoch ~/ 1000));
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<int?> _note(WakeEvidenceKind kind, int sec) async {
    final onset = await store.sleepOnsetSec();
    if (onset == null || sec < onset) return null;
    if (await store.confirmedWakeSec() != null) return null;
    await store.addEvidence(kind, sec);
    final events = await store.evidence();
    List<int> of(bool Function(WakeEvidenceKind) test) =>
        [for (final e in events) if (test(e.kind)) e.sec];
    final opens = of((k) => k == WakeEvidenceKind.appOpened);
    final moment = confirmedWakeSec(
      onsetSec: onset,
      appOpenedSec: opens,
      bandMovementSec: of((k) => k == WakeEvidenceKind.bandMovement),
      alarmSec: of(_isAlarm),
    );
    if (moment == null) return null;
    // The evidence that completed it: the non-open kind that, with the opens,
    // reaches exactly that moment.
    var basis = WakeEvidenceKind.bandMovement;
    for (final k in WakeEvidenceKind.values) {
      if (k == WakeEvidenceKind.appOpened) continue;
      final alone = confirmedWakeSec(
        onsetSec: onset,
        appOpenedSec: opens,
        bandMovementSec: k == WakeEvidenceKind.bandMovement
            ? of((e) => e == k)
            : const [],
        alarmSec: _isAlarm(k) ? of((e) => e == k) : const [],
      );
      if (alone == moment) {
        basis = k;
        break;
      }
    }
    await store.confirmWake(moment, basis: basis);
    return moment;
  }

  static bool _isAlarm(WakeEvidenceKind k) =>
      k == WakeEvidenceKind.alarmFired ||
      k == WakeEvidenceKind.alarmAcknowledged ||
      k == WakeEvidenceKind.naturalWake;
}
