part of '../app_state.dart';

// AppState owns the lane's lifetime. This part runs its durable night/nap
// receipts and publishes only the revision that actually completed.
extension _AppSleepEdits on AppState {
  Future<void> _runSleepEdit(SleepEditJob job) async {
    final day = job.day;
    if ((await SleepEditStore.status(day))?['revision'] != job.revision) return;
    try {
      await _waitForDerivation(limit:sleepEditWaitLimit);
      if(job.mainPending) {
        await _deriveSleepDay(job);
      } else if(!await _derive.refreshNapEdits(_profile,day,job.napRevision)) {
        throw const SleepEditRequeue('nap rollup did not complete');
      }
    } on SyncFailureError catch (e) {
      // Waiting out a long pass is not a fault of the edit.
      if (e.code == SyncFailure.calculationStuck) {
        throw const SleepEditRequeue(
            'another calculation is still running', counts: false);
      }
      rethrow;
    }
    final status = await SleepEditStore.status(day);
    if (status?['revision'] != job.revision) return; // a newer edit owns it
    if (status?['nap_revision'] != job.napRevision) return;
    if (status?['applied_revision'] != job.revision || status?['nap_applied_revision'] != job.napRevision) {
      final fence = _sleepEditPassFence;
      if (fence != null && await SleepEditStore.generation(upTo: day) != fence) {
        throw const SleepEditRequeue('an earlier night was edited meanwhile');
      }
      throw StateError('Sleep calculation is incomplete. Your times are saved. Retry.');
    }
    if (await SleepEditStore.advance(job, SleepEditPhase.done) == SleepEditAdvance.applied) {
      await _deriveCoordinator.publishNow();
    }
  }

  Future<Map<String, Object?>> _deriveSleepDay(SleepEditJob job) async {
    final day = job.day;
    // A pass that was already running prepared the edited day from the old
    // window and re-pins that night's readiness when it lands, after the
    // edit's own release. Release again once it is done, right before this
    // derive takes over (no await between the last check and the latch).
    do {
      await _waitForDerivation(limit: sleepEditWaitLimit);
      if (_disposed) throw StateError('Sleep worker closed');
      if ((await SleepEditStore.status(day))?['revision'] != job.revision) return {};
      await LocalDb.releaseFrozenHeadline(day);
    } while (_derive.running || reanalyzing);
    _sleepEditPassFence = await SleepEditStore.generation(upTo: day);
    reanalyzing = true;
    final recalcOwner = _deriveCoordinator.beginSleepEdit(day);
    notifyListeners();
    try {
      // The edited night, then the later nights scored against it.
      final outcome = await _derive.rederiveAfterSleepEdit(_profile, day, publication: _AppSleepEditPublication(this, job));
      if (outcome == SleepEditCalculation.superseded) return {};
      if (outcome == SleepEditCalculation.incomplete) {
        final fence = _sleepEditPassFence;
        if (fence != null && await SleepEditStore.generation(upTo: day) != fence) {
          throw const SleepEditRequeue('an earlier night was edited meanwhile');
        }
        throw StateError('Sleep calculation is incomplete. Your times are saved. Retry.');
      }
      final error = _derive.snapshot()['last_error'];
      if (error != null) throw StateError('$error');
      // A finalized day behind the export cursor is never re-written, so the
      // corrected (or rejected) night would never reach the health store. Not
      // awaited: the rewind waits out any export already running.
      unawaited(HealthExporter.reexportFrom(day).then((_) {
        if (healthSyncEnabled) unawaited(_runHealthExport());
      }).catchError((Object e) {
        _log('[health] re-export after a sleep edit failed: $e');
      }));
      await _deriveCoordinator.publishNow();
      return await repo?.getDaySleep(day) ?? <String, Object?>{};
    } finally { _deriveCoordinator.endSleepEdit(recalcOwner); reanalyzing = false; notifyListeners(); }
  }

}

final class _AppSleepEditEffects implements SleepEditEffects {
  const _AppSleepEditEffects(this.app);
  final AppState app;
  @override Future<void> run(SleepEditJob job) => app._runSleepEdit(job);
  @override Future<void> publish() => app._deriveCoordinator.publishNow();
  @override void hold(bool held) => app._deriveScheduler.setSleepEditHeld(held);
  @override void report(Object error) => app._log('[sleep edit] $error');
}

final class _AppSleepEditPublication implements SleepEditPublication {
  const _AppSleepEditPublication(this.app, this.job);
  final AppState app;
  final SleepEditJob job;
  @override Future<bool> publish() async {
    if (await SleepEditStore.advance(job, SleepEditPhase.dependents) != SleepEditAdvance.applied) return false;
    await app._deriveCoordinator.publishNow();
    return true;
  }
}
