// Owner: PulseEpisodeStore owns every write to the `pulse_ep_*` tables:
// episodes, revisions, evidence, alert debt, admission batches, checkpoints and
// the upgrade boundary. Preparation (analytics, encoding) runs elsewhere; this
// class only rechecks stamps and writes, in ONE transaction per publication.
// No foreign key points at a prunable signal table.
//
// Delivery itself (claims, handoff) is phase 3. Phase 2 creates and preserves
// the debt rows and never enables production scheduling ([schedulingEnabled]).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../../compute/processing_context.dart';
import 'pulse_ep_codec.dart';
import 'pulse_ep_types.dart';

const int kPulseEvidenceBudgetBytes = 128 * 1024 * 1024;
const int kPulseEvidenceDays = 365;

/// Every table, creation-order. Dependants first when deleting.
const List<String> kPulseEpTableNames = [
  'pulse_ep_episode',
  'pulse_ep_revision',
  'pulse_ep_evidence',
  'pulse_ep_outbox',
  'pulse_ep_admission',
  'pulse_ep_checkpoint',
  'pulse_ep_complete',
  'pulse_ep_upgrade',
  'pulse_ep_upgrade_record',
];

/// One pulse-bearing record of a committed batch: its second (epoch ms) and RR.
class PulseAdmittedRecord {
  const PulseAdmittedRecord(this.tsMs, this.rr);
  final int tsMs;
  final List<int> rr;
}

class PulseAdmission {
  const PulseAdmission({required this.records, required this.novel});
  final int records, novel;
}

/// What a prepared decision was computed from. Rechecked inside the write
/// transaction; any difference refuses the publication (CLAIM(pulse-input-revision)).
class PulseStamp {
  const PulseStamp({
    required this.inputRev,
    required this.context,
    required this.generation,
    this.source = '',
    this.admissionThrough = 0,
    this.admissionCount = 0,
    this.fromMs = 0,
    this.toMs = 0,
  });
  final int inputRev, generation, fromMs, toMs, admissionThrough, admissionCount;
  final String context, source;
  String get encoded => '$inputRev|$context|$generation|$admissionThrough:$admissionCount';
  @override
  bool operator ==(Object other) => other is PulseStamp && other.encoded == encoded;
  @override
  int get hashCode => encoded.hashCode;
}

class PulsePublication {
  const PulsePublication({
    required this.episodeId,
    required this.source,
    required this.seedStartMs,
    required this.seedEndMs,
    required this.startMs,
    required this.endMs,
    required this.ongoing,
    required this.startDay,
    required this.endDay,
    required this.detector,
    required this.algo,
    required this.alertEligible,
    required this.origin,
    required this.summaryJson,
    required this.evidence,
    required this.supportKeysMs,
    required this.nowMs,
    this.refusal,
  });
  final String episodeId, source, startDay, endDay, origin, summaryJson;
  final int seedStartMs, seedEndMs, startMs, endMs, detector, algo, nowMs;
  final bool ongoing, alertEligible;

  /// Why the episode is not alert-eligible (recording quality, ...).
  final String? refusal;

  /// Null when no evidence could be kept; the revision is then 'omitted'.
  final PulseEncoded? evidence;

  /// Distinct record seconds (epoch ms) of this source supporting the
  /// qualifying windows; compared with the upgrade membership.
  final List<int> supportKeysMs;
}

/// A rollout boundary could not be captured. Opening must expose this failure:
/// rebuilding would replace the input whose membership we have to preserve.
class PulseUpgradeCaptureFailed implements Exception {
  const PulseUpgradeCaptureFailed(this.cause);
  final Object cause;
  @override
  String toString() => 'Pulse upgrade capture failed: $cause';
}

class PulseEpisodeStore {
  PulseEpisodeStore._();

  /// Small budgets exercise aggregate import admission without large fixtures.
  static int? importBudgetBytesForTest;

  /// Phase 2 ships the storage only. Phase 3 flips this when central routing
  /// and silent recovery exist (spec 4.2/4.4). While false there is no Pulse
  /// retention hold and no refused:unsupported row.
  static const bool schedulingEnabled = false;

