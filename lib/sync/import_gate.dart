// import_gate.dart — ONE owner of "an import is running, so nothing syncs".
//
// Owner directive: the app does no syncing while an import is happening. A
// band that reconnected mid-import drained, committed rows and ACKed while the
// import was merging the same tables.
//
// State owned here (nobody else mutates it):
//  * [_imports]  imports running in this process; raised and lowered only by
//    `ImportJournal.runExclusive`, which also covers a resume.
//  * [_pending]  the journal holds an unfinished run that a resume has not
//    picked up yet (a process killed mid-import). Read by [probe].
//  * [_drains]   engines whose history offload is in flight, fed by
//    `BleEngine._setOffloadActive`, the one choke point of that flag.
//
// What it refuses is the START of a drain, an offload or a record commit.
// Interrupting one mid-chunk is never done: commit-before-ACK (AGENTS 3.1)
// means a refused request costs nothing (the band keeps its flash), while a
// half-ACKed chunk loses data. So an import that finds a drain in flight
// raises the flag at once (no NEW drain starts) and then waits for the
// running one to end, or is deferred with a reason.
//
// Static, like ResetGate: every sync entry point, headless included, runs in
// the main isolate. A background isolate would not see it (see reset_gate.dart).
// Live streams persist nothing and are not gated.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/db.dart';
import '../data/import_journal.dart';

enum ImportBlock { importRunning, importPending, drainInProgress }

sealed class SyncPermit {
  const SyncPermit();
}

final class SyncAllowed extends SyncPermit {
  const SyncAllowed();
}

final class SyncRefused extends SyncPermit {
  const SyncRefused(this.reason);
  final ImportBlock reason;

  /// The sentence a status line shows.
  String get message => reason == ImportBlock.drainInProgress
      ? 'Waiting for the sync to finish before importing'
      : 'Waiting for the import to finish';
}

sealed class ImportAdmission {
  const ImportAdmission();
}

final class ImportAdmitted extends ImportAdmission {
  const ImportAdmitted();
}

final class ImportDeferred extends ImportAdmission {
  const ImportDeferred(this.reason);
  final ImportBlock reason;
  String get message => 'A sync is still writing; try the import again in a moment';
}

class ImportGate {
  ImportGate._();

  /// Every place that can start a drain, an offload or a record commit. The
  /// source guard in test/import_gate_test.dart keeps this honest.
  static const List<String> entryPoints = [
    'ble.refresh', // _startHistoricalRefresh: every in-session trigger
    'ble.init_drain', // _doConnect's INIT: the first drain of a session
    'headless.gate', // HeadlessSyncGate.tryRun: all background wake sources
    'headless.sync', // runHeadlessSync
    'coordinator.syncNow', // pull-to-sync and every manual control
    'shortcut.sync', // iOS Shortcut
    'wearable.run', // BandHost.run
    'wearable.commit', // BandHost record commit
  ];

  static int _imports = 0;
  static bool _pending = false;
  static final Set<Object> _drains = {};
  static Completer<void>? _drained;
  static final Map<String, int> refusals = {};

  /// What a status line reads; changes only when the answer does.
  static final ValueNotifier<SyncPermit> state =
      ValueNotifier<SyncPermit>(const SyncAllowed());

  static bool get drainActive => _drains.isNotEmpty;

  /// May [entry] start syncing now? Counts the refusal per entry.
  static SyncPermit check(String entry) {
    final p = _now();
    if (p is SyncRefused) refusals[entry] = (refusals[entry] ?? 0) + 1;
    return p;
  }

  static SyncPermit _now() => _imports > 0
      ? const SyncRefused(ImportBlock.importRunning)
      : _pending
          ? const SyncRefused(ImportBlock.importPending)
          : const SyncAllowed();

  static void _publish() {
    final p = _now();
    final old = state.value;
    if (old.runtimeType == p.runtimeType &&
        (old is! SyncRefused || old.reason == (p as SyncRefused).reason)) {
      return;
    }
    state.value = p;
  }

  /// An import is starting. Pair with [leave] in a `finally`.
  static void enter() {
    _imports++;
    _publish();
  }

  static void leave() {
    if (_imports > 0) _imports--;
    _publish();
  }

  /// Raises the gate, then waits for a drain that is already mid-chunk to end.
  /// On [ImportDeferred] the gate is lowered again: nothing was started.
  static Future<ImportAdmission> beginImport({
    Duration wait = const Duration(seconds: 30),
  }) async {
    enter();
    if (_drains.isEmpty) return const ImportAdmitted();
    final done = _drained ??= Completer<void>();
    try {
      await done.future.timeout(wait);
      return const ImportAdmitted();
    } on TimeoutException {
      leave();
      return const ImportDeferred(ImportBlock.drainInProgress);
    }
  }

  /// [owner]'s history offload started or ended. Idempotent per owner.
  static void drainChanged(Object owner, bool active) {
    if (active) {
      _drains.add(owner);
      return;
    }
    if (_drains.remove(owner) && _drains.isEmpty) {
      final c = _drained;
      _drained = null;
      if (c != null && !c.isCompleted) c.complete();
    }
  }

  /// Reads the journal once: a run that is unfinished and still to be resumed
  /// keeps sync shut after a restart. Cheap; safe to call often. A failed read
  /// leaves the answer as it was.
  static Future<void> probe() async {
    try {
      final db = await LocalDb.instance;
      final rows = await db.query('import_journal',
          columns: ['state', 'resumes'], orderBy: 'id DESC', limit: 1);
      final r = rows.firstOrNull;
      // Same rule as ImportJournal.resumeIfUnfinished: done is done; a failed
      // run past its automatic retries waits for the user, not for sync.
      _pending = r != null &&
          r['state'] != 'done' &&
          !(r['state'] == 'failed' &&
              ((r['resumes'] as int?) ?? 0) >= ImportJournal.kMaxAutoResumes);
      _publish();
    } catch (_) {
      /* no table yet, or no database: the answer stays as it was */
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _imports = 0;
    _pending = false;
    _drains.clear();
    _drained = null;
    refusals.clear();
    state.value = const SyncAllowed();
  }
}
