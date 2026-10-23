// ImportReentryStore: the ONE owner of "what the user still has to enter again
// after an import".
//
// Owned state: for each import RUN, the items still PENDING and the items the
// user has ACKNOWLEDGED (dismissed). Everything is keyed by (runId, itemId): an
// acknowledgement only ever suppresses the same item of the same run. There is
// no reset step and no exception to it. A resume of a run reads the same
// journal row and so records under the same runId (its dismissal stands); a
// fresh backup, including one that replaces an unfinished journal, is a new
// run (its own warnings are never hidden by an old ack).
//
// runId comes from the import journal (see [reentryRunIdOf]); nothing new is
// stored there. A multi-select import is one journaled run per backup file.
//
// All runs live together in ONE preference, `import_reentry_pending`, so any
// operation, a dismissal included, is a single write and no crash can leave
// the sets disagreeing. The value is JSON {"v":2,"runs":[{"id","p","a"}]}.
// Older values ("pending" or "pending;acknowledged") are read as one run of
// UNKNOWN identity: their pending items stay visible, and their acks match no
// run, since it cannot be told which import they were for.
//
// Every operation runs through one queue and re-reads the preference first, so
// the in-memory mirror ([pending]) can never overwrite what is stored. Callers
// never read-modify-write. A write the platform refuses is retried once, then
// thrown, never dropped. Device-only state (kPrefsNotBackedUp in
// backup_extras.dart).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The identity of one journaled import run: its journal row id (AUTOINCREMENT,
/// never reused) with its start time. A resume reads the same row and so gets
/// the same value; a backup that replaces the journal gets a new one.
String reentryRunIdOf(int journalId, int startedAt) => '$startedAt-$journalId';

class _Run {
  _Run(this.id, this.pending, this.acked);
  final String id;
  final List<String> pending;
  final List<String> acked;
}

class ImportReentryStore {
  ImportReentryStore();

  static ImportReentryStore? _current;

  /// The store the running app uses; the data layer reaches it from here
  /// because the import code has no AppState in hand.
  static ImportReentryStore get current => _current ??= ImportReentryStore();
  static set current(ImportReentryStore s) => _current = s;

  /// A mirror of the stored pending items (all runs, each once), for screens.
  /// Only this class writes it.
  final ValueNotifier<List<String>> pending = ValueNotifier(const []);

  // Null until the first operation: a future built in the constructor would
  // belong to whatever zone built the store.
  Future<void>? _tail;

  /// Waits for every earlier operation, then returns the lock to release (in a
  /// finally) with complete(). One at a time, in call order.
  Future<Completer<void>> _acquire() async {
    final prev = _tail;
    final mine = Completer<void>();
    _tail = mine.future;
    if (prev != null) await prev;
    return mine;
  }

  static const String _key = 'import_reentry_pending';

  /// The run an older-format value is read as.
  static const String _unknownRun = '?';

  /// Runs kept once they have nothing pending: enough that a resume of a
  /// recent run still finds its acknowledgements.
  static const int _keepRuns = 6;

  /// Every preference this store owns; each must be listed in
  /// kPrefsNotBackedUp (a restore must not carry them to another install).
  static const List<String> prefKeys = [_key];

  // A multi-select import is one batch: its backups share the run identity of
  // the first one that records, so a dismissal made between two of them holds
  // for the rest. Only while a batch is open; a resume of an interrupted file
  // later has just its own journal identity (the batch id is not journaled).
  int _batchDepth = 0;
  String? _batchRunId;

  /// Runs [body] as one batch: every [add] inside shares one run identity.
  Future<T> batch<T>(Future<T> Function() body) async {
    _batchDepth++;
    try {
      return await body();
    } finally {
      if (--_batchDepth == 0) _batchRunId = null;
    }
  }

