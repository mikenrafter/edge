// The one provenance seam for the wake dev harness: both evaluators (the
// Natural orchestrator and the legacy evaluator in AppState) record their
// effective snapshot here BEFORE they decide. See wake_harness.dart.
import 'dart:convert';

import 'wake_orchestrator.dart' show WakeTraceEntry, WakeTraceStore;

/// Durable storage behind [WakeHarnessRecorder]: its small per-occurrence
/// state, and an idempotent append of a `harness` trace row.
abstract interface class WakeHarnessLedger {
  Future<Map<String, Object?>?> loadState();
  Future<void> saveState(Map<String, Object?> state);

  /// True only when the row is confirmed present afterwards (already there,
  /// or appended now). Identity: occurrence + kind + data (never the time).
  Future<bool> appendOnce(WakeTraceEntry entry);
}

/// In-memory state over any trace store (tests, and an orchestrator built
/// without a ledger).
class MemoryWakeHarnessLedger implements WakeHarnessLedger {
  MemoryWakeHarnessLedger(this.trace);
  final WakeTraceStore trace;
  Map<String, Object?>? state;

  @override
  Future<Map<String, Object?>?> loadState() async => state;

  @override
  Future<void> saveState(Map<String, Object?> s) async => state = s;

  @override
  Future<bool> appendOnce(WakeTraceEntry entry) async {
    try {
      final data = jsonEncode(entry.data);
      for (final e in await trace.forWake(entry.wakeEpochSec)) {
        if (e.kind == entry.kind && jsonEncode(e.data) == data) return true;
      }
      await trace.append(entry);
      return true;
    } catch (_) {
      return false;
    }
  }
}

class WakeHarnessRecorder {
  WakeHarnessRecorder(this.ledger, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final WakeHarnessLedger ledger;
  final DateTime Function() _now;

  /// Record [record] (a `WakeHarnessConfig.provenance` map) for occurrence
  /// [epoch]. [untouched]: the stored config is the default.
  Future<void> record(
    int epoch,
    Map<String, Object?> record, {
    required bool untouched,
  }) async {}
}
