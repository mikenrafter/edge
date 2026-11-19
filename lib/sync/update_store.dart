// Owns install-local update consent, cache, leases and permanent release
// claims in `release-checks-v1.db` under Android's noBackupFilesDir. Separate
// from LocalDb: updates never write health tables or enter an export, and no
// code here opens the health database.
//
// Reset paths (spec §5.4, owner 2026-11-17 R8), both tested:
//  * "Delete everything" in the health store does not touch this file: consent
//    and release claims survive it.
//  * An explicit full app-data reset (the OS clears noBackupFilesDir) removes
//    the file; the next open is a fresh store: off, no cache, no claims.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../notify/event_claim_ledger.dart';
import 'update_models.dart';

/// One batch's right to write. A stale holder (older token, older generation)
/// is refused on every write.
class UpdateLease {
  const UpdateLease(this.token, this.generation);
  final int token, generation;
}

/// What [UpdateStore.beginRelease] hands the one delivering owner.
class ReleaseTicket {
  const ReleaseTicket(this.identity, this.osId, this.token, this.generation);
  final String identity;
  final int osId, token, generation;
}

/// The store file cannot be used by this build (a newer schema).
class UpdateStoreException implements Exception {
  const UpdateStoreException(this.message);
  final String message;
  @override
  String toString() => 'UpdateStoreException: $message';
}

class UpdateStore {
  UpdateStore(this.db);
  final Database db;

  /// Independent of LocalDb's schema; bumped only with an additive migration.
  static const schemaVersion = 1;
  static const busyTimeout = Duration(seconds: 2);

  /// Manifest cache rows kept (positive and negative together).
  static const manifestRetention = 64;

  static const _lease = Duration(minutes: 5);
  static const _daily = Duration(days: 1);
  static const _maxJitter = Duration(hours: 6);

  /// First OS notification id for release alerts; the band 500000+ belongs to
  /// no other category (see NotificationIds.bandBaseFor).
  static const osIdBase = 500000;

  /// The retired companion-pointer switch older builds wrote to
  /// SharedPreferences. Nothing reads it: it is listed as never restored
  /// (kPrefsNotBackedUp) and grants this store no consent.
  static const retiredCompanionSwitch = 'update_checks_enabled';

  static Future<UpdateStore>? _opening;

  /// The production file under Android's noBackupFilesDir (or the app support
  /// directory off Android), shared by the UI and the background worker.
  static Future<UpdateStore> open() =>
      _opening ??= _openProduction().catchError((Object e) {
        _opening = null;
        throw e;
      });

  static Future<UpdateStore> _openProduction() async {
    final directory = Platform.isAndroid
        ? await const MethodChannel(
            'openstrap/release_environment',
          ).invokeMethod<String>('storagePath')
        : (await getApplicationSupportDirectory()).path;
    if (directory == null) {
      throw const FileSystemException('Update storage unavailable');
    }
    return openFile('$directory/release-checks-v1.db');
  }

  /// [open] for a given path and factory; tests and [open] use it. A file that
  /// is not a database is replaced by a fresh off store that reports the reset.
  static Future<UpdateStore> openFile(
    String path, {
    DatabaseFactory? factory,
  }) async {
    final f = factory ?? databaseFactory;
    Future<UpdateStore> attempt({required bool reset}) async {
      final store = UpdateStore(await f.openDatabase(path));
      try {
        await store.initialize();
        if (reset) await store._markReset();
        return store;
      } catch (_) {
        await store.db.close();
        rethrow;
      }
    }

    try {
      return await attempt(reset: false);
    } catch (error) {
      if (!await _notDatabase(error, path)) rethrow;
      // SQLite serializes engines in one process too; Dart's file locks do
      // not. Recheck under that ownership before replacing a corrupt file.
      final recovery = UpdateStore(await f.openDatabase('$path.recovery.db',
          options: OpenDatabaseOptions(singleInstance: false)));
      try {
        await recovery.db.rawQuery('PRAGMA busy_timeout = 0');
        await recovery.db.rawQuery('PRAGMA journal_mode=WAL');
        return await recovery._tx((txn) async {
          await txn.execute(
            'CREATE TABLE IF NOT EXISTS recovery_owner (id INTEGER PRIMARY KEY)',
          );
          try {
            return await attempt(reset: false);
          } catch (retryError) {
            if (!await _notDatabase(retryError, path)) rethrow;
            await f.deleteDatabase(path);
            return await attempt(reset: true);
          }
        });
      } finally {
        await recovery.db.close();
      }
    }
  }