  Future<List<_Run>> _read() async {
    final prefs = await SharedPreferences.getInstance();
    // The plugin updates its cache BEFORE the platform confirms a write, so a
    // refused write leaves the cache ahead of the disk. Disk is the truth.
    await prefs.reload();
    final raw = prefs.getString(_key) ?? '';
    if (raw.isEmpty) return [];
    List<String> ids(Object? v) =>
        v is List ? [for (final x in v) if (x is String && x.isNotEmpty) x] : [];
    if (raw.startsWith('{')) {
      try {
        final j = jsonDecode(raw);
        final runs = j is Map ? j['runs'] : null;
        if (runs is List) {
          return [
            for (final r in runs)
              if (r is Map && r['id'] is String)
                _Run(r['id'] as String, ids(r['p']), ids(r['a'])),
          ];
        }
      } catch (_) {}
      return [];
    }
    // Older format: "pending" or "pending;acknowledged". The acks are dropped:
    // they belong to no run this build can name.
    final pend = ids(raw.split(';').first.split(','));
    return pend.isEmpty ? [] : [_Run(_unknownRun, pend, [])];
  }

  List<String> _pendingOf(List<_Run> runs) =>
      [for (final id in {for (final r in runs) ...r.pending}) id];

  /// All runs in one write; retried once; throws if the platform refuses.
  Future<void> _write(List<_Run> runs) async {
    // Bounded: a run with nothing pending is only worth keeping for its acks.
    while (runs.length > _keepRuns) {
      final i = runs.indexWhere((r) => r.pending.isEmpty);
      if (i < 0) break;
      runs.removeAt(i);
    }
    final live = [for (final r in runs) if (r.pending.isNotEmpty || r.acked.isNotEmpty) r];
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final ok = live.isEmpty
            ? await prefs.remove(_key)
            : await prefs.setString(
                _key,
                jsonEncode({
                  'v': 2,
                  'runs': [
                    for (final r in live) {'id': r.id, 'p': r.pending, 'a': r.acked},
                  ],
                }));
        if (ok) {
          pending.value = List.unmodifiable(_pendingOf(live));
          return;
        }
      } catch (_) {}
      // Refused: drop the cache's optimistic value before trying again or
      // giving up, so no later decision is made on a write that never landed.
      try {
        await (await SharedPreferences.getInstance()).reload();
      } catch (_) {}
    }
    throw StateError('Could not save the note about what to enter again.');
  }

  /// Reads the stored items into the mirror.
  Future<void> load() async {
    final lock = await _acquire();
    try {
      pending.value = List.unmodifiable(_pendingOf(await _read()));
    } finally {
      lock.complete();
    }
  }

  /// Records [ids] as pending for the import run [runId], unless the user has
  /// already acknowledged that item of that same run. Writes only when
  /// something is new.
  Future<void> add(Iterable<String> ids, {required String runId}) async {
    // Nothing to add touches nothing (no preferences read, no lock).
    if (ids.isEmpty) return;
    if (_batchDepth > 0) runId = _batchRunId ??= runId;
    final lock = await _acquire();
    try {
      final runs = await _read();
      var run = runs.where((r) => r.id == runId).firstOrNull;
      final fresh = [
        for (final id in ids)
          if (!(run?.acked.contains(id) ?? false) &&
              !(run?.pending.contains(id) ?? false))
            id
      ];
      if (fresh.isEmpty) {
        pending.value = List.unmodifiable(_pendingOf(runs));
        return;
      }
      if (run == null) {
        run = _Run(runId, [], []);
        runs.add(run);
      }
      run.pending.addAll(fresh);
      await _write(runs);
    } finally {
      lock.complete();
    }
  }

  /// Acknowledges [ids] (no ids: everything pending now) in every run that has
  /// them pending. One write. The mirror drops them at once and is put back if
  /// the write fails, so it never claims a dismissal that did not happen.
  Future<void> dismiss([Iterable<String>? ids]) async {
    final which = {...(ids ?? pending.value)};
    final before = pending.value;
    pending.value = List.unmodifiable(
        [for (final x in before) if (!which.contains(x)) x]);
    final lock = await _acquire();
    try {
      final runs = await _read();
      for (final r in runs) {
        final hit = [for (final x in r.pending) if (which.contains(x)) x];
        r.pending.removeWhere(which.contains);
        r.acked.addAll([for (final x in hit) if (!r.acked.contains(x)) x]);
      }
      await _write(runs);
    } catch (_) {
      pending.value = before;
      rethrow;
    } finally {
      lock.complete();
    }
  }
}
