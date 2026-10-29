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

/// Per occurrence: the last acknowledged digest, the next activation number,
/// and at most one PENDING activation (written to the ledger state before its
/// append, so a retry after a failure, a timeout or a restart re-sends the
/// same row: same seq, same time, same data). A digest is acknowledged only
/// after the append is confirmed.
class WakeHarnessRecorder {
  WakeHarnessRecorder(this.ledger);
  final WakeHarnessLedger ledger;
  Future<void> _chain = Future.value();

  /// Record [record] (a `WakeHarnessConfig.provenance` map) for occurrence
  /// [epoch] at [atMs]. [untouched]: the stored config is the default; an
  /// occurrence that has only ever been untouched writes nothing. Never
  /// throws.
  Future<void> record(
    int epoch,
    Map<String, Object?> record, {
    required bool untouched,
    required int atMs,
  }) {
    final run = _chain.then((_) => _record(epoch, record, untouched, atMs));
    _chain = run.catchError((Object _) {});
    return _chain;
  }

  Future<void> _record(
    int epoch,
    Map<String, Object?> record,
    bool untouched,
    int atMs,
  ) async {
    final loaded = await ledger.loadState();
    final st = loaded != null && loaded['epoch'] == epoch
        ? Map<String, Object?>.of(loaded)
        : <String, Object?>{'epoch': epoch, 'seq': 0};
    final seq0 = st['seq'];
    var seq = seq0 is int && seq0 >= 0 ? seq0 : 0;
    // A pending activation goes out first, exactly as it was.
    final pending = st['pending'];
    if (pending is Map) {
      final ok = await ledger.appendOnce(_entry(epoch, pending));
      if (!ok) return; // retried next time, still pending
      st['acked'] = pending['digest'];
      seq = ((pending['data'] as Map)['seq'] as int) + 1;
      st['seq'] = seq;
      st.remove('pending');
      await ledger.saveState(st);
    }
    final digest = record['digest'];
    if (st['acked'] == null && untouched) return;
    if (digest == st['acked']) return;
    final next = <String, Object?>{
      'digest': digest,
      'atMs': atMs,
      'data': {...record, 'seq': seq},
    };
    st['pending'] = next;
    await ledger.saveState(st);
    if (!await ledger.appendOnce(_entry(epoch, next))) return;
    st['acked'] = digest;
    st['seq'] = seq + 1;
    st.remove('pending');
    await ledger.saveState(st);
  }

  static WakeTraceEntry _entry(int epoch, Map<dynamic, dynamic> p) =>
      WakeTraceEntry(
        wakeEpochSec: epoch,
        atMs: p['atMs'] as int,
        kind: 'harness',
        data: (p['data'] as Map).cast<String, Object?>(),
      );
}
