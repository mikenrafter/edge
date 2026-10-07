// wake_outcome_recorder.dart — the shadow-mode wiring behind AppState: when a
// wake closes (or the app comes back after one), assemble that wake's
// WakeOutcome and keep it in the outcome store. Everything outside is injected,
// so the gate, the idempotence and the catch-up rule are tested without BLE or
// a database.
//
// SHADOW ONLY. Nothing here is handed to the orchestrator, the plan or an
// alarm. Every entry point is a no-op unless [enabled] says so (developer mode
// AND the explore flag), and none of them throws: a failure here must not touch
// the alarm, the wake tick or the touch that triggered it.

import 'dart:async';

import '../wake_orchestrator.dart' show WakeTraceEntry;
import 'wake_outcome.dart';
import 'wake_outcome_assembler.dart';
import 'wake_outcome_store.dart';

/// The foreground catch-up looks at a wake at least this long ago (the closed
/// tick already covered the recent ones) ...
const Duration kOutcomeCatchUpMinAge = Duration(hours: 2);

/// ... and at most this long ago: the wake-evidence store only follows the
/// newest sleep block, which is a night's block for about this long.
const Duration kOutcomeCatchUpMaxAge = Duration(hours: 12);

/// A delivered, unrated outcome is asked about for this long after the wake.
const Duration kGrogginessPromptMaxAge = Duration(hours: 12);

/// App opens and band movement noted for a wake, epoch seconds. Empty means
/// none were seen, which the assembler reports as "not seen", never 0.
typedef WakeEvidenceSecs = ({List<int> appOpened, List<int> movement});

class WakeOutcomeRecorder {
  WakeOutcomeRecorder({
    required this.enabled,
    required this.store,
    required this.traceFor,
    required this.recentTrace,
    required this.evidenceFor,
    this.touchSecs,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Developer mode AND `Prefs.exploreWakeOutcomesOn`, read at every call.
  final bool Function() enabled;
  final WakeOutcomeStore store;

  /// One wake's trace rows (DbWakeTraceStore.forWake).
  final Future<List<WakeTraceEntry>> Function(int wakeSec) traceFor;

  /// The newest trace rows across wakes (DbWakeTraceStore.recent).
  final Future<List<WakeTraceEntry>> Function() recentTrace;

  /// The persisted app-open and band-movement evidence for a wake.
  final Future<WakeEvidenceSecs> Function(int wakeSec) evidenceFor;

  /// Foreground touches still in memory (epoch seconds), or null.
  final List<int> Function()? touchSecs;

  final DateTime Function() _now;

  // Every store read-modify-write goes through this one chain: an upsert that
  // overlaps a rating would otherwise write back a list without it.
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() body) {
    final run = _tail.then((_) => body());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  int get _nowSec => _now().millisecondsSinceEpoch ~/ 1000;

  /// Assembles the outcome of the wake at [wakeSec] and stores it, replacing an
  /// earlier one for the same wake but keeping its grogginess rating. Null when
  /// gated off, when the trace has neither a fire nor a close for it, or on any
  /// failure.
  Future<WakeOutcome?> record(int wakeSec) async {
    if (!enabled()) return null;
    try {
      final trace = [
        for (final row in await traceFor(wakeSec))
          if (row.wakeEpochSec == wakeSec) row,
      ];
      // No fire and no close: the app was not running around T, so what
      // reached the band is unknown. No outcome beats a "nothing fired" one.
      final knowable = trace.any((row) =>
          row.kind == 'closed' ||
          row.kind == 'gradual' && row.data['result'] == 'sent' ||
          (row.kind == 'natural_haptic' || row.kind == 'natural_repeat') &&
              row.data['phase'] == 'result' &&
              row.data['result'] == 'sent');
      if (!knowable) return null;
      final evidence = await evidenceFor(wakeSec);
      return await _serial(() async {
        final existing = (await store.load())
            .where((o) => o.wakeSec == wakeSec)
            .firstOrNull;
        final outcome = assemble(
          wakeSec: wakeSec,
          trace: trace,
          appInteractionSecs: [
            ...evidence.appOpened,
            ...?touchSecs?.call(),
          ],
          movementSecs: evidence.movement,
          grogginess: existing?.grogginess,
        );
        await store.upsert(outcome);
        return outcome;
      });
    } catch (_) {
      return null;
    }
  }

  /// The foreground catch-up (the app may have been dead at T): the newest wake
  /// in the trace that is 2..12 hours old, assembled again with whatever has
  /// been seen since. Same outcome as the closed tick would have made, only
  /// fuller, and the rating survives.
  Future<WakeOutcome?> catchUp() async {
    if (!enabled()) return null;
    try {
      final now = _nowSec;
      final newest = now - kOutcomeCatchUpMinAge.inSeconds;
      final oldest = now - kOutcomeCatchUpMaxAge.inSeconds;
      int? wakeSec;
      for (final row in await recentTrace()) {
        final t = row.wakeEpochSec;
        if (t > newest || t <= oldest) continue;
        if (wakeSec == null || t > wakeSec) wakeSec = t;
      }
      return wakeSec == null ? null : await record(wakeSec);
    } catch (_) {
      return null;
    }
  }

  /// The newest delivered outcome with no rating, if it is under 12 hours old.
  /// Null when gated off, when the newest delivered one is rated (an older
  /// unrated morning is not asked about), or when nothing qualifies.
  Future<WakeOutcome?> pendingRating() async {
    if (!enabled()) return null;
    try {
      final newest =
          (await store.load()).where((o) => o.delivered).firstOrNull;
      if (newest == null || newest.grogginess != null) return null;
      final age = _nowSec - newest.wakeSec;
      return age <= kGrogginessPromptMaxAge.inSeconds ? newest : null;
    } catch (_) {
      return null;
    }
  }

  /// Stores a rating (1..5) on [wakeSec]. Gated off, an out-of-range value or
  /// a storage failure writes nothing and returns false.
  Future<bool> rate(int wakeSec, int grogginess) async {
    if (!enabled()) return false;
    try {
      await _serial(() => store.rate(wakeSec, grogginess));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The stored log, newest first; empty when gated off.
  Future<List<WakeOutcome>> outcomes() async {
    if (!enabled()) return const [];
    return _serial(store.load);
  }
}