  // ---- schema ---------------------------------------------------------------
  /// Idempotent and cheap: DDL only, no scan. Safe in onCreate, the ladder and
  /// the open repair. Literal SQL on purpose (the p21 write seam).
  static Future<void> createTables(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS pulse_ep_episode (
      id TEXT PRIMARY KEY, source TEXT NOT NULL,
      seed_start_ms INTEGER NOT NULL, seed_end_ms INTEGER NOT NULL,
      start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
      ongoing INTEGER NOT NULL DEFAULT 0,
      start_day TEXT NOT NULL, end_day TEXT NOT NULL,
      first_seen_ms INTEGER NOT NULL, revision INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'active', refusal TEXT)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS pulse_ep_revision (
      episode_id TEXT NOT NULL, revision INTEGER NOT NULL,
      detector INTEGER NOT NULL, algo INTEGER NOT NULL, input_stamp TEXT NOT NULL,
      summary_json TEXT NOT NULL, evidence_status TEXT NOT NULL,
      checksum TEXT NOT NULL, created_ms INTEGER NOT NULL,
      PRIMARY KEY(episode_id, revision))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS pulse_ep_evidence (
      episode_id TEXT NOT NULL, revision INTEGER NOT NULL, payload BLOB NOT NULL,
      encoded_bytes INTEGER NOT NULL, expanded_bytes INTEGER NOT NULL,
      checksum TEXT NOT NULL DEFAULT '', retained_json TEXT NOT NULL, omitted_json TEXT NOT NULL,
      created_ms INTEGER NOT NULL, PRIMARY KEY(episode_id, revision))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS pulse_ep_outbox (
      episode_id TEXT PRIMARY KEY, delivery_key TEXT NOT NULL UNIQUE,
      revision INTEGER NOT NULL, state TEXT NOT NULL, reason TEXT,
      origin TEXT NOT NULL, debt_ms INTEGER NOT NULL, source_ms INTEGER NOT NULL,
      token TEXT, claim_ms INTEGER, targets TEXT, handoff_ms INTEGER)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS pulse_ep_admission (
      source TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
      digest TEXT NOT NULL, records INTEGER NOT NULL, novel INTEGER NOT NULL,
      origin TEXT NOT NULL, admitted_ms INTEGER NOT NULL,
      historical INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(source, start_ms, end_ms, digest))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS pulse_ep_checkpoint (
      source TEXT PRIMARY KEY, through_ms INTEGER NOT NULL,
      detector INTEGER NOT NULL, stamp TEXT NOT NULL,
      refused_json TEXT NOT NULL DEFAULT '[]', updated_ms INTEGER NOT NULL)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS pulse_ep_complete (
      source TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
      generation INTEGER NOT NULL, holes_json TEXT NOT NULL DEFAULT '[]',
      certified_ms INTEGER NOT NULL, PRIMARY KEY(source, start_ms))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS pulse_ep_upgrade (
      id INTEGER PRIMARY KEY CHECK(id = 1), recorded_ms INTEGER NOT NULL,
      generation INTEGER NOT NULL DEFAULT 0)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS pulse_ep_upgrade_record (
      source TEXT NOT NULL, ts_ms INTEGER NOT NULL, PRIMARY KEY(source, ts_ms))''');
    // Short-lived per-batch completion belongs to admission, never record keys.
    final admissionColumns = await db.rawQuery('PRAGMA table_info(pulse_ep_admission)');
    if (!admissionColumns.any((c) => c['name'] == 'evaluated')) {
      await db.execute('ALTER TABLE pulse_ep_admission ADD COLUMN evaluated INTEGER NOT NULL DEFAULT 0');
    }
    await db.execute('CREATE INDEX IF NOT EXISTS pulse_ep_episode_time ON pulse_ep_episode(start_ms, id)');
    await db.execute('CREATE INDEX IF NOT EXISTS pulse_ep_episode_day ON pulse_ep_episode(start_day, end_day)');
    await db.execute('CREATE INDEX IF NOT EXISTS pulse_ep_evidence_age ON pulse_ep_evidence(created_ms)');
    await db.execute('CREATE INDEX IF NOT EXISTS pulse_ep_admission_end ON pulse_ep_admission(source, end_ms)');
  }

  /// Tables, then the boundary if the marker is missing. The one entry point
  /// for fresh create, the upgrade rung and open repair.
  static Future<void> initialize(DatabaseExecutor db, {required int nowMs}) async {
    try {
      await createTables(db);
      await captureUpgrade(db, nowMs: nowMs);
    } catch (error, stack) {
      Error.throwWithStackTrace(PulseUpgradeCaptureFailed(error), stack);
    }
  }

  /// The upgrade boundary: the exact `(source, record second)` keys present
  /// NOW, snapshotted server-side (no Dart rows, no detector, no JSON), then the
  /// immutable marker. The caller supplies the transaction; any failure
  /// propagates so keys, marker and tables roll back together.
  ///
  /// CLAIM(pulse-upgrade-membership): the keys are identities, not a time
  /// cutoff, so an older record that arrives after the upgrade is still new
  /// [pulse_ep_migration_test].
  static Future<void> captureUpgrade(DatabaseExecutor db, {required int nowMs}) async {
    if ((await db.rawQuery('SELECT 1 FROM pulse_ep_upgrade LIMIT 1')).isNotEmpty) return;
    // A sparse legacy database can predate decoded storage; the open repair
    // creates it afterwards. Absent means no keys, never "malformed".
    final hasRr = (await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'decoded_rr'",
    )).isNotEmpty;
    if (hasRr) {
      await db.execute(
        'INSERT OR IGNORE INTO pulse_ep_upgrade_record(source, ts_ms) '
        'SELECT DISTINCT device_id, ts_ms FROM decoded_rr',
      );
    }
    await db.execute(
      'INSERT INTO pulse_ep_upgrade(id, recorded_ms, generation) VALUES (1, ?, 0)',
      [nowMs],
    );
  }

  // ---- admission --------------------------------------------------------------
  /// One durable batch per committed source range, written INSIDE the sync
  /// transaction and BEFORE the decoded rows are replaced, so novelty is exact.
  /// Throws on failure: the caller's transaction (decoded rows, cursor) rolls
  /// back and nothing is ACKed without its provenance.
  static Future<PulseAdmission> recordAdmission(
    DatabaseExecutor txn, {
    required String source,
    required List<PulseAdmittedRecord> records,
    required ProcessingOrigin origin,
    required int nowMs,
  }) async {
    final bearing = [
      for (final r in records)
        if (r.rr.isNotEmpty) r,
    ]..sort((a, b) => a.tsMs.compareTo(b.tsMs));
    if (bearing.isEmpty) return const PulseAdmission(records: 0, novel: 0);
    final ts = [for (final r in bearing) r.tsMs];
    // How many of these records this phone already knows by identity: stored
    // decoded, or present at the upgrade. One scalar per chunk, no row walk.
    var known = 0;
    for (var i = 0; i < ts.length; i += 400) {
      final part = ts.sublist(i, i + 400 < ts.length ? i + 400 : ts.length);
      final marks = List.filled(part.length, '?').join(',');
      known += Sqflite.firstIntValue(await txn.rawQuery(
            'SELECT COUNT(*) FROM (SELECT ts_ms FROM decoded_rr WHERE device_id = ? AND ts_ms IN ($marks) '
            'UNION SELECT ts_ms FROM pulse_ep_upgrade_record WHERE source = ? AND ts_ms IN ($marks))',
            [source, ...part, source, ...part],
          )) ??
          0;
    }
    final novel = bearing.length - known;
    final canonical = StringBuffer();
    for (final r in bearing) {
      canonical
        ..write(r.tsMs)
        ..write(':')
        ..writeAll(r.rr, ',')
        ..write('\n');
    }
    final digest = sha256.convert(utf8.encode(canonical.toString())).toString();
    await txn.rawInsert(
      'INSERT OR IGNORE INTO pulse_ep_admission(source, start_ms, end_ms, digest, '
      'records, novel, origin, admitted_ms, historical) VALUES (?,?,?,?,?,?,?,?,?)',
      [
        source,
        bearing.first.tsMs,
        bearing.last.tsMs + 1000,
        digest,
        bearing.length,
        novel,
        origin.name,
        nowMs,
        origin != ProcessingOrigin.recentSync || novel == 0 ? 1 : 0,
      ],
    );
    return PulseAdmission(records: bearing.length, novel: novel);
  }

  /// Commits this snapshot's evaluation/refusals. Only admission batches wholly
  /// covered by this range are consumed; an older pass cannot certify a newer
  /// replacement behind a prior watermark. Throws if the snapshot raced or the
  /// range would leave a gap in the watermark.
  static Future<int> advanceCheckpoint(
    Database db, {
    required String source,
    required int throughMs,
    required PulseStamp stamp,
    required int detector,
    required int nowMs,
    int? fromMs,
    String refusedJson = '[]',
  }) => db.transaction((txn) async {
    final current = await readStamp(txn,
        source: source, fromMs: stamp.fromMs, toMs: stamp.toMs);
    if (current != stamp) throw StateError('Pulse evaluation snapshot changed');
    final start = fromMs ?? stamp.fromMs;
    final prior = await txn.query('pulse_ep_checkpoint',
        where: 'source = ?', whereArgs: [source], limit: 1);
    if (prior.isNotEmpty && start > (prior.first['through_ms'] as int)) {
      throw StateError('Pulse evaluation leaves a checkpoint gap');
    }
    await txn.rawUpdate(
      'UPDATE pulse_ep_admission SET evaluated = 1 WHERE source = ? '
      'AND start_ms >= ? AND end_ms <= ? AND rowid <= ?',
      [source, start, throughMs, stamp.admissionThrough],
    );
    if (prior.isEmpty) {
      await txn.insert('pulse_ep_checkpoint', {
        'source': source, 'through_ms': throughMs, 'detector': detector,
        'stamp': stamp.encoded, 'refused_json': refusedJson, 'updated_ms': nowMs,
      });
    } else {
      final refusals = [
        ...jsonDecode(prior.first['refused_json'] as String) as List,
        ...jsonDecode(refusedJson) as List,
      ];
      await txn.update('pulse_ep_checkpoint', {
        if (throughMs > (prior.first['through_ms'] as int)) ...{
          'through_ms': throughMs, 'detector': detector,
          'stamp': stamp.encoded, 'updated_ms': nowMs,
        },
        'refused_json': jsonEncode(refusals),
      }, where: 'source = ?', whereArgs: [source]);
    }
    return Sqflite.firstIntValue(await txn.rawQuery(
          'SELECT COUNT(*) FROM pulse_ep_admission WHERE source = ? AND evaluated = 1',
          [source],
        )) ?? 0;
  });

  /// Prunes admission batches with decoded retention. Consumed batches go at
  /// [cutoffMs]. Scheduling off: the rest go too, with no refusal (nothing was
  /// refused; nothing ran). Scheduling on: an unconsumed batch is held until the
  /// existing 14-day floor [hardFloorMs]; at the floor its range is first
  /// recorded as refused:unsupported in the checkpoint, then the batch goes.
  static Future<int> pruneAdmissions(
    DatabaseExecutor txn, {
    required int cutoffMs,
    required int hardFloorMs,
    bool holdEnabled = schedulingEnabled,
  }) async {
    var deleted = await txn.rawDelete(
      'DELETE FROM pulse_ep_admission WHERE end_ms <= ? AND evaluated = 1',
      [cutoffMs],
    );
    if (!holdEnabled) {
      return deleted +
          await txn.rawDelete('DELETE FROM pulse_ep_admission WHERE end_ms <= ?', [cutoffMs]);
    }
    final stuck = await txn.rawQuery(
      'SELECT source, start_ms, end_ms, digest FROM pulse_ep_admission WHERE end_ms <= ?',
      [hardFloorMs < cutoffMs ? hardFloorMs : cutoffMs],
    );
    final bySource = <String, List<Map<String, Object?>>>{};
    for (final r in stuck) {
      (bySource[r['source'] as String] ??= []).add(r);
    }
    for (final e in bySource.entries) {
      final cp = await txn.query('pulse_ep_checkpoint',
          where: 'source = ?', whereArgs: [e.key], limit: 1);
      final refused = cp.isEmpty
          ? <Object?>[]
          : (jsonDecode(cp.first['refused_json'] as String) as List).toList();
      for (final r in e.value) {
        refused.add({'start': r['start_ms'], 'end': r['end_ms'], 'reason': 'refused:unsupported'});
      }
      // The refusal is durable BEFORE any batch disappears; a failed write
      // throws and rolls the whole prune back.
      final refusedJson = jsonEncode(refused);
      await txn.rawInsert(
        'INSERT OR IGNORE INTO pulse_ep_checkpoint(source, through_ms, detector, stamp, refused_json, updated_ms) '
        "VALUES (?, 0, 0, '', ?, 0)",
        [e.key, refusedJson],
      );
      await txn.rawUpdate(
        'UPDATE pulse_ep_checkpoint SET refused_json = ? WHERE source = ?',
        [refusedJson, e.key],
      );
      for (final r in e.value) {
        deleted += await txn.rawDelete(
          'DELETE FROM pulse_ep_admission WHERE source = ? AND start_ms = ? AND end_ms = ? AND digest = ?',
          [e.key, r['start_ms'], r['end_ms'], r['digest']],
        );
      }
    }
    return deleted;
  }

  // ---- stamps ---------------------------------------------------------------------
  static Future<PulseStamp> readStamp(
    DatabaseExecutor db, {
    required String source,
    required int fromMs,
    required int toMs,
  }) async {
    final input = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COALESCE(SUM(rev), 0) FROM input_rev WHERE bucket BETWEEN ? AND ?',
          [fromMs ~/ 900000, toMs ~/ 900000],
        )) ??
        0;
    final events = Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COALESCE(SUM(rev), 0) FROM input_revision WHERE source = 'events'",
        )) ??
        0;
    final sleep = Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COALESCE(SUM(rev), 0) FROM row_rev WHERE kind = 'day_result'",
        )) ??
        0;
    final complete = await db.rawQuery(
      'SELECT COUNT(*) AS n, COALESCE(SUM(generation), 0) AS g, COALESCE(MAX(certified_ms), 0) AS m '
      'FROM pulse_ep_complete WHERE source = ?',
      [source],
    );
    final gen = Sqflite.firstIntValue(
            await db.rawQuery('SELECT generation FROM pulse_ep_upgrade WHERE id = 1')) ??
        0;
    final admission = (await db.rawQuery(
      'SELECT COALESCE(MAX(rowid), 0) AS last, COUNT(*) AS n FROM pulse_ep_admission WHERE source = ?',
      [source],
    )).single;
    return PulseStamp(
      admissionThrough: admission['last'] as int,
      admissionCount: admission['n'] as int,
      inputRev: input,
      context: '$events:$sleep:${complete.first['n']}:${complete.first['g']}:${complete.first['m']}',
      generation: gen,
      source: source,
      fromMs: fromMs,
      toMs: toMs,
    );
  }

  // ---- publication ----------------------------------------------------------------
  static const _regroupedReason = 'regrouped input';

  /// One transaction: recheck the stamp, resolve stable identity, write the
  /// episode, its revision and evidence, and create or preserve the debt.
  /// CLAIM(pulse-evidence-atomic) CLAIM(pulse-no-realert)
  static Future<PulseApply> publish(
    Database db,
    PulsePublication p, {
    required PulseStamp expected,
    int budgetBytes = kPulseEvidenceBudgetBytes,
  }) async {
    try {
      return await db.transaction((txn) async {
        final now = await readStamp(txn,
            source: p.source, fromMs: expected.fromMs, toMs: expected.toMs);
        if (now != expected) {
          return const PulseRefused('input changed since this decision was prepared');
        }
        final overlapping = await txn.rawQuery(
          'SELECT e.*, r.detector AS cur_detector, r.checksum AS cur_checksum FROM pulse_ep_episode e '
          'LEFT JOIN pulse_ep_revision r ON r.episode_id = e.id AND r.revision = e.revision '
          'WHERE e.source = ? AND ((e.start_ms < ? AND e.end_ms > ?) OR e.id = ?)',
          [p.source, p.endMs, p.startMs, p.episodeId],
        );
        if (overlapping.any((e) => e['status'] == 'deleted')) {
          return const PulseRefused('recording deleted');
        }
        var id = p.episodeId;
        Map<String, Object?>? existing;
        for (final e in overlapping) {
          if (e['id'] == id) existing = e;
        }
        if (existing == null) {
          // An existing episode whose seed lies inside this one hands over its
          // identity; this is stable identity, not an alias.
          final heirs = [
            for (final e in overlapping)
              if ((e['seed_start_ms'] as int) >= p.startMs && (e['seed_start_ms'] as int) < p.endMs) e,
          ]..sort((a, b) {
              final s = (a['seed_start_ms'] as int).compareTo(b['seed_start_ms'] as int);
              return s != 0 ? s : (a['id'] as String).compareTo(b['id'] as String);
            });
          if (heirs.isNotEmpty) {
            existing = heirs.first;
            id = existing['id'] as String;
          }
        }
        if (existing != null &&
            existing['cur_detector'] == 1 &&
            p.detector >= 2) {
          return const PulseRefused('stored v1 decision is protected from a rewrite');
        }
        final checksum = p.evidence?.checksum ??
            'omitted:${sha256.convert(utf8.encode('${p.summaryJson}|${p.startMs}|${p.endMs}')).toString()}';
        if (existing != null &&
            existing['status'] == 'active' &&
            existing['cur_checksum'] == checksum &&
            existing['end_ms'] == p.endMs &&
            existing['start_ms'] == p.startMs &&
            (existing['ongoing'] == 1) == p.ongoing) {
          return PulseUnchanged(id);
        }
        // Budget: evict the oldest unpinned evidence first; refuse rather than
        // exceed the cap.
        final enc = p.evidence;
        if (enc != null) {
          final used = Sqflite.firstIntValue(
                  await txn.rawQuery('SELECT COALESCE(SUM(encoded_bytes), 0) FROM pulse_ep_evidence')) ??
              0;
          if (used + enc.encodedBytes > budgetBytes) {
            await _evictToBudget(txn, budgetBytes - enc.encodedBytes);
            final after = Sqflite.firstIntValue(
                    await txn.rawQuery('SELECT COALESCE(SUM(encoded_bytes), 0) FROM pulse_ep_evidence')) ??
                0;
            if (after + enc.encodedBytes > budgetBytes) {
              return const PulseRefused('evidence budget is full of pinned recordings');
            }
          }
        }
        final revision = existing == null ? 1 : (existing['revision'] as int) + 1;
        final status = enc == null
            ? PulseEvidenceStatus.omitted
            : enc.evidence.partial
                ? PulseEvidenceStatus.partial
                : PulseEvidenceStatus.available;
        await txn.insert('pulse_ep_revision', {
          'episode_id': id,
          'revision': revision,
          'detector': p.detector,
          'algo': p.algo,
          'input_stamp': expected.encoded,
          'summary_json': p.summaryJson,
          'evidence_status': status.wire,
          'checksum': checksum,
          'created_ms': p.nowMs,
        });
        if (enc != null) {
          await txn.insert('pulse_ep_evidence', {
            'episode_id': id,
            'revision': revision,
            'payload': enc.bytes,
            'encoded_bytes': enc.encodedBytes,
            'expanded_bytes': enc.expandedBytes,
            'checksum': enc.checksum,
            'retained_json': enc.retainedJson,
            'omitted_json': enc.omittedJson,
            'created_ms': p.nowMs,
          });
        }
        final row = {
          'source': p.source,
          'start_ms': p.startMs,
          'end_ms': p.endMs,
          'ongoing': p.ongoing ? 1 : 0,
          'start_day': p.startDay,
          'end_day': p.endDay,
          'revision': revision,
          'status': 'active',
          'refusal': enc == null ? (p.refusal ?? 'evidence unavailable') : p.refusal,
        };
        if (existing == null) {
          await txn.insert('pulse_ep_episode', {
            'id': id,
            'seed_start_ms': p.seedStartMs,
            'seed_end_ms': p.seedEndMs,
            'first_seen_ms': p.nowMs,
            ...row,
          });
        } else {
          await txn.update('pulse_ep_episode', row, where: 'id = ?', whereArgs: [id]);
        }
        await _writeDebt(txn, p, id, revision, existing == null, overlapping);
        await _dropSupersededEvidence(txn, id);
        return PulseApplied(id, revision, created: existing == null);
      });
    } catch (e) {
      return PulseFailed(e);
    }
  }

  static Future<void> _writeDebt(
    DatabaseExecutor txn,
    PulsePublication p,
    String id,
    int revision,
    bool created,
    List<Map<String, Object?>> overlapping,
  ) async {
    final rows = await txn.query('pulse_ep_outbox',
        where: 'episode_id = ?', whereArgs: [id], limit: 1);
    final eligible = p.alertEligible && p.evidence != null;
    final eligibleState = eligible ? PulseDelivery.owed : PulseDelivery.notSent;
    final eligibleReason = eligible ? null :
        (p.refusal ?? (p.evidence == null ? 'evidence unavailable' : 'recording quality'));
    if (rows.isNotEmpty) {
      final cur = rows.first;
      final state = PulseDelivery.parse(cur['state']);
      if (state.consumed) return; // an outcome is never reset or re-versioned
      final reason = cur['reason'];
      final reopen = state == PulseDelivery.notSent &&
          (reason == 'retracted' || reason == 'recording quality' ||
              (reason is String && reason.startsWith('evidence unavailable')));
      final next = state == PulseDelivery.held
          ? (eligible ? PulseDelivery.held : PulseDelivery.notSent)
          : (state == PulseDelivery.owed || reopen)
              ? eligibleState
              : state;
      await txn.update(
        'pulse_ep_outbox',
        {
          'revision': revision,
          'state': next.wire,
          if (next != state || reopen) 'reason': next == eligibleState ? eligibleReason : cur['reason'],
        },
        where: 'episode_id = ?',
        whereArgs: [id],
      );
      return;
    }
    // New debt. Handled input never creates new debt: an overlapping episode
    // with a consumed outcome, or support made only of pre-upgrade records.
    PulseDelivery state = eligibleState;
    String? reason = eligibleReason;
    for (final o in overlapping) {
      final prior = await txn.query('pulse_ep_outbox',
          where: 'episode_id = ?', whereArgs: [o['id']], limit: 1);
      if (prior.isNotEmpty && PulseDelivery.parse(prior.first['state']).consumed) {
        state = PulseDelivery.parse(prior.first['state']);
        reason = _regroupedReason;
        break;
      }
    }
    if (state == eligibleState && await _allPreUpgrade(txn, p.source, p.supportKeysMs)) {
      state = PulseDelivery.beforeVersion;
      reason = 'before this version';
    }
    await txn.insert('pulse_ep_outbox', {
      'episode_id': id,
      'delivery_key': 'pulse-episode:$id',
      'revision': revision,
      'state': state.wire,
      'reason': reason,
      'origin': p.origin,
      'debt_ms': p.nowMs,
      'source_ms': p.endMs,
    });
  }

  static Future<bool> _allPreUpgrade(
      DatabaseExecutor txn, String source, List<int> keys) async {
    if (keys.isEmpty) return false;
    final distinct = keys.toSet().toList();
    var found = 0;
    for (var i = 0; i < distinct.length; i += 400) {
      final part = distinct.sublist(i, i + 400 < distinct.length ? i + 400 : distinct.length);
      found += Sqflite.firstIntValue(await txn.rawQuery(
            'SELECT COUNT(*) FROM pulse_ep_upgrade_record WHERE source = ? AND ts_ms IN '
            '(${List.filled(part.length, '?').join(',')})',
            [source, ...part],
          )) ??
          0;
    }
    return found == distinct.length;
  }

  /// Keep only the current revision's evidence and the revision actually
  /// delivered (spec 4.6). Revision headers (digests, status) stay.
  static Future<void> _dropSupersededEvidence(DatabaseExecutor txn, String id) async {
    await txn.rawUpdate(
      "UPDATE pulse_ep_revision SET evidence_status = 'expired' WHERE episode_id = ? AND revision IN ("
      'SELECT v.revision FROM pulse_ep_evidence v WHERE v.episode_id = ? '
      'AND v.revision <> (SELECT revision FROM pulse_ep_episode WHERE id = ?) '
      "AND v.revision <> COALESCE((SELECT revision FROM pulse_ep_outbox WHERE episode_id = ? AND state IN "
      "('pending','unknown','sent','summary')), -1))",
      [id, id, id, id],
    );
    await txn.rawDelete(
      'DELETE FROM pulse_ep_evidence WHERE episode_id = ? '
      'AND revision <> (SELECT revision FROM pulse_ep_episode WHERE id = ?) '
      "AND revision <> COALESCE((SELECT revision FROM pulse_ep_outbox WHERE episode_id = ? AND state IN "
      "('pending','unknown','sent','summary')), -1)",
      [id, id, id],
    );
  }

  // ---- semantic outcomes ------------------------------------------------------------
  /// Complete late evidence says the episode no longer qualifies. Cancels
  /// unclaimed debt, keeps a consumed outcome, sends nothing.
  static Future<PulseApply> retract(
    Database db,
    String episodeId, {
    required String reason,
    required int nowMs,
  }) async {
    try {
      return await db.transaction((txn) async {
        final rows = await txn.query('pulse_ep_episode',
            where: 'id = ?', whereArgs: [episodeId], limit: 1);
        if (rows.isEmpty) return const PulseRefused('unknown episode');
        if (rows.first['status'] == 'deleted') return const PulseRefused('recording deleted');
        await txn.update('pulse_ep_episode', {'status': 'retracted', 'refusal': reason},
            where: 'id = ?', whereArgs: [episodeId]);
        final out = await txn.query('pulse_ep_outbox',
            where: 'episode_id = ?', whereArgs: [episodeId], limit: 1);
        if (out.isNotEmpty && !PulseDelivery.parse(out.first['state']).consumed) {
          await txn.update('pulse_ep_outbox',
              {'state': PulseDelivery.notSent.wire, 'reason': 'retracted'},
              where: 'episode_id = ?', whereArgs: [episodeId]);
        }
        return PulseApplied(episodeId, rows.first['revision'] as int, created: false);
      });
    } catch (e) {
      return PulseFailed(e);
    }
  }

  /// Current reanalysis could not be supported. The last supported decision
  /// stays; the refusal is recorded, never read as "normal timing".
  static Future<PulseApply> recordRefusal(
    Database db,
    String episodeId, {
    required String reason,
  }) async {
    try {
      final n = await db.update('pulse_ep_episode', {'refusal': reason},
          where: "id = ? AND status <> 'deleted'", whereArgs: [episodeId]);
      if (n == 0) return const PulseRefused('unknown episode');
      final rev = Sqflite.firstIntValue(await db.rawQuery(
              'SELECT revision FROM pulse_ep_episode WHERE id = ?', [episodeId])) ??
          0;
      return PulseApplied(episodeId, rev, created: false);
    } catch (e) {
      return PulseFailed(e);
    }
  }

  // ---- retention ----------------------------------------------------------------------
  /// 365-day expiry plus the evidence byte budget. Small headers, versions,
  /// routes and consumed outcomes survive; unclaimed debt whose recording
  /// expired becomes not_sent: recording expired. A pending claim's evidence is
  /// never evicted. Returns how many recordings expired.
  static Future<int> enforceRetention(
    Database db, {
    required int nowMs,
    int budgetBytes = kPulseEvidenceBudgetBytes,
  }) => db.transaction((txn) => retainIn(txn, nowMs: nowMs, budgetBytes: budgetBytes));

  /// [enforceRetention] inside a transaction the caller already holds (the
  /// decoded-retention prune runs it in its own).
  static Future<int> retainIn(
    DatabaseExecutor txn, {
    required int nowMs,
    int budgetBytes = kPulseEvidenceBudgetBytes,
  }) async {
    var n = await _expire(
      txn,
      "created_ms < ?",
      [nowMs - kPulseEvidenceDays * 86400000],
    );
    n += await _evictToBudget(txn, budgetBytes);
    return n;
  }

  // ---- completeness -------------------------------------------------------------------
  /// Certifies that [source]'s recording is complete over `[startMs, endMs)`
  /// except the declared [holes], at the committed tail the caller measured
  /// AFTER the history commit (HISTORY_COMPLETE with a durable tail). A bare
  /// maximum timestamp never pledges coverage. A certificate is local authority:
  /// it is not exported and an imported one is never trusted. Overlapping
  /// certificates for the source are replaced by this one.
  static Future<PulseApply> certifyComplete(
    Database db, {
    required String source,
    required int startMs,
    required int endMs,
    required List<PulseRange> holes,
    required int nowMs,
  }) async {
    if (endMs <= startMs) return const PulseRefused('empty range');
    for (final h in holes) {
      if (h.startMs < startMs || h.endMs > endMs) {
        return const PulseRefused('a hole lies outside the certified range');
      }
    }
    try {
      await db.transaction((txn) async {
        await txn.rawDelete(
          'DELETE FROM pulse_ep_complete WHERE source = ? AND start_ms < ? AND end_ms > ?',
          [source, endMs, startMs],
        );
        final generation = Sqflite.firstIntValue(await txn
                .rawQuery('SELECT generation FROM pulse_ep_upgrade WHERE id = 1')) ??
            0;
        await txn.insert('pulse_ep_complete', {
          'source': source,
          'start_ms': startMs,
          'end_ms': endMs,
          'generation': generation,
          'holes_json': jsonEncode([for (final h in holes) [h.startMs, h.endMs]]),
          'certified_ms': nowMs,
        });
      });
      return PulseApplied(source, 0, created: true);
    } catch (e) {
      return PulseFailed(e);
    }
  }

  static Future<int> _expire(DatabaseExecutor txn, String where, List<Object?> args) async {
    final victims = await txn.rawQuery(
      'SELECT v.episode_id, v.revision FROM pulse_ep_evidence v '
      'LEFT JOIN pulse_ep_outbox o ON o.episode_id = v.episode_id '
      "WHERE v.$where AND COALESCE(o.state, '') <> 'pending' "
      'ORDER BY v.created_ms, v.episode_id',
      args,
    );
    return _expireRows(txn, victims);
  }

  static Future<int> _expireRows(DatabaseExecutor txn, List<Map<String, Object?>> victims) async {
    for (final v in victims) {
      await txn.rawDelete(
        'DELETE FROM pulse_ep_evidence WHERE episode_id = ? AND revision = ?',
        [v['episode_id'], v['revision']],
      );
      await txn.rawUpdate(
        "UPDATE pulse_ep_revision SET evidence_status = 'expired' WHERE episode_id = ? AND revision = ?",
        [v['episode_id'], v['revision']],
      );
      await txn.rawUpdate(
        "UPDATE pulse_ep_outbox SET state = 'not_sent', reason = 'recording expired' "
        "WHERE episode_id = ? AND state IN ('owed','held')",
        [v['episode_id']],
      );
    }
    return victims.length;
  }

  static Future<int> _evictToBudget(DatabaseExecutor txn, int budgetBytes) async {
    var used = Sqflite.firstIntValue(
            await txn.rawQuery('SELECT COALESCE(SUM(encoded_bytes), 0) FROM pulse_ep_evidence')) ??
        0;
    if (used <= budgetBytes) return 0;
    final order = await txn.rawQuery(
      'SELECT v.episode_id, v.revision, v.encoded_bytes FROM pulse_ep_evidence v '
      'LEFT JOIN pulse_ep_outbox o ON o.episode_id = v.episode_id '
      "WHERE COALESCE(o.state, '') <> 'pending' ORDER BY v.created_ms, v.episode_id",
    );
    final take = <Map<String, Object?>>[];
    for (final v in order) {
      if (used <= budgetBytes) break;
      take.add(v);
      used -= (v['encoded_bytes'] as num).toInt();
    }
    return _expireRows(txn, take);
  }

  // ---- transport ----------------------------------------------------------------------
  /// Reads one evidence blob in `substr` chunks (an Android cursor window is
  /// about 2 MB; RULES B.8). [source] is any database holding the blob.
  static Future<Uint8List> readPayload(
    DatabaseExecutor source,
    String episodeId,
    int revision,
    int size,
  ) async {
    const chunk = 256 * 1024;
    final out = BytesBuilder(copy: false);
    for (var at = 1; at <= size; at += chunk) {
      final rows = await source.rawQuery(
        'SELECT substr(payload, ?, ?) AS c FROM pulse_ep_evidence WHERE episode_id = ? AND revision = ?',
        [at, chunk, episodeId, revision],
      );
      if (rows.isEmpty) break;
      final part = rows.first['c'];
      if (part is! List<int> || part.isEmpty) break;
      out.add(part);
    }
    return out.takeBytes();
  }

  /// Merges one row of an imported `pulse_ep_*` table (evidence rows arrive with
  /// their payload already read). Stable identities, never
  /// REPLACE: local valid content wins on an equal identity, a consumed outcome
  /// beats an owed one whichever side holds it, another phone's claim is
  /// meaningless here, and what this phone could not have announced becomes a
  /// silent historical summary. Idempotent, so a resumed import re-runs it.
  /// Returns true when the row changed this database.
  static Future<bool> mergeImportedRow(
    DatabaseExecutor txn,
    String table,
    Map<String, Object?> row, {
    PulseImportedRecording? recording,
  }) async {
    switch (table) {
      case 'pulse_ep_episode':
        final changed = (await txn.insert('pulse_ep_episode', row,
                conflictAlgorithm: ConflictAlgorithm.ignore)) > 0;
        if (row['status'] == 'deleted') {
          await _deleteRecording(txn, row['id']);
          return true;
        }
        return changed;
      case 'pulse_ep_revision':
        if (await _isDeleted(txn, row['episode_id'])) return false;
        return (await txn.insert('pulse_ep_revision', row,
                conflictAlgorithm: ConflictAlgorithm.ignore)) >
            0;
      case 'pulse_ep_evidence':
        final id = row['episode_id'], rev = row['revision'];
        if (await _isDeleted(txn, id)) return false;
        final local = await txn.query('pulse_ep_revision',
            columns: ['checksum'],
            where: 'episode_id = ? AND revision = ?',
            whereArgs: [id, rev],
            limit: 1);
        final sum = row['checksum'];
        // The evidence must belong to the revision header this phone holds.
        if (local.isEmpty || sum is! String || sum.isEmpty || local.first['checksum'] != sum) {
          return false;
        }
        if (recording == null) return false;
        if (!recording.available) {
          // Preserve valid local content if the foreign contribution is corrupt.
          final present = await txn.rawQuery(
              'SELECT 1 FROM pulse_ep_evidence WHERE episode_id = ? AND revision = ?', [id, rev]);
          if (present.isEmpty) {
            await txn.update('pulse_ep_revision', {'evidence_status': recording.status.wire},
                where: 'episode_id = ? AND revision = ?', whereArgs: [id, rev]);
            await txn.update('pulse_ep_episode', {'refusal': recording.reason},
                where: 'id = ? AND revision = ?', whereArgs: [id, rev]);
          }
          return false;
        }
        await txn.update('pulse_ep_revision', {'evidence_status': recording.status.wire},
            where: 'episode_id = ? AND revision = ?', whereArgs: [id, rev]);
        return (await txn.insert('pulse_ep_evidence', recording.row,
                conflictAlgorithm: ConflictAlgorithm.ignore)) > 0;
      case 'pulse_ep_outbox':
        return _mergeOutbox(txn, row);
      case 'pulse_ep_admission':
        // A replacement can never carry recent-sync authority from another phone.
        return (await txn.insert('pulse_ep_admission', {...row, 'historical': 1, 'evaluated': 0},
                conflictAlgorithm: ConflictAlgorithm.ignore)) >
            0;
      case 'pulse_ep_upgrade_record':
        return (await txn.insert('pulse_ep_upgrade_record', row,
                conflictAlgorithm: ConflictAlgorithm.ignore)) >
            0;
    }
    return false;
  }

  static Future<bool> _mergeOutbox(DatabaseExecutor txn, Map<String, Object?> row) async {
    var theirs = PulseDelivery.parse(row['state']);
    // A foreign pending claim may have shown an alert: unknown, never retried.
    if (theirs == PulseDelivery.pending) theirs = PulseDelivery.unknown;
    final usable = (await txn.rawQuery(
      'SELECT 1 FROM pulse_ep_revision r JOIN pulse_ep_evidence v '
      'ON v.episode_id = r.episode_id AND v.revision = r.revision '
      "WHERE r.episode_id = ? AND r.revision = ? AND r.evidence_status IN ('available','partial')",
      [row['episode_id'], row['revision']],
    )).isNotEmpty;
    final unavailable = !theirs.consumed && !usable;
    if (unavailable) theirs = PulseDelivery.notSent;
    final imported = {
      ...row,
      if (unavailable) 'reason': 'evidence unavailable',
      'state': theirs.wire,
      'token': null,
      'claim_ms': null,
      if (!theirs.consumed) 'origin': 'historical',
    };
    final mine = await txn.query('pulse_ep_outbox',
        where: 'episode_id = ?', whereArgs: [row['episode_id']], limit: 1);
    if (mine.isEmpty) {
      return (await txn.insert('pulse_ep_outbox', imported,
              conflictAlgorithm: ConflictAlgorithm.ignore)) >
          0;
    }
    final local = PulseDelivery.parse(mine.first['state']);
    if (local.consumed) return false;
    if (theirs.consumed) {
      await txn.update('pulse_ep_outbox', {
        'state': theirs.wire,
        'reason': row['reason'],
        'handoff_ms': row['handoff_ms'],
        'targets': row['targets'],
        'revision': row['revision'],
        'token': null,
        'claim_ms': null,
      }, where: 'episode_id = ?', whereArgs: [row['episode_id']]);
      return true;
    }
    // Both unconsumed: either side's quiet deferral survives.
    if (theirs == PulseDelivery.held && local != PulseDelivery.held) {
      await txn.update('pulse_ep_outbox',
          {'state': PulseDelivery.held.wire, 'reason': row['reason']},
          where: 'episode_id = ?', whereArgs: [row['episode_id']]);
      return true;
    }
    return false;
  }

  static Future<bool> _isDeleted(DatabaseExecutor txn, Object? id) async =>
      (await txn.rawQuery("SELECT 1 FROM pulse_ep_episode WHERE id = ? AND status = 'deleted'", [id])).isNotEmpty;

  // CLAIM(pulse-deletion-import): both local deletion and imported tombstones
  // remove all measurements [R1 transport and resume tests].
  static Future<void> _deleteRecording(DatabaseExecutor txn, Object? id) async {
        await txn.rawDelete('DELETE FROM pulse_ep_evidence WHERE episode_id = ?', [id]);
        await txn.rawDelete('DELETE FROM pulse_ep_revision WHERE episode_id = ?', [id]);
        await txn.rawUpdate(
          "UPDATE pulse_ep_episode SET status = 'deleted', refusal = NULL, ongoing = 0 WHERE id = ?",
          [id],
        );
        await txn.rawUpdate(
          "UPDATE pulse_ep_outbox SET state = 'deleted', reason = 'recording deleted', token = NULL "
          "WHERE episode_id = ? AND state IN ('owed','held','not_sent')",
          [id],
        );
  }

  // ---- deletion --------------------------------------------------------------------------
  /// Deletes every recording that intersects any of [windows] (local day label,
  /// epoch-second start and end). The whole episode goes, including its other-day
  /// portion; only an opaque consumed tombstone stays, so a re-import cannot
  /// re-alert. Upgrade membership keys stay for the same reason. No RR/HR value
  /// survives.
  static Future<void> deleteDays(
    DatabaseExecutor txn,
    List<(String day, int startSec, int endSec)> windows,
  ) async {
    for (final w in windows) {
      final hit = await txn.rawQuery(
        "SELECT id FROM pulse_ep_episode WHERE status <> 'deleted' AND start_day <= ? AND end_day >= ?",
        [w.$1, w.$1],
      );
      for (final e in hit) {
        final id = e['id'];
        await _deleteRecording(txn, id);
      }
      await txn.rawDelete(
        'DELETE FROM pulse_ep_admission WHERE start_ms < ? AND end_ms > ?',
        [w.$3 * 1000, w.$2 * 1000],
      );
    }
    await txn.rawUpdate('UPDATE pulse_ep_upgrade SET generation = generation + 1');
  }

  /// After "delete everything" emptied every table, restore the empty marker so
  /// the next sync is not read as an unbounded pre-upgrade history.
  static Future<void> reinitializeAfterWipe(DatabaseExecutor db, {required int nowMs}) async {
    await createTables(db);
    await captureUpgrade(db, nowMs: nowMs);
  }
}
