// Owner: PulseEpisodeStore. Episode reconciliation, evidence and delivery claims
// share this transaction boundary; no FK points to prunable signal tables.
import 'dart:convert';
import 'package:flutter/foundation.dart' show mapEquals;
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:sqflite/sqflite.dart';
import '../util/heavy.dart';
import '../util/worker_init.dart';
import '../util/worker_audit.dart';
import 'day_label.dart';

const pulseEpisodeTables = [
  'pulse_episode',
  'pulse_episode_revision',
  'pulse_evidence_chunk',
  'pulse_episode_outbox',
  'pulse_episode_alias',
  'pulse_input_arrival',
  'pulse_source_complete',
  'pulse_upgrade',
  'pulse_upgrade_record',
];
const pulseEvidenceBudget = 128 * 1024 * 1024;
const pulseEvidenceDays = 365;

class PulseEpisodeSnapshot {
  final Map<String, Object?> row;
  final Map<String, dynamic>? evidence;
  const PulseEpisodeSnapshot(this.row, this.evidence);
  String get id => row['id'] as String;
  int get startMs => row['start_ms'] as int;
  int get endMs => row['end_ms'] as int;
  String get alertState => row['alert_state'] as String? ?? 'owed';
  String? get alertReason => row['alert_reason'] as String?;
  String get evidenceStatus => evidence == null
      ? 'expired'
      : evidence!['partial'] == true
      ? 'partial'
      : 'complete';
  List<Map<String, dynamic>> get beats =>
      (evidence?['beats'] as List? ?? []).cast<Map<String, dynamic>>();
  String get alertNote => switch (alertState) {
    'sent' =>
      alertReason == 'before this version'
          ? 'Already sent: before this version'
          : 'Alert sent',
    'summary' => 'Alert included in a summary',
    'pending' || 'unknown' => 'Alert delivery unknown; it will not be repeated',
    'not_sent' => 'Not sent: ${alertReason ?? 'notifications off'}',
    _ => 'Alert waiting for delivery',
  };
}

/// The input moved between the worker's read and the commit (a late or live
/// record landed). Nothing was written; the day is read again on the next pass.
class PulseInputChanged implements Exception {
  const PulseInputChanged();
  @override
  String toString() => 'Pulse input changed; retry before pruning';
}

/// A row of `pulse_episode_outbox` that a delivery consumed or may have
/// consumed. A `summary` that only records a merge ("joined episode") never
/// reached the user, and neither did a retraction or a replaced episode.
bool pulseOutboxConsumed(Map<String, Object?> outbox) =>
    switch (outbox['state']) {
      'sent' || 'pending' || 'unknown' => true,
      'summary' => outbox['reason'] != 'joined episode',
      _ => false,
    };

const _retiredReasons = [
  'decision changed',
  'joined episode',
  'superseded episode',
];

class PulseEpisodeStore {
  final Database db;
  const PulseEpisodeStore(this.db);
  static Future<void> create(DatabaseExecutor db) async {
    for (final sql in [
      '''CREATE TABLE IF NOT EXISTS pulse_episode (
        id TEXT PRIMARY KEY, source TEXT NOT NULL, seed_ms INTEGER NOT NULL,
        start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, ongoing INTEGER NOT NULL,
        day TEXT NOT NULL, end_day TEXT NOT NULL, offset_min INTEGER, zone_provenance TEXT NOT NULL,
        first_seen_ms INTEGER NOT NULL, updated_ms INTEGER NOT NULL, revision TEXT NOT NULL,
        origin TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'active')''',
      '''CREATE TABLE IF NOT EXISTS pulse_episode_revision (
        episode_id TEXT NOT NULL, revision TEXT NOT NULL, detector INTEGER NOT NULL,
        summary TEXT NOT NULL, checksum TEXT NOT NULL, evidence_status TEXT NOT NULL,
        created_ms INTEGER NOT NULL, PRIMARY KEY(episode_id,revision))''',
      '''CREATE TABLE IF NOT EXISTS pulse_evidence_chunk (
        episode_id TEXT NOT NULL, revision TEXT NOT NULL, payload BLOB NOT NULL,
        byte_count INTEGER NOT NULL, created_ms INTEGER NOT NULL,
        PRIMARY KEY(episode_id,revision))''',
      '''CREATE TABLE IF NOT EXISTS pulse_episode_outbox (
        episode_id TEXT PRIMARY KEY, delivery_key TEXT NOT NULL UNIQUE,
        revision TEXT NOT NULL, state TEXT NOT NULL, reason TEXT, token TEXT,
        at_ms INTEGER NOT NULL, origin TEXT NOT NULL, summary_key TEXT)''',
      '''CREATE TABLE IF NOT EXISTS pulse_episode_alias (
        alias TEXT PRIMARY KEY, episode_id TEXT NOT NULL)''',
      '''CREATE TABLE IF NOT EXISTS pulse_input_arrival (
        source TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
        digest TEXT NOT NULL, origin TEXT NOT NULL, admitted_ms INTEGER NOT NULL,
        PRIMARY KEY(source,start_ms,end_ms,digest))''',
      '''CREATE TABLE IF NOT EXISTS pulse_source_complete (source TEXT PRIMARY KEY,through_ms INTEGER NOT NULL)''',
      '''CREATE TABLE IF NOT EXISTS pulse_upgrade (
        id INTEGER PRIMARY KEY CHECK(id=1), recorded_ms INTEGER NOT NULL)''',
      '''CREATE TABLE IF NOT EXISTS pulse_upgrade_record (
        source TEXT NOT NULL, ts_ms INTEGER NOT NULL,
        PRIMARY KEY(source,ts_ms))''',
      'CREATE INDEX IF NOT EXISTS pulse_episode_time ON pulse_episode(start_ms,id)',
      'CREATE INDEX IF NOT EXISTS pulse_evidence_age ON pulse_evidence_chunk(created_ms)',
    ]) {
      await db.execute(sql);
    }
  }

