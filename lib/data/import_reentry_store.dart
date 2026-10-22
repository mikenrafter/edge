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

class ImportReentryStore {
  ImportReentryStore();

  static ImportReentryStore? _current;

  /// The store the running app uses; the data layer reaches it from here
  /// because the import code has no AppState in hand.
  static ImportReentryStore get current => _current ??= ImportReentryStore();
  static set current(ImportReentryStore s) => _current = s;

  /// A mirror of the stored pending set, for screens. Only this class writes it.
  final ValueNotifier<List<String>> pending = ValueNotifier(const []);

  Future<void> _tail = Future.value();

  Future<T> _queued<T>(Future<T> Function() op) {
    final done = _tail.then((_) => op());
    _tail = done.then<void>((_) {}, onError: (_) {});
    return done;
  }

  static const String _key = 'import_reentry_pending';

  Future<(List<String>, List<String>)> _read() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key) ?? '';
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
    }
    throw StateError('Could not save the note about what to enter again.');
  }

  /// Reads the stored sets into the mirror.
  Future<void> load() => _queued(() async {
        pending.value = List.unmodifiable((await _read()).$1);
      });

  /// pending ∪= ids − acknowledged. Writes only when something is new.
  Future<void> add(Iterable<String> ids) => _queued(() async {
        final (pend, acked) = await _read();
        final fresh = [
          for (final id in ids)
            if (!acked.contains(id) && !pend.contains(id)) id
        ];
        if (fresh.isEmpty) {
          pending.value = List.unmodifiable(pend);
          return;
        }
        await _write([...pend, ...fresh], acked);
      });

  /// acknowledged ∪= ids; pending −= ids. No ids means everything pending now.
  /// The mirror drops them at once; the write follows in order.
  Future<void> dismiss([Iterable<String>? ids]) {
    final which = [...(ids ?? pending.value)];
    pending.value = List.unmodifiable(
        [for (final x in pending.value) if (!which.contains(x)) x]);
    return _queued(() async {
      final (pend, acked) = await _read();
      await _write([for (final x in pend) if (!which.contains(x)) x],
          {...acked, ...which}.toList());
    });
  }

  /// A user-started import begins: earlier acknowledgements no longer apply.
  /// Never called for a resume.
  Future<void> beginFreshImport() => _queued(() async {
        final (pend, acked) = await _read();
        if (acked.isEmpty) return;
        await _write(pend, const []);
      });
}
