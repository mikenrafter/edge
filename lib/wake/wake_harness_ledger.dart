// The one provenance seam for the wake dev harness: both evaluators (the
// Natural orchestrator and the legacy evaluator in AppState) record their
// effective snapshot here BEFORE they decide. See wake_harness.dart.
import 'dart:convert';

import 'wake_orchestrator.dart' show WakeTraceEntry, WakeTraceStore;

/// Durable storage behind [WakeHarnessRecorder]: its small per-occurrence
/// state, and an idempotent append of a `harness` trace row.
abstract interface class WakeHarnessLedger {
  /// Null only when there is genuinely no bookkeeping (fresh install, after a
  /// restore). A read that fails THROWS, so the caller retries later rather
  /// than mistaking it for "nothing recorded yet".
  Future<Map<String, Object?>?> loadState();
  Future<void> saveState(Map<String, Object?> state);

  /// The occurrence's durable `harness` rows (to recover bookkeeping).
  Future<List<WakeTraceEntry>> harnessRows(int epoch);

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
  Future<List<WakeTraceEntry>> harnessRows(int epoch) async => [
    for (final e in await trace.forWake(epoch))
      if (e.kind == 'harness') e,
  ];

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

/// Bookkeeping (one durable blob): per occurrence the last ENQUEUED digest
/// and the next activation number, and a FIFO queue of activations not yet
/// confirmed in the trace. Each transition is enqueued durably before any
/// retry, so a failing append never drops a later configuration (A fails, B,
/// A keeps B), and queued entries keep their own occurrence, seq and time
/// across occurrence changes. Missing bookkeeping is recovered from the
/// occurrence's durable rows; a failed read is retried, never reset.
class WakeHarnessRecorder {
  WakeHarnessRecorder(this.ledger);
  final WakeHarnessLedger ledger;
  Future<void> _chain = Future.value();

  /// Record [record] (a `WakeHarnessConfig.provenance` map) for occurrence
  /// [epoch] at [atMs]. [untouched]: the stored config is the default; an
  /// occurrence that has only ever been untouched writes nothing. Never
  /// throws (a failure leaves everything for the next call).
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
    final loaded = await ledger.loadState(); // a failed read propagates
    final occ = <String, Object?>{};
    final queue = <Map<String, Object?>>[];
    if (loaded != null) {
      final o = loaded['occ'];
      if (o is Map) occ.addAll(o.cast<String, Object?>());
      final q = loaded['queue'];
      if (q is List) {
        for (final e in q) {
          if (e is Map) queue.add(e.cast<String, Object?>());
        }
      }
    }
    final key = '$epoch';
    var mine = occ[key] is Map ? (occ[key] as Map).cast<String, Object?>() : null;
    mine ??= await _recover(epoch);
    final last = mine['last'];
    final digest = record['digest'];
    var changed = false;
    if (!(last == null && untouched) && digest != last) {
      final seq = mine['seq'] as int;
      queue.add({
        'epoch': epoch,
        'atMs': atMs,
        'data': {...record, 'seq': seq},
      });
      mine = {'last': digest, 'seq': seq + 1};
      changed = true;
    }
    if (occ[key] == null || changed) {
      occ[key] = mine;
      changed = true;
    }
    // Keep bookkeeping for the latest occurrences and any still queued.
    final queued = {for (final e in queue) '${e['epoch']}'};
    occ.removeWhere(
      (k, _) => !queued.contains(k) && (int.tryParse(k) ?? 0) < epoch - 3 * 86400,
    );
    if (changed) await ledger.saveState({'occ': occ, 'queue': queue});
    if (queue.isEmpty) return;
    var sent = 0;
    for (final e in queue) {
      if (!await ledger.appendOnce(_entry(e))) break;
      sent++;
    }
    if (sent == 0) return;
    await ledger.saveState({'occ': occ, 'queue': queue.sublist(sent)});
  }

  /// No bookkeeping for [epoch]: resume after its highest durable seq.
  Future<Map<String, Object?>> _recover(int epoch) async {
    Object? last;
    var next = 0;
    for (final e in await ledger.harnessRows(epoch)) {
      final seq = e.data['seq'];
      if (seq is int && seq >= next) {
        next = seq + 1;
        last = e.data['digest'];
      }
    }
    return {'last': last, 'seq': next};
  }

  static WakeTraceEntry _entry(Map<String, Object?> e) => WakeTraceEntry(
    wakeEpochSec: e['epoch'] as int,
    atMs: e['atMs'] as int,
    kind: 'harness',
    data: (e['data'] as Map).cast<String, Object?>(),
  );
}
