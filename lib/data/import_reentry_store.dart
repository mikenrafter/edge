// ImportReentryStore: the ONE owner of "what the user still has to enter again
// after an import".
//
// Owned state: two sets, PENDING (not yet acknowledged) and ACKNOWLEDGED (the
// user dismissed it; stays dismissed until the next user-started import). They
// live together in one preference, `import_reentry_pending`, written in a
// single call so no crash can leave them disagreeing. The value is
// "pending;acknowledged", each a comma-joined list; a value without ';' is the
// older pending-only form.
//
// Every operation runs through one queue and re-reads the preference first, so
// the in-memory mirror ([pending]) can never overwrite what is stored. Callers
// never read-modify-write: they add, dismiss, begin a fresh import, or load.
// A write that the platform refuses is retried once, then thrown, never
// dropped. Device-only state (kPrefsNotBackedUp in backup_extras.dart).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'import_journal.dart';

class ImportReentryStore {
  ImportReentryStore();

  static ImportReentryStore? _current;

  /// The store the running app uses; the data layer reaches it from here
  /// because the import code has no AppState in hand.
  static ImportReentryStore get current => _current ??= ImportReentryStore();
  static set current(ImportReentryStore s) => _current = s;

  /// A mirror of the stored pending set, for screens. Only this class writes it.
  final ValueNotifier<List<String>> pending = ValueNotifier(const []);

  // Null until the first operation: a future built in the constructor would
  // belong to whatever zone built the store.
  Future<void>? _tail;
  bool _resetFailedForCurrentImport = false;

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

  Future<(List<String>, List<String>)> _read() async {
    final prefs = await SharedPreferences.getInstance();
    // The plugin updates its cache BEFORE the platform confirms a write, so a
    // refused write leaves the cache ahead of the disk. Disk is the truth.
    await prefs.reload();
    final raw = prefs.getString(_key) ?? '';
    final parts = raw.split(';');
    List<String> ids(String s) => [for (final x in s.split(',')) if (x.isNotEmpty) x];
    return (ids(parts[0]), parts.length > 1 ? ids(parts[1]) : <String>[]);
  }

  /// Both sets in one write; retried once; throws if the platform refuses.
  Future<void> _write(List<String> pend, List<String> acked) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final ok = pend.isEmpty && acked.isEmpty
            ? await prefs.remove(_key)
            : await prefs.setString(_key, '${pend.join(',')};${acked.join(',')}');
        if (ok) {
          pending.value = List.unmodifiable(pend);
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

  /// Reads the stored sets into the mirror.
  Future<void> load() async {
    final lock = await _acquire();
    try {
      pending.value = List.unmodifiable((await _read()).$1);
    } finally {
      lock.complete();
    }
  }

  /// pending ∪= ids − acknowledged. Writes only when something is new.
  Future<void> add(Iterable<String> ids) async {
    // Nothing to add touches nothing (no preferences read, no lock).
    if (ids.isEmpty) return;
    final lock = await _acquire();
    try {
      final (pend, acked) = await _read();
      final fresh = [
        for (final id in ids)
          if ((_resetFailedForCurrentImport || !acked.contains(id)) && !pend.contains(id)) id
      ];
      if (fresh.isEmpty) {
        pending.value = List.unmodifiable(pend);
        return;
      }
      await _write([...pend, ...fresh], acked);
    } finally {
      lock.complete();
    }
  }

  /// acknowledged ∪= ids; pending −= ids. No ids means everything pending now.
  /// The mirror drops them at once; the write follows in order.
  Future<void> dismiss([Iterable<String>? ids]) async {
    final which = [...(ids ?? pending.value)];
    pending.value = List.unmodifiable(
        [for (final x in pending.value) if (!which.contains(x)) x]);
    final lock = await _acquire();
    try {
      final (pend, acked) = await _read();
      await _write([for (final x in pend) if (!which.contains(x)) x],
          {...acked, ...which}.toList());
    } finally {
      lock.complete();
    }
  }

  /// A user-started import begins: earlier acknowledgements no longer apply,
  /// so a new import that loses the same item shows it again (the destination
  /// has no such item, or it would not have been lost). Never called for a
  /// resume. Skipped while an OLDER import is still unfinished: when that one
  /// resumes it will record the same item, and the dismissal still stands for
  /// it. (Limit: a journal nobody finishes keeps its acknowledgements.)
  Future<void> beginFreshImport() async {
    final lock = await _acquire();
    try {
      final (pend, acked) = await _read();
      if (acked.isEmpty) return;
      if (await _olderImportUnfinished()) return;
      await _write(pend, const []);
      _resetFailedForCurrentImport = false;
    } catch (_) {
      _resetFailedForCurrentImport = true;
      rethrow;
    } finally {
      lock.complete();
    }
  }

  /// True when the latest journaled import has not finished, or when that
  /// cannot be told (then the acknowledgements are kept, not dropped).
  Future<bool> _olderImportUnfinished() async {
    try {
      final st = await ImportJournal.current();
      return st != null && st.state != ImportJournalState.done;
    } catch (_) {
      return true;
    }
  }
}