  /// Only SQLITE_NOTADB plus an invalid SQLite header permits file replacement.
  /// Busy, full-disk, I/O and corrupt-page errors retain all permanent claims.
  static Future<bool> _notDatabase(Object error, String path) async {
    if (error is! DatabaseException ||
        ((error.getResultCode() ?? -1) & 0xff) != 26 &&
            !error.toString().contains('file is not a database')) {
      return false;
    }
    final file = await File(path).open();
    try {
      final header = await file.read(16);
      return ascii.decode(header, allowInvalid: true) != 'SQLite format 3\x00';
    } finally {
      await file.close();
    }
  }

  Future<void> initialize() async {
    // Per connection: wait for a brief foreign write lock instead of failing.
    await db.rawQuery('PRAGMA busy_timeout = ${busyTimeout.inMilliseconds}');
    final version = Sqflite.firstIntValue(
      await db.rawQuery('PRAGMA user_version'),
    );
    if ((version ?? 0) > schemaVersion) {
      throw UpdateStoreException(
        'release-checks schema $version is newer than $schemaVersion',
      );
    }
    await db.execute(
      'CREATE TABLE IF NOT EXISTS update_state (id INTEGER PRIMARY KEY CHECK(id=1), '
      'official_prereleases INTEGER NOT NULL DEFAULT 0, enabled INTEGER NOT NULL DEFAULT 0, '
      'generation INTEGER NOT NULL DEFAULT 0, token INTEGER NOT NULL DEFAULT 0, '
      'lease_until INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL DEFAULT 0, '
      'manual_at INTEGER NOT NULL DEFAULT 0, notice INTEGER NOT NULL DEFAULT 0)',
    );
    await db.rawInsert('INSERT OR IGNORE INTO update_state(id) VALUES(1)');
    await db.execute(
      'CREATE TABLE IF NOT EXISTS update_sources (source TEXT PRIMARY KEY, json TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS update_progress (source TEXT PRIMARY KEY, json TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS update_manifests (key TEXT PRIMARY KEY, json TEXT NOT NULL)',
    );
    // seq is AUTOINCREMENT so an OS id is never reused, even for a freed claim.
    await db.execute(
      'CREATE TABLE IF NOT EXISTS update_notifications (seq INTEGER PRIMARY KEY AUTOINCREMENT, '
      'identity TEXT NOT NULL UNIQUE, state TEXT NOT NULL, token INTEGER NOT NULL DEFAULT 0)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS update_deliveries (identity TEXT NOT NULL, target TEXT NOT NULL, '
      'PRIMARY KEY(identity, target))',
    );
    if ((version ?? 0) < schemaVersion) {
      await db.rawQuery('PRAGMA user_version = $schemaVersion');
    }
  }

