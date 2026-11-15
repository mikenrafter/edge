// Owns install-local update consent, cache, leases and permanent release claims.
// Separate from LocalDb: updates never write health tables or enter an export.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'update_models.dart';

class UpdateLease {
  const UpdateLease(this.token, this.generation);
  final int token, generation;
}

class UpdateStore {
  UpdateStore(this.db);
  final Database db;
  static Future<UpdateStore>? _opening;
  static Future<UpdateStore> open() =>
      _opening ??= _open().catchError((Object e) {
        _opening = null;
        throw e;
      });
  static Future<UpdateStore> _open() async {
    final directory = Platform.isAndroid
        ? await const MethodChannel(
            'openstrap/release_environment',
          ).invokeMethod<String>('storagePath')
        : (await getApplicationSupportDirectory()).path;
    if (directory == null) {
      throw const FileSystemException('Update storage unavailable');
    }
    final store = UpdateStore(
      await openDatabase('$directory/release-checks-v1.db'),
    );
    await store.initialize();
    return store;
  }

  Future<void> initialize() async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS update_state (id INTEGER PRIMARY KEY CHECK(id=1), '
      'official_prereleases INTEGER NOT NULL DEFAULT 0, enabled INTEGER NOT NULL DEFAULT 0, generation INTEGER NOT NULL DEFAULT 0, '
      'token INTEGER NOT NULL DEFAULT 0, lease_until INTEGER NOT NULL DEFAULT 0, '
      'next_at INTEGER NOT NULL DEFAULT 0, manual_at INTEGER NOT NULL DEFAULT 0)',
    );
    await db.rawInsert('INSERT OR IGNORE INTO update_state(id) VALUES(1)');
    await db.execute(
      'CREATE TABLE IF NOT EXISTS update_sources (source TEXT PRIMARY KEY, json TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS update_manifests '
      '(key TEXT PRIMARY KEY, json TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS update_notifications (identity TEXT PRIMARY KEY)',
    );
  }

  Future<UpdateSnapshot> read() => db.transaction((txn) async {
    final state = (await txn.query('update_state')).single;
    final sources = <ReleaseSource, SourceUpdate>{};
    for (final row in await txn.query('update_sources')) {
      try {
        final source = ReleaseSource.values.byName(row['source'] as String);
        final result = SourceUpdate.fromJson(
          jsonDecode(row['json'] as String) as Map<String, dynamic>,
        );
        if (result.candidate != null && result.candidate!.source != source) {
          continue;
        }
        sources[source] = result;
      } catch (_) {
        /* corrupt cache is never a release or a link */
      }
    }
    final enabled = state['enabled'] == 1;
    final phase = sources.isEmpty
        ? (enabled ? UpdatePhase.notChecked : UpdatePhase.off)
        : sources.values.any(
            (v) => v.candidate != null && !v.current && v.error == null,
          )
        ? UpdatePhase.available
        : sources.values.any((v) => v.error != null)
        ? UpdatePhase.error
        : UpdatePhase.current;
    return UpdateSnapshot(
      enabled: enabled,
      phase: phase,
      sources: Map.unmodifiable(sources),
      officialPrereleases: state['official_prereleases'] == 1,
    );
  });

  Future<void> setEnabled(bool enabled) => db.transaction((txn) async {
    await txn.rawUpdate(
      'UPDATE update_state SET enabled=?, generation=generation+1, '
      'lease_until=0, next_at=0 WHERE id=1',
      [enabled ? 1 : 0],
    );
    if (!enabled) {
      await txn.delete('update_sources');
      await txn.delete('update_manifests');
    }
  });

  Future<void> setOfficialPrereleases(bool enabled) => db.transaction((
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
      whereArgs: ['official'],
    );
  });

  // CLAIM(update-lease): one cross-isolate batch, generation-checked saves and
  // a deadline committed before network work [update_checker_test].
  Future<UpdateLease?> claim(DateTime now, {required bool manual}) =>
      db.transaction((txn) async {
        final row = (await txn.query('update_state')).single;
        final ms = now.millisecondsSinceEpoch;
        final leaseUntil = row['lease_until'] as int;
        if (leaseUntil > ms &&
            leaseUntil - ms <= const Duration(minutes: 5).inMilliseconds) {
          return null;
        }
        if (!manual && row['enabled'] != 1) return null;
        final due = row['next_at'] as int;
        if (!manual && due > ms) {
          // A backward wall-clock jump gets one bounded daily postponement.
          if (due - ms > const Duration(hours: 30).inMilliseconds) {
            await txn.update('update_state', {
              'next_at': ms + const Duration(days: 1).inMilliseconds,
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
        final token = (row['token'] as int) + 1;
        await txn.update('update_state', {
          'token': token,
          'lease_until': ms + 300000,
          'next_at': ms + const Duration(days: 1).inMilliseconds,
          if (manual) 'manual_at': ms,
        }, where: 'id=1');
        return UpdateLease(token, row['generation'] as int);
      });

  Future<bool> save(
    UpdateLease lease,
    ReleaseSource source,
    SourceUpdate result,
  ) => db.transaction((txn) async {
    final row = (await txn.query('update_state')).single;
    if (row['generation'] != lease.generation || row['token'] != lease.token) {
      return false;
    }
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

  // CLAIM(update-manifest-cache): only validated, allowlisted fields are saved
  // under the current batch generation [update_manifest_cache_test].
  Future<bool> saveManifest(
    UpdateLease lease,
    String key,
    Map<String, dynamic> metadata,
  ) => db.transaction((txn) async {
    final row = (await txn.query('update_state')).single;
    if (row['generation'] != lease.generation || row['token'] != lease.token) {
      return false;
    }
    await txn.insert('update_manifests', {
      'key': key,
      'json': jsonEncode(metadata),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return true;
  });

  Future<bool> valid(UpdateLease lease) async {
    final row = (await db.query('update_state')).single;
    return row['generation'] == lease.generation && row['token'] == lease.token;
  }

  Future<void> release(UpdateLease lease) => db
      .rawUpdate(
        'UPDATE update_state SET lease_until=0 WHERE token=? AND generation=?',
        [lease.token, lease.generation],
      )
      .then((_) {});

  // CLAIM(update-notification-claim): durable INSERT OR IGNORE, no dated
  // expiry and no degraded non-atomic fallback [update_notifications_test].
  // Claim before presenting; a crash may omit an alert, but cannot repeat it.
  Future<bool> claimNotification(String identity) async =>
      await claimNotificationId(identity) != null;

  /// Uses this ledger's rowid so notification IDs never touch the health DB.
  Future<int?> claimNotificationId(String identity) => db
      .transaction<int?>((txn) async {
        if ((await txn.query('update_state')).single['enabled'] != 1) {
          return null;
        }
        await txn.rawInsert(
          'INSERT OR IGNORE INTO update_notifications(identity) VALUES(?)',
          [identity],
        );
        if ((await txn.rawQuery('SELECT changes() AS n')).single['n'] != 1) {
          return null;
        }
        final slot =
            (await txn.rawQuery(
                  'SELECT rowid AS slot FROM update_notifications WHERE identity=?',
                  [identity],
                )).single['slot']
                as int;
        if (slot >= 100000) {
          throw StateError('Update notification ID band exhausted');
        }
        return 500000 + slot;
      })
      .catchError((Object _) => null); // Unavailable/busy storage fails closed.
}