  /// Fallback for fresh installs, which have no onUpgrade transaction.
  Future<void> initializeUpgrade({required int nowMs}) =>
      db.transaction((txn) => captureUpgrade(txn, nowMs: nowMs));

  /// CLAIM(pulse-upgrade): schema migration commits the immutable record-key
  /// snapshot, prior-pilot sweep and marker before sync can add new records
  /// [pulse_upgrade_migration_test]. The caller must supply its transaction;
  /// failures propagate so all three writes roll back together.
  /// Recording timestamps are identities, not a cutoff: a missing older key
  /// delivered later remains new. Keeping keys after signal eviction also makes
  /// restore and re-decoding of the same records historical forever.
  static Future<void> captureUpgrade(
    DatabaseExecutor db, {
    required int nowMs,
  }) async {
    if ((await db.query('pulse_upgrade', limit: 1)).isNotEmpty) return;
    // Sparse legacy databases can predate decoded storage. onOpen repairs
    // them after this transaction; an absent RR table means no keys to capture,
    // not corruption. Existing tables still fail loudly on invalid reads.
    final hasRr = (await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name='decoded_rr'",
    )).isNotEmpty;
    if (hasRr) {
      await db.execute(
        'INSERT OR IGNORE INTO pulse_upgrade_record(source,ts_ms) '
        'SELECT device_id,ts_ms FROM decoded_rr',
      );
    }
    // A prior pilot may already have episodes. Close their debt in the same
    // transaction, before any delivery path can claim it.
    await db.rawUpdate(
      "UPDATE pulse_episode_outbox SET state='sent',reason='before this version',"
      "token=NULL,summary_key=NULL,at_ms=?",
      [nowMs],
    );
    await db.insert('pulse_upgrade', {'id': 1, 'recorded_ms': nowMs});
  }

  /// An episode alerts by itself when the band synced the day it started on
  /// ([syncDays]); every other path, or no knowledge, takes [origin].
  static String _originOf(
    ana.PulseEpisode episode,
    String origin,
    Set<String>? syncDays,
  ) => syncDays == null
      ? origin
      : syncDays.contains(
          dayLabelOf(DateTime.fromMillisecondsSinceEpoch(episode.startMs)),
        )
      ? 'sync'
      : 'bulk';

  /// Only HISTORY_COMPLETE with a durable tail certifies a band's closed history.
  /// A HISTORY_END transport chunk never advances this marker.
  Future<void> certifyCurrentSource(String source) => db.transaction((
    txn,
  ) async {
    final rows = await txn.rawQuery(
      'SELECT MAX(rec_ts)*1000 AS t FROM decoded_rr WHERE device_id=?',
      [source],
    );
    final through = rows.first['t'] as int?;
    if (through == null) return;
    await txn.rawInsert(
      'INSERT OR REPLACE INTO pulse_source_complete(source,through_ms) VALUES (?, MAX(?,COALESCE((SELECT through_ms FROM pulse_source_complete WHERE source=?),0)))',
      [source, through, source],
    );
  });

  // Completeness certificates are separate from delivery ancestry and are
  // safe to reconstruct from a later completed sync after restore.
  /// CLAIM(pulse-atomic): evidence and intent commit together [pulse_episode_store_test].
  /// Preparation throws before writes; any SQLite failure rolls back the whole reconciliation.
  Future<void> reconcile(
    ana.PulseDetection detection, {
    required String origin,
    required int nowMs,
    List<Map<String, dynamic>> heartRate = const [],
    PulseInputStamp? inputStamp,
    Set<String>? syncDays,
    Set<String> beforeVersion = const {},
  }) async {
    final frozen = await _protectedEpisodes(db);
    final admitted = <ana.PulseEpisode>[];
    final historicalIds = {...beforeVersion};
    for (final episode in detection.episodes) {
      var run = <ana.PulseWindow>[];
      void finish(bool ongoing) {
        if (run.length >= 2) {
          final child = ana.PulseEpisode(
            episode.source,
            List.unmodifiable(run),
            ongoing: ongoing,
          );
          admitted.add(child);
          if (beforeVersion.contains(episode.id)) historicalIds.add(child.id);
        }
        run = [];
      }

      for (final window in episode.windows) {
        if (frozen.any(
          (old) =>
              old['source'] == episode.source &&
              (old['start_ms'] as int) < window.endMs &&
              (old['end_ms'] as int) > window.startMs,
        )) {
          finish(false);
        } else {
          run.add(window);
        }
      }
      finish(episode.ongoing);
    }
    // A new qualifying tail outside old history remains independently visible.
    final admittedDetection = ana.PulseDetection(detection.windows, admitted);
    final input = PulsePreparationInput(admittedDetection, heartRate);
    final preparation = await Isolate.run(
      () => preparePulseEvidenceHeavy(input),
    );
    final prepared = preparation.episodes;
    await db.transaction((txn) async {
      if (inputStamp != null) {
        final rev = await txn.rawQuery(
          'SELECT COALESCE(SUM(rev),0) AS rev FROM input_rev WHERE bucket BETWEEN ? AND ?',
          [inputStamp.startBucket, inputStamp.endBucket],
        );
        if (rev.first['rev'] != inputStamp.revision ||
            (inputStamp.contextRevision != null &&
                await pulseContextRevision(txn) !=
                    inputStamp.contextRevision)) {
          throw const PulseInputChanged();
        }
      }
      // CLAIM(pulse-version-history): a new detector leaves old evidence and
      // delivery ancestry intact [pulse_episode_store_test]. Any overlap is
      // already represented by history, so it cannot create fresh alert debt.
      final protected = await _protectedEpisodes(txn);
      if (protected.length != frozen.length ||
          !protected.indexed.every(
            (pair) => mapEquals(pair.$2, frozen[pair.$1]),
          )) {
        throw const PulseInputChanged();
      }
      final protectedIds = {for (final e in protected) e['id']};
      final previousEpisodes = (await txn.query(
        'pulse_episode',
      )).where((e) => !protectedIds.contains(e['id'])).toList();
      final finalIds = <String>[];
      final admittedEpisodes = admitted;
      for (final episode in admittedEpisodes) {
        final encoded = prepared[episode.id]!;
        final overlaps =
            previousEpisodes
                .where(
                  (old) =>
                      old['source'] == episode.source &&
                      (old['start_ms'] as int) < episode.endMs &&
                      (old['end_ms'] as int) > episode.startMs,
                )
                .toList()
              ..sort((a, b) {
                final seed = (a['seed_ms'] as int).compareTo(
                  b['seed_ms'] as int,
                );
                return seed != 0
                    ? seed
                    : (a['id'] as String).compareTo(b['id'] as String);
              });
        var id = episode.id;
        for (final old in overlaps) {
          final seed = old['seed_ms'] as int;
          // Only a live row hands over its identity; a retired one stays retired.
          if (old['status'] == 'active' &&
              episode.startMs <= seed &&
              seed < episode.endMs) {
            id = old['id'] as String;
            break;
          }
        }
        final existing = await txn.query(
          'pulse_episode',
          where: 'id = ?',
          whereArgs: [id],
        );
        final reactivated =
            existing.isNotEmpty && existing.first['status'] != 'active';
        finalIds.add(id);
        final local = DateTime.fromMillisecondsSinceEpoch(episode.startMs);
        final revision = encoded['checksum'] as String;
        await txn.insert('pulse_episode', {
          'id': id,
          'source': episode.source,
          'seed_ms': existing.isEmpty
              ? episode.startMs
              : existing.first['seed_ms'],
          'start_ms': episode.startMs,
          'end_ms': episode.endMs,
          'ongoing': episode.ongoing ? 1 : 0,
          'day': existing.isEmpty ? dayLabelOf(local) : existing.first['day'],
          'end_day': dayLabelOf(
            DateTime.fromMillisecondsSinceEpoch(episode.endMs - 1),
          ),
          'offset_min': existing.isEmpty
              ? local.timeZoneOffset.inMinutes
              : existing.first['offset_min'],
          'zone_provenance': existing.isEmpty
              ? 'phoneAtAnalysis'
              : existing.first['zone_provenance'],
          'first_seen_ms': existing.isEmpty
              ? nowMs
              : existing.first['first_seen_ms'],
          'updated_ms': nowMs,
          'revision': revision,
          'origin': existing.isEmpty
              ? _originOf(episode, origin, syncDays)
              : existing.first['origin'],
          'status': 'active',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        // The id is live again: an old merge alias must not redirect it.
        await txn.delete(
          'pulse_episode_alias',
          where: 'alias = ?',
          whereArgs: [id],
        );
        await txn.insert('pulse_episode_revision', {
          'episode_id': id,
          'revision': revision,
          'detector': ana.pulseDetectorVersion,
          'summary': encoded['summary'],
          'checksum': revision,
          'evidence_status': encoded['partial'] == true
              ? 'partial'
              : 'complete',
          'created_ms': nowMs,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        await txn.insert('pulse_evidence_chunk', {
          'episode_id': id,
          'revision': revision,
          'payload': encoded['payload'],
          'byte_count': (encoded['payload'] as List).length,
          'created_ms': nowMs,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        // Descendants inherit consumed delivery, including ambiguous claims.
        Map<String, Object?>? inherited;
        var quietHeld = false;
        for (final old in overlaps) {
          final alerts = await txn.query(
            'pulse_episode_outbox',
            where: 'episode_id = ?',
            whereArgs: [old['id']],
          );
          if (alerts.isNotEmpty && alerts.first['reason'] == 'quiet hours') {
            quietHeld = true;
          }
          if (alerts.isNotEmpty && pulseOutboxConsumed(alerts.first)) {
            inherited = alerts.first;
            break;
          }
        }
        final historical = historicalIds.contains(episode.id);
        await txn.insert('pulse_episode_outbox', {
          'episode_id': id,
          'delivery_key': 'pulse-episode:$id',
          'revision': revision,
          'state': historical
              ? 'sent'
              : inherited?['state'] ??
                    (episode.alertEligible ? 'owed' : 'not_sent'),
          'reason': historical
              ? 'before this version'
              : inherited?['reason'] ??
                    (episode.alertEligible ? null : 'recording quality'),
          'at_ms': inherited?['at_ms'] ?? nowMs,
          'origin': _originOf(episode, origin, syncDays),
          'token': inherited?['token'],
          'summary_key': inherited?['summary_key'],
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        if (historical) {
          await txn.update(
            'pulse_episode_outbox',
            {
              'state': 'sent',
              'reason': 'before this version',
              'token': null,
              'summary_key': null,
            },
            where: 'episode_id=?',
            whereArgs: [id],
          );
        } else if (inherited != null) {
          await txn.update(
            'pulse_episode_outbox',
            {
              'state': inherited['state'],
              'reason': inherited['reason'],
              'at_ms': inherited['at_ms'],
              'token': inherited['token'],
              'summary_key': inherited['summary_key'],
            },
            where:
                "episode_id=? AND (state IN ('owed','not_sent') OR (state='summary' AND reason='joined episode'))",
            whereArgs: [id],
          );
        } else if (reactivated) {
          // A retracted, merged or replaced episode that qualifies again is a
          // live stretch nobody was told about: its terminal "decision
          // changed / joined / replaced" record is not a delivery.
          await txn.rawUpdate(
            "UPDATE pulse_episode_outbox SET state=?,reason=?,revision=?,at_ms=? "
            "WHERE episode_id=? AND state IN ('not_sent','summary') "
            "AND reason IN (${_retiredReasons.map((_) => '?').join(',')})",
            [
              episode.alertEligible ? 'owed' : 'not_sent',
              episode.alertEligible ? null : 'recording quality',
              revision,
              nowMs,
              id,
              ..._retiredReasons,
            ],
          );
        }
        // Quiet deferral is unconsumed ancestry: a split child or an existing
        // merge root must remain silent, without inheriting a consumed claim.
        if (!historical && inherited == null && quietHeld && episode.alertEligible) {
          await txn.update(
            'pulse_episode_outbox',
            {'reason': 'quiet hours'},
            where: "episode_id=? AND (state='owed' OR (state='not_sent' AND reason IN ('notifications off','quiet hours')))",
            whereArgs: [id],
          );
        }
        // At most current + handed-off revision. Delivery tombstones are never pruned.
        await txn.rawDelete(
          '''DELETE FROM pulse_evidence_chunk WHERE episode_id = ?
          AND revision != ? AND revision NOT IN
          (SELECT revision FROM pulse_episode_outbox WHERE episode_id = ?)''',
          [id, revision, id],
        );
      }
      // A live row that no new episode took over, yet overlaps one, describes
      // a stretch another row now owns: retire it into that row (an alias) so
      // a stretch is one active row, and its unsent alert is owed once, by the
      // survivor. Consumed records stay as they are; the survivor inherited them.
      for (final old in previousEpisodes) {
        final oldId = old['id'] as String;
        if (old['status'] != 'active' || finalIds.contains(oldId)) continue;
        final over = [
          for (var i = 0; i < admittedEpisodes.length; i++)
            if (admittedEpisodes[i].source == old['source'] &&
                admittedEpisodes[i].startMs < (old['end_ms'] as int) &&
                admittedEpisodes[i].endMs > (old['start_ms'] as int))
              i,
        ];
        if (over.isEmpty) continue;
        final seed = old['seed_ms'] as int;
        final holder = over.where(
          (i) =>
              admittedEpisodes[i].startMs <= seed &&
              seed < admittedEpisodes[i].endMs,
        );
        final joined = holder.isNotEmpty;
        await txn.insert('pulse_episode_alias', {
          'alias': oldId,
          'episode_id': finalIds[joined ? holder.first : over.first],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.update(
          'pulse_episode',
          {'status': joined ? 'merged' : 'superseded'},
          where: 'id = ?',
          whereArgs: [oldId],
        );
        await txn.update(
          'pulse_episode_outbox',
          joined
              ? {'state': 'summary', 'reason': 'joined episode'}
              : {'state': 'not_sent', 'reason': 'superseded episode'},
          where: "episode_id = ? AND state IN ('owed','not_sent')",
          whereArgs: [oldId],
        );
      }
      // CLAIM(pulse-late-context): quality refusal retains prior evidence;
      // complete semantic exclusions retract without creating delivery debt
      // [pulse_episode_store_test]. Consumed delivery ancestry is untouched.
      final candidates = await txn.query(
        'pulse_episode',
        where: "status = 'active'",
      );
      for (final old in candidates) {
        if (protectedIds.contains(old['id'])) continue;
        if (admittedEpisodes.any(
          (e) =>
              e.source == old['source'] &&
              e.startMs < (old['end_ms'] as int) &&
              e.endMs > (old['start_ms'] as int),
        )) {
          continue;
        }
        final covered = detection.windows
            .where(
              (w) =>
                  w.source == old['source'] &&
                  !w.pending &&
                  w.qualityReasons.isEmpty &&
                  w.startMs >= (old['start_ms'] as int) &&
                  w.endMs <= (old['end_ms'] as int),
            )
            .toList();
        if (covered.length * ana.pulseWindowMs <
            (old['end_ms'] as int) - (old['start_ms'] as int)) {
          continue;
        }
        await txn.update(
          'pulse_episode',
          {'status': 'retracted'},
          where: 'id=?',
          whereArgs: [old['id']],
        );
        await txn.rawUpdate(
          "UPDATE pulse_episode_outbox SET state='not_sent',reason='decision changed' WHERE episode_id=? AND state IN ('owed','not_sent')",
          [old['id']],
        );
      }
    });
  }

  Future<List<Map<String, Object?>>> _protectedEpisodes(
    DatabaseExecutor executor,
  ) => executor.rawQuery(
    // V1 history is frozen. V2 decisions remain correctable by v3; freezing
    // every older detector would preserve the stale semantic debt fixed here.
    'SELECT DISTINCT e.* FROM pulse_episode e JOIN pulse_episode_revision r '
    'ON r.episode_id=e.id WHERE r.detector < ? ORDER BY e.id',
    [2],
  );

  Future<PulseEpisodeSnapshot?> get(String episodeId) async {
    var id = episodeId;
    final seen = <String>{};
    while (seen.add(id)) {
      final aliases = await db.query(
        'pulse_episode_alias',
        where: 'alias = ?',
        whereArgs: [id],
      );
      if (aliases.isEmpty) break;
      id = aliases.first['episode_id'] as String;
    }
    final rows = await db.rawQuery(
      '''SELECT e.*, a.state AS alert_state,a.reason AS alert_reason,
      a.at_ms AS alert_at_ms FROM pulse_episode e LEFT JOIN pulse_episode_outbox a ON a.episode_id=e.id
      WHERE e.id=?''',
      [id],
    );
    if (rows.isEmpty) return null;
    final evidence = await db.query(
      'pulse_evidence_chunk',
      where: 'episode_id = ? AND revision = ?',
      whereArgs: [id, rows.first['revision']],
    );
    Map<String, dynamic>? decoded;
    if (evidence.isNotEmpty) {
      final payload = evidence.first['payload'];
      if (payload is! List<int>) throw StateError('Pulse recording is corrupt');
      final List<int> bytes = payload;
      final expected = rows.first['revision'] as String;
      decoded = (await Isolate.run(
        () => decodePulseEvidenceHeavy(bytes, expected),
      )).document;
    }
    return PulseEpisodeSnapshot(rows.first, decoded);
  }

  Future<List<PulseEpisodeSnapshot>> list({
    int limit = 30,
    int? beforeMs,
    String beforeId = '',
  }) async {
    final rows = await db.rawQuery(
      "SELECT e.*,a.state AS alert_state,a.reason AS alert_reason,a.at_ms AS alert_at_ms "
      "FROM pulse_episode e LEFT JOIN pulse_episode_outbox a ON a.episode_id=e.id "
      "WHERE e.status='active' ${beforeMs == null ? '' : 'AND (e.start_ms < ? OR (e.start_ms = ? AND e.id < ?))'} "
      "ORDER BY e.start_ms DESC,e.id DESC LIMIT ?",
      [
        if (beforeMs != null) ...[beforeMs, beforeMs, beforeId],
        limit,
      ],
    );
    return [for (final r in rows) PulseEpisodeSnapshot(r, null)];
  }

  /// Quiet hours hold only unclaimed debt. Keep this reason durable so the
  /// first later pass can present silently without changing consumed ancestry.
  Future<void> deferQuiet() async {
    await db.rawUpdate(
      "UPDATE pulse_episode_outbox SET reason='quiet hours' "
      "WHERE episode_id IN (SELECT id FROM pulse_episode WHERE status='active') "
      "AND (state='owed' OR (state='not_sent' AND reason IN ('notifications off','quiet hours')))",
    );
  }

  Future<List<Map<String, Object?>>> owed() =>
      db.rawQuery('''SELECT a.*, e.start_ms,e.end_ms,e.day,e.offset_min
    FROM pulse_episode_outbox a JOIN pulse_episode e ON e.id=a.episode_id
    WHERE e.status='active' AND (a.state='owed' OR (a.state='not_sent' AND a.reason IN ('notifications off','quiet hours')))
    ORDER BY e.start_ms,e.id''');

  Future<List<String>> claim(
    List<String> ids, {
    required String token,
    required int nowMs,
  }) => db.transaction((txn) async {
    final owned = <String>[];
    for (final id in ids) {
      final evidence = await txn.rawQuery(
        '''SELECT c.payload,a.revision FROM pulse_episode_outbox a
          JOIN pulse_evidence_chunk c ON c.episode_id=a.episode_id AND c.revision=a.revision
          WHERE a.episode_id=?''',
        [id],
      );
      if (evidence.isEmpty ||
          evidence.first['payload'] is! List<int> ||
          sha256.convert(evidence.first['payload'] as List<int>).toString() !=
              evidence.first['revision']) {
        continue;
      }
      if (await txn.rawUpdate(
            "UPDATE pulse_episode_outbox SET state='pending',token=?,at_ms=? "
            "WHERE episode_id=? AND (state='owed' OR (state='not_sent' AND reason IN ('notifications off','quiet hours')))",
            [token, nowMs, id],
          ) ==
          1) {
        owned.add(id);
      }
    }
    return owned;
  });
  Future<void> finish(
    List<String> ids, {
    required String token,
    required String state,
    String? reason,
    String? summaryKey,
    required int nowMs,
  }) => db.transaction((txn) async {
    for (final id in ids) {
      await txn.update(
        'pulse_episode_outbox',
        {
          'state': state,
          'reason': reason,
          'at_ms': nowMs,
          'summary_key': summaryKey,
        },
        where: "episode_id = ? AND token = ? AND state = 'pending'",
        whereArgs: [id, token],
      );
    }
  });
  Future<void> recoverClaims({required int beforeMs}) => db.rawUpdate(
    "UPDATE pulse_episode_outbox SET state='unknown',reason='delivery unknown' WHERE state='pending' AND at_ms < ?",
    [beforeMs],
  );

  /// Only evidence is bounded. Raw/decoded and small delivery tombstones are untouched.
  Future<void> retain({
    required int nowMs,
    int budgetBytes = pulseEvidenceBudget,
  }) => db.transaction((txn) async {
    // Sizes and dates only: the payloads can be megabytes each (rule B8).
    final rows = await txn.query(
      'pulse_evidence_chunk',
      columns: ['episode_id', 'revision', 'byte_count', 'created_ms'],
      orderBy: 'created_ms ASC,episode_id,revision',
    );
    var bytes = rows.fold<int>(0, (s, r) => s + (r['byte_count'] as int));
    for (final r in rows) {
      if ((r['created_ms'] as int) >= nowMs - pulseEvidenceDays * 86400000 &&
          bytes <= budgetBytes) {
        continue;
      }
      final pending = await txn.query(
        'pulse_episode_outbox',
        where: "episode_id=? AND revision=? AND state='pending'",
        whereArgs: [r['episode_id'], r['revision']],
      );
      if (pending.isNotEmpty) continue;
      await txn.delete(
        'pulse_evidence_chunk',
        where: 'episode_id=? AND revision=?',
        whereArgs: [r['episode_id'], r['revision']],
      );
      await txn.update(
        'pulse_episode_revision',
        {'evidence_status': 'expired'},
        where: 'episode_id=? AND revision=?',
        whereArgs: [r['episode_id'], r['revision']],
      );
      await txn.rawUpdate(
        "UPDATE pulse_episode_outbox SET state='not_sent',reason='recording expired' WHERE episode_id=? AND state='owed'",
        [r['episode_id']],
      );
      bytes -= r['byte_count'] as int;
    }
  });
}

/// @heavy: bounded evidence encoding runs away from the UI isolate.
@heavy
Map<String, dynamic> encodePulseEvidenceHeavy(Map<String, dynamic> input) {
  WorkerInit.ensure(
    const WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en'),
  );
  assertWorker();
  final all = (input['context'] as List? ?? input['beats'] as List)
      .cast<Map<String, dynamic>>();
  all.sort((a, b) => (a['time'] as int).compareTo(b['time'] as int));
  final byId = {for (final b in all) b['id'] as String: b};
  final unique = byId.values.toList();
  final jumps =
      unique
          .where(
            (b) =>
                b['change'] != null &&
                b['adjacent'] == true &&
                (b['time'] as int) >= input['start'] &&
                (b['time'] as int) < input['end'] &&
                ((b['labels'] as List).contains('suddenLong') ||
                    (b['labels'] as List).contains('suddenShort')) &&
                b['dropped'] != true,
          )
          .toList()
        ..sort((a, b) {
          final d = (b['change'] as num).abs().compareTo(
            (a['change'] as num).abs(),
          );
          return d != 0 ? d : (a['time'] as int).compareTo(b['time'] as int);
        });
  final biggest = jumps.take(5).toList()
    ..sort((a, b) => (a['time'] as int).compareTo(b['time'] as int));
  var kept = unique;
  var partial = false;
  if (kept.length > 20000) {
    partial = true;
    final priority = unique
        .where(
          (b) =>
              (b['time'] as int) < input['start'] + 60000 ||
              (b['time'] as int) > input['end'] - 60000 ||
              biggest.any(
                (j) => ((b['time'] as int) - (j['time'] as int)).abs() < 16000,
              ),
        )
        .take(20000)
        .toList();
    final keys = priority.map((b) => b['id']).toSet();
    kept = [
      ...priority,
      ...unique
          .where((b) => !keys.contains(b['id']))
          .take(20000 - priority.length),
    ]..sort((a, b) => (a['time'] as int).compareTo(b['time'] as int));
  }
  final overview = <Map<String, dynamic>>[];
  final bins = <int, List<double>>{};
  for (final b in unique) {
    if (b['plausible'] != true ||
        b['corrected'] == true ||
        b['dropped'] == true) {
      continue;
    }
    (bins[(b['time'] as int) ~/ 30000 * 30000] ??= []).add(
      (b['raw'] as num).toDouble(),
    );
  }
  for (final time in bins.keys.toList()..sort()) {
    final v = bins[time]!..sort();
    overview.add({
      'time': time + 15000,
      'lo': v[((v.length - 1) * .1).floor()],
      'median': v[((v.length - 1) * .5).floor()],
      'hi': v[((v.length - 1) * .9).floor()],
      'count': v.length,
    });
  }
  final windows = (input['windows'] as List).take(4096).toList();
  final rawEpisode =
      (input['beats'] as List)
          .cast<Map<String, dynamic>>()
          .where((b) => b['plausible'] == true)
          .toList()
        ..sort((a, b) => (a['raw'] as num).compareTo(b['raw'] as num));
  final summary = {...input}
    ..remove('beats')
    ..remove('context')
    ..remove('comparison')
    ..remove('heartRate');
  summary['windows'] = windows;
  Map<String, dynamic> document() => {
    ...summary,
    'schema': 1,
    'partial': partial,
    'beats': kept,
    'overview': overview.take(4096).toList(),
    'jumps': biggest,
    'comparison': input['comparison'] ?? [],
    'heartRate': (input['heartRate'] as List? ?? []).take(960).toList(),
    'extremes': rawEpisode.isEmpty
        ? null
        : {'shortest': rawEpisode.first, 'longest': rawEpisode.last},
    'omissions': [
      if (kept.isNotEmpty &&
          (kept.first['time'] as int) > (unique.first['time'] as int))
        {
          'from': unique.first['time'],
          'to': kept.first['time'],
          'reason': 'evidence limit',
        },
      if (kept.isNotEmpty &&
          (kept.last['time'] as int) < (unique.last['time'] as int))
        {
          'from': kept.last['time'],
          'to': unique.last['time'],
          'reason': 'evidence limit',
        },
      for (var i = 1; i < kept.length; i++)
        if ((kept[i]['index'] as int) > (kept[i - 1]['index'] as int) + 1)
          {
            'from': kept[i - 1]['time'],
            'to': kept[i]['time'],
            'reason': 'evidence limit or missing recording',
          },
    ],
  };
  var payload = gzip.encode(utf8.encode(jsonEncode(document())));
  while (payload.length > 1024 * 1024 && kept.length > 100) {
    partial = true;
    kept = kept.take(kept.length ~/ 2).toList();
    payload = gzip.encode(utf8.encode(jsonEncode(document())));
  }
  if (payload.length > 1024 * 1024) {
    throw StateError('Pulse evidence exceeds byte cap');
  }
  return {
    'payload': payload,
    'checksum': sha256.convert(payload).toString(),
    'summary': jsonEncode(summary),
    'partial': partial,
  };
}

@SendableShape(
  'Immutable analytics evidence and primitive HR maps; sendable_preparePulseEvidenceHeavy_test',
)
class PulsePreparationInput {
  final ana.PulseDetection detection;
  final List<Map<String, dynamic>> heartRate;
  const PulsePreparationInput(this.detection, this.heartRate);
}

@SendableShape(
  'Bounded compressed byte arrays and primitive summary maps; sendable_preparePulseEvidenceHeavy_test',
)
class PulsePreparedEvidence {
  final Map<String, Map<String, dynamic>> episodes;
  const PulsePreparedEvidence(this.episodes);
}

/// Revision of context inputs that are not indexed by the raw 15-minute buckets.
Future<String> pulseContextRevision(DatabaseExecutor db) async {
  final events = await db.rawQuery(
    "SELECT COALESCE(SUM(rev),0) AS rev FROM input_revision WHERE source='events'",
  );
  final sleep = await db.rawQuery(
    "SELECT COALESCE(SUM(rev),0) AS rev FROM row_rev WHERE kind='day_result'",
  );
  final episodes = await db.rawQuery(
    'SELECT DISTINCT source,start_ms,end_ms FROM pulse_episode '
    'ORDER BY source,start_ms,end_ms',
  );
  final episodeStamp = sha256.convert(utf8.encode(jsonEncode(episodes)));
  return '${events.first['rev']}:${sleep.first['rev']}:$episodeStamp';
}

@sendable
class PulseInputStamp {
  final int startBucket, endBucket, revision;
  final String? contextRevision;
  const PulseInputStamp(
    this.startBucket,
    this.endBucket,
    this.revision, {
    this.contextRevision,
  });
}

@heavy
PulsePreparedEvidence preparePulseEvidenceHeavy(PulsePreparationInput request) {
  WorkerInit.ensure(
    const WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en'),
  );
  assertWorker();
  WorkerAudit.entered('preparePulseEvidenceHeavy');
  final detection = request.detection, heartRate = request.heartRate;
  final prepared = <String, Map<String, dynamic>>{};
  for (final episode in detection.episodes) {
    final input = episode.toJson();
    final comparison = detection.windows
        .where(
          (w) =>
              w.source == episode.source &&
              !w.pending &&
              !w.qualified &&
              w.reasons.isEmpty &&
              w.endMs <= episode.startMs &&
              w.endMs >= episode.startMs - 600000,
        )
        .toList();
    input['comparison'] = comparison.isEmpty
        ? <dynamic>[]
        : [for (final b in comparison.last.beats) b.toJson()];
    input['context'] = [
      for (final w in detection.windows)
        if (w.source == episode.source &&
            w.endMs > episode.startMs - 600000 &&
            w.startMs < episode.endMs + 600000)
          for (final b in w.beats) b.toJson(),
    ];
    input['heartRate'] = heartRate
        .where(
          (r) =>
              r['source'] == episode.source &&
              (r['time'] as num) >= episode.startMs - 8 * 3600000 &&
              (r['time'] as num) < episode.startMs + 8 * 3600000,
        )
        .take(960)
        .toList();
    prepared[episode.id] = encodePulseEvidenceHeavy(input);
  }

  return PulsePreparedEvidence(prepared);
}

@SendableShape(
  'Decoded bounded JSON recording; sendable_decodePulseEvidenceHeavy_test',
)
class PulseEvidenceDocument {
  final Map<String, dynamic> document;
  const PulseEvidenceDocument(this.document);
}

@heavy
PulseEvidenceDocument decodePulseEvidenceHeavy(
  List<int> payload,
  String expected,
) {
  WorkerInit.ensure(
    const WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en'),
  );
  assertWorker();
  WorkerAudit.entered('decodePulseEvidenceHeavy');
  if (sha256.convert(payload).toString() != expected) {
    throw StateError('Pulse recording checksum mismatch');
  }
  return PulseEvidenceDocument(
    (jsonDecode(utf8.decode(gzip.decode(payload))) as Map)
        .cast<String, dynamic>(),
  );
}