  /// A transaction that waits (bounded by [busyTimeout]) for a brief foreign
  /// write lock instead of surfacing SQLITE_BUSY, whatever the platform's own
  /// busy handler does.
  Future<T> _tx<T>(Future<T> Function(Transaction txn) action) async {
    final deadline = DateTime.now().add(busyTimeout);
    for (var delay = 20;; delay = (delay * 2).clamp(20, 200)) {
      try {
        return await db.transaction(action);
      } on DatabaseException catch (e) {
        final locked = e.toString().contains('database is locked');
        if (!locked || DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(Duration(milliseconds: delay));
      }
    }
  }

  Future<void> _markReset() =>
      db.rawUpdate('UPDATE update_state SET notice=1 WHERE id=1');

  Future<void> acknowledgeReset() =>
      db.rawUpdate('UPDATE update_state SET notice=0 WHERE id=1').then((_) {});

  static bool _flag(Object? v) => v == 0 || v == 1;

  /// Consent, per-source cache. Unreadable consent resets to off, drops the
  /// caches and is reported once through [UpdateSnapshot.authorizationReset].
  Future<UpdateSnapshot> read() => _tx((txn) async {
    final rows = await txn.query('update_state');
    Map<String, Object?>? found = rows.length == 1 ? rows.single : null;
    final row0 = found;
    final intact = row0 != null &&
        _flag(row0['enabled']) &&
        _flag(row0['official_prereleases']) &&
        row0['generation'] is int &&
        row0['token'] is int &&
        row0['lease_until'] is int &&
        row0['next_at'] is int &&
        row0['manual_at'] is int &&
        _flag(row0['notice']);
    if (!intact) {
      final previous = row0?['generation'];
      await txn.delete('update_state');
      await txn.delete('update_sources');
      await txn.delete('update_manifests');
      await txn.delete('update_progress');
      await txn.insert('update_state', {
        'id': 1,
        'generation': (previous is int ? previous : 0) + 1,
        'notice': 1,
      });
      found = (await txn.query('update_state')).single;
    }
    final row = found!;
    final sources = <ReleaseSource, SourceUpdate>{};
    for (final saved in await txn.query('update_sources')) {
      try {
        final source = ReleaseSource.values.byName(saved['source'] as String);
        final result = SourceUpdate.fromJson(
          jsonDecode(saved['json'] as String) as Map<String, dynamic>,
        );
        if (result.candidate != null && result.candidate!.source != source) {
          continue;
        }
        sources[source] = result;
      } catch (_) {
        /* a corrupt cache entry is never a release or a link */
      }
    }
    final enabled = row['enabled'] == 1;
    return UpdateSnapshot(
      enabled: enabled,
      phase: enabled ? UpdatePhase.notChecked : UpdatePhase.off,
      sources: Map.unmodifiable(sources),
      officialPrereleases: row['official_prereleases'] == 1,
      authorizationReset: row['notice'] == 1,
    );
  });

  /// Opting in or out. Both bump the generation, end any lease and reset the
  /// due slot, so a late result cannot cross the change. Opting out clears the
  /// caches and cancels held announcements; permanent claims stay.
  Future<void> setEnabled(bool enabled) => _tx((txn) async {
    await txn.rawUpdate(
      'UPDATE update_state SET enabled=?, generation=generation+1, '
      'lease_until=0, next_at=0 WHERE id=1',
      [enabled ? 1 : 0],
    );
    if (!enabled) {
      await txn.delete('update_sources');
      await txn.delete('update_manifests');
      await txn.delete('update_progress');
      await _discardHeld(txn);
    }
  });

  Future<void> setOfficialPrereleases(bool enabled) => _tx((
    txn,
  ) async {
    await txn.rawUpdate(
      'UPDATE update_state SET official_prereleases=?, generation=generation+1, '
      'lease_until=0, next_at=0 WHERE id=1',
      [enabled ? 1 : 0],
    );
    await txn.delete(
      'update_sources',
      where: 'source=?',
      whereArgs: [ReleaseSource.official.name],
    );
    await txn.delete('update_progress', where: 'source=?',
        whereArgs: [ReleaseSource.official.name]);
  });

  /// One cross-isolate batch. Automatic claims need consent and the daily slot
  /// (24 h plus up to six hours of [jitter]); manual claims are the separate
  /// one-time authorization, throttled to one per minute. The lease and slot
  /// are committed before any network work.
  Future<UpdateLease?> claim(
    DateTime now, {
    required bool manual,
    Duration jitter = Duration.zero,
  }) => _tx((txn) async {
    final row = (await txn.query('update_state')).single;
    final ms = now.millisecondsSinceEpoch;
    final leaseUntil = row['lease_until'] as int;
    // A lease further out than its own bound is a clock rollback, not a holder.
    if (leaseUntil > ms && leaseUntil - ms <= _lease.inMilliseconds) {
      return null;
    }
    if (!manual && row['enabled'] != 1) return null;
    final due = row['next_at'] as int;
    if (!manual && due > ms) {
      if (due - ms > (_daily + _maxJitter).inMilliseconds) {
        await txn.update('update_state', {
          'next_at': ms + _daily.inMilliseconds,
        });
      }
      return null;
    }
    final manualAt = row['manual_at'] as int;
    if (manual &&
        manualAt != 0 &&
        ms - manualAt < 60000 &&
        ms - manualAt > -60000) {
      return null;
    }
    final extra = manual
        ? Duration.zero
        : Duration(
            milliseconds: jitter.inMilliseconds.clamp(
              0,
              _maxJitter.inMilliseconds,
            ),
          );
    final token = (row['token'] as int) + 1;
    await txn.update('update_state', {
      'token': token,
      'lease_until': ms + _lease.inMilliseconds,
      'next_at': ms + _daily.inMilliseconds + extra.inMilliseconds,
      if (manual) 'manual_at': ms,
    }, where: 'id=1');
    return UpdateLease(token, row['generation'] as int);
  });

  /// Extend the holder's lease through a long batch. False for a stale holder.
  Future<bool> renew(UpdateLease lease, DateTime now) =>
      _tx((txn) async {
        final row = (await txn.query('update_state')).single;
        if (row['generation'] != lease.generation ||
            row['token'] != lease.token) {
          return false;
        }
        await txn.update('update_state', {
          'lease_until': now.millisecondsSinceEpoch + _lease.inMilliseconds,
        }, where: 'id=1');
        return true;
      });

  Future<bool> save(
    UpdateLease lease,
    ReleaseSource source,
    SourceUpdate result,
  ) => _tx((txn) async {
    if (!await _holds(txn, lease)) return false;
    await txn.insert('update_sources', {
      'source': source.name,
      'json': jsonEncode(result.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return true;
  });

  Future<Map<String, dynamic>?> manifest(String key) async {
    final rows = await db.query(
      'update_manifests',
      where: 'key=?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(
        jsonDecode(rows.single['json'] as String) as Map,
      );
    } catch (_) {
      return null;
    }
  }

  /// A positive entry (the checked manifest fields) or a negative one
  /// (`{'unusable': true}`), under the batch's generation. Oldest entries
  /// beyond [manifestRetention] are evicted; claims are never touched.
  Future<bool> saveManifest(
    UpdateLease lease,
    String key,
    Map<String, dynamic> metadata,
  ) => _tx((txn) async {
    if (!await _holds(txn, lease)) return false;
    await txn.insert('update_manifests', {
      'key': key,
      'json': jsonEncode(metadata),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await txn.rawDelete(
      'DELETE FROM update_manifests WHERE rowid NOT IN '
      '(SELECT rowid FROM update_manifests ORDER BY rowid DESC LIMIT ?)',
      [manifestRetention],
    );
    return true;
  });

  /// At most one bounded progress summary per source, fenced by the batch lease.
  static const maxProgressBytes = 128 * 1024;

  Future<Map<String, dynamic>?> progress(ReleaseSource source) async {
    final rows = await db.query('update_progress', where: 'source=?',
        whereArgs: [source.name]);
    if (rows.isEmpty) return null;
    final raw = rows.single['json'] as String;
    if (raw.length > maxProgressBytes) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<bool> saveProgress(UpdateLease lease, ReleaseSource source,
      Map<String, dynamic> progress) => _tx((txn) async {
    if (!await _holds(txn, lease)) return false;
    final json = jsonEncode(progress);
    if (utf8.encode(json).length > maxProgressBytes) {
      throw const FormatException('Discovery progress too large');
    }
    await txn.insert('update_progress', {'source': source.name, 'json': json},
        conflictAlgorithm: ConflictAlgorithm.replace);
    return true;
  });

  Future<bool> _holds(DatabaseExecutor txn, UpdateLease lease) async {
    final row = (await txn.query('update_state')).single;
    return row['generation'] == lease.generation && row['token'] == lease.token;
  }

  Future<bool> valid(UpdateLease lease) => _holds(db, lease);

  Future<void> release(UpdateLease lease) => db
      .rawUpdate(
        'UPDATE update_state SET lease_until=0 WHERE token=? AND generation=?',
        [lease.token, lease.generation],
      )
      .then((_) {});

  // ── release claims ─────────────────────────────────────────────────────────
  // One permanent claim per `(repository, release id)` identity. States:
  //   presenting  an owner holds it now (a crash here leaves it consumed)
  //   held        quiet/sleep policy holds the alert; reserved, reusable
  //   sent        presented; permanent
  //   unknown     ambiguous hand-off; permanent (at most once, not exactly once)
  //   free        given back after known non-delivery or an opt-out

  /// Take the claim for [identity], or null when it is consumed or owned now.
  /// A held or freed claim is taken back with the SAME OS id.
  Future<ReleaseTicket?> beginRelease(String identity, DateTime now) =>
      _tx((txn) async {
        final consent = (await txn.query('update_state')).single;
        final generation = consent['generation'] as int;
        final rows = await txn.query(
          'update_notifications',
          where: 'identity=?',
          whereArgs: [identity],
        );
        if (rows.isEmpty) {
          final seq = await txn.insert('update_notifications', {
            'identity': identity,
            'state': 'presenting',
            'token': 1,
          });
          return ReleaseTicket(identity, osIdBase + seq, 1, generation);
        }
        final row = rows.single;
        if (row['state'] != 'held' && row['state'] != 'free') return null;
        final token = (row['token'] as int) + 1;
        await txn.update(
          'update_notifications',
          {'state': 'presenting', 'token': token},
          where: 'identity=?',
          whereArgs: [identity],
        );
        return ReleaseTicket(identity, osIdBase + (row['seq'] as int), token, generation);
      });

  /// Consent belongs to this attempt's generation, including across off/on.
  Future<bool> releaseWanted(ReleaseTicket ticket) => _tx((txn) async {
    final row = (await txn.query('update_state')).single;
    return row['enabled'] == 1 && row['generation'] == ticket.generation;
  });

  /// A stale attempt may consume a delivery, but cannot resurrect a held intent.
  Future<void> settleRelease(ReleaseTicket ticket, ClaimOutcome outcome) =>
      _tx((txn) async {
        final consent = (await txn.query('update_state')).single;
        final wanted = consent['generation'] == ticket.generation;
        final settled = outcome == ClaimOutcome.held && !wanted
            ? ClaimOutcome.released : outcome;
        await txn.rawUpdate(
          'UPDATE update_notifications SET state=? '
          "WHERE identity=? AND token=? AND state='presenting'",
          [
            switch (settled) {
              ClaimOutcome.sent => 'sent',
              ClaimOutcome.held => 'held',
              ClaimOutcome.released => 'free',
              ClaimOutcome.unknown => 'unknown',
            },
            ticket.identity,
            ticket.token,
          ],
        );
      });

  /// Identities whose alert the quiet/sleep policy is holding.
  Future<List<String>> heldReleases() async => [
    for (final row in await db.query(
      'update_notifications',
      columns: ['identity'],
      where: "state='held'",
      orderBy: 'seq',
    ))
      row['identity'] as String,
  ];

  /// Opt-out: held intents are cancelled; sent and unknown claims stay. With
  /// [except], only held claims outside it are given back (a recovery pass that
  /// found some held releases no longer worth announcing).
  Future<void> discardHeld({Set<String> except = const {}}) =>
      _tx((txn) => _discardHeld(txn, except));

  Future<void> _discardHeld(
    DatabaseExecutor txn, [
    Set<String> except = const {},
  ]) async {
    if (except.isEmpty) {
      await txn.update('update_notifications', {'state': 'free'},
          where: "state='held'");
      return;
    }
    final held = await txn.query('update_notifications',
        columns: ['identity'], where: "state='held'");
    for (final row in held) {
      final identity = row['identity'];
      if (except.contains(identity)) continue;
      await txn.update('update_notifications', {'state': 'free'},
          where: "state='held' AND identity=?", whereArgs: [identity]);
    }
  }

  /// Whether a validated manifest for [tag] and [build] is cached: the cache a
  /// 304 over a fork listing relies on.
  Future<bool> hasManifest(String tag, int build) async {
    for (final row in await db.query('update_manifests')) {
      try {
        final m = jsonDecode(row['json'] as String) as Map;
        if (m['tag'] == tag && m['versionCode'] == build) return true;
      } catch (_) {}
    }
    return false;
  }

  /// Once-only mark for one routed destination of a release. True to the
  /// first caller; the release claim itself stays the single owner of intent.
  Future<bool> claimTarget(String identity, String target) =>
      _tx((txn) async {
        final existing = await txn.query(
          'update_deliveries',
          where: 'identity=? AND target=?',
          whereArgs: [identity, target],
        );
        if (existing.isNotEmpty) return false;
        await txn.insert('update_deliveries', {
          'identity': identity,
          'target': target,
        });
        return true;
      });

  Future<void> releaseTarget(String identity, String target) => db
      .delete(
        'update_deliveries',
        where: 'identity=? AND target=?',
        whereArgs: [identity, target],
      )
      .then((_) {});
}
