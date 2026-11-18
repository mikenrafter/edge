// Pulse episode store on real SQLite: one write transaction, stable identity,
// consumed outcomes, retention and the admission/checkpoint lifecycle.
// CLAIM(pulse-evidence-atomic) CLAIM(pulse-input-revision) CLAIM(pulse-no-realert)
// CLAIM(pulse-upgrade-membership) CLAIM(pulse-prune-floor) CLAIM(pulse-admission-bound)
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_codec.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_store.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_types.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'backup/backup_support.dart';
import 'pulse_ep_support.dart';

const _min = 60000;
const _t0 = 1794000000000; // aligned to nothing in particular; only differences matter
const _day = '2026-11-10';

PulseEncoded _enc({String sum = 'sum-a', int bytes = 3, String episode = 's:0'}) => PulseEncoded(
  bytes: Uint8List.fromList(List.filled(bytes, 7)),
  checksum: sum,
  retainedJson: '[[$_t0,${_t0 + 10 * _min}]]',
  omittedJson: '[]',
  expandedBytes: bytes,
  evidence: PulseEvidence(
    episodeId: episode, source: 's', startMs: _t0, endMs: _t0 + 10 * _min,
    ongoing: false, beats: const [],
  ),
);

PulsePublication _pub({
  String id = 's:0',
  String source = 's',
  int start = 0,
  int end = 10,
  int? seed,
  bool eligible = true,
  String origin = 'recentSync',
  List<int>? keys,
  List<PulseWindowSupport>? windows,
  PulseEncoded? evidence,
  bool noEvidence = false,
  int detector = 4,
  int now = 5000,
  String sum = 'sum-a',
}) => PulsePublication(
  episodeId: id,
  source: source,
  seedStartMs: _t0 + (seed ?? start) * _min,
  seedEndMs: _t0 + ((seed ?? start) + 10) * _min,
  startMs: _t0 + start * _min,
  endMs: _t0 + end * _min,
  ongoing: false,
  startDay: _day,
  endDay: _day,
  detector: detector,
  algo: 126,
  alertEligible: eligible,
  origin: origin,
  summaryJson: '{"windows":2}',
  evidence: noEvidence ? null : (evidence ?? _enc(sum: sum, episode: id)),
  supportKeysMs: keys ?? [_t0 + start * _min],
  windowSupport: windows ?? [
    PulseWindowSupport(startMs: _t0 + start * _min, endMs: _t0 + (start + 5) * _min,
        qualified: true, preUpgradeQualified: false, novelRecords: 300),
    PulseWindowSupport(startMs: _t0 + (start + 5) * _min, endMs: _t0 + (start + 10) * _min,
        qualified: true, preUpgradeQualified: false, novelRecords: 300),
  ],
  nowMs: now,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late Database db;
  setUpAll(() async => env = await BackupEnv.create('pulse-ep-store.db'));
  tearDownAll(() async => env.dispose());
  setUp(() async {
    await env.wipe();
    SharedPreferences.setMockInitialValues({});
    db = await LocalDb.instance;
  });

  Future<PulseApply> publish(PulsePublication p) async {
    final stamp = await PulseEpisodeStore.readStamp(db,
        source: p.source, fromMs: p.startMs - 10 * _min, toMs: p.endMs + 10 * _min);
    return PulseEpisodeStore.publish(db, p, expected: stamp);
  }

  Future<Map<String, Object?>> outbox(String id) async =>
      (await pulseRows(db, 'pulse_ep_outbox', where: 'episode_id = ?', whereArgs: [id])).single;

  // WHY/CLAIM(pulse-evidence-atomic): the episode, its revision, its evidence
  // and its alert debt commit together or not at all.
  test('a publication writes episode, revision, evidence and debt together', () async {
    final r = await publish(_pub());
    expect(r, isA<PulseApplied>());
    final ep = (await pulseRows(db, 'pulse_ep_episode')).single;
    expect(ep['id'], 's:0');
    expect(ep['status'], 'active');
    expect(ep['revision'], 1);
    expect(ep['first_seen_ms'], 5000);
    expect((await pulseRows(db, 'pulse_ep_revision')).single['evidence_status'], 'available');
    expect((await pulseRows(db, 'pulse_ep_evidence')).single['payload'], [7, 7, 7]);
    final o = await outbox('s:0');
    expect(o['state'], 'owed');
    expect(o['delivery_key'], 'pulse-episode:s:0');
    expect(o['origin'], 'recentSync');
    expect(o['debt_ms'], 5000);
  });

  // WHY: disk-full or a write failure must not leave an alert owed without
  // the evidence that justifies it.
  test('an evidence write failure rolls back the episode and the debt', () async {
    await pulseRows(db, 'pulse_ep_evidence'); // table exists
    await db.execute('DROP TABLE pulse_ep_evidence');
    final r = await publish(_pub());
    expect(r, isA<PulseFailed>());
    expect(await pulseRows(db, 'pulse_ep_episode'), isEmpty);
    expect(await pulseRows(db, 'pulse_ep_outbox'), isEmpty);
    expect(await pulseRows(db, 'pulse_ep_revision'), isEmpty);
  });

  // WHY/CLAIM(pulse-input-revision): a late record that lands between the
  // read and the commit must refuse the stale decision.
  test('a changed input revision refuses the publication and writes nothing', () async {
    final p = _pub();
    final stamp = await PulseEpisodeStore.readStamp(db,
        source: 's', fromMs: p.startMs - 10 * _min, toMs: p.endMs + 10 * _min);
    final sec = (_t0 + 3 * _min) ~/ 1000;
    await db.insert('decoded_onehz',
        {'device_id': 's', 'ts_ms': sec * 1000, 'rec_ts': sec, 'counter': 1, 'hr': 60});
    final r = await PulseEpisodeStore.publish(db, p, expected: stamp);
    expect(r, isA<PulseRefused>());
    expect((r as PulseRefused).reason, contains('input'));
    expect(await pulseRows(db, 'pulse_ep_episode'), isEmpty);
  });

  test('a changed store generation refuses the publication', () async {
    final p = _pub();
    final stamp = await PulseEpisodeStore.readStamp(db,
        source: 's', fromMs: p.startMs, toMs: p.endMs);
    await db.execute('UPDATE pulse_ep_upgrade SET generation = generation + 1');
    expect(await PulseEpisodeStore.publish(db, p, expected: stamp), isA<PulseRefused>());
    expect(await pulseRows(db, 'pulse_ep_episode'), isEmpty);
  });

  test('publishing identical content again is Unchanged', () async {
    await publish(_pub());
    expect(await publish(_pub(now: 9000)), isA<PulseUnchanged>());
    expect((await pulseRows(db, 'pulse_ep_episode')).single['revision'], 1);
    expect(await pulseRows(db, 'pulse_ep_revision'), hasLength(1));
  });

  // WHY/CLAIM(pulse-no-realert): extension keeps the identity, first-seen time
  // and the consumed outcome; only the content revision moves.
  test('an extension keeps id, first-seen time and a consumed outcome', () async {
    await publish(_pub());
    await db.execute("UPDATE pulse_ep_outbox SET state='sent', handoff_ms=6000");
    final r = await publish(_pub(end: 20, sum: 'sum-b', now: 9000));
    expect((r as PulseApplied).revision, 2);
    final ep = (await pulseRows(db, 'pulse_ep_episode')).single;
    expect(ep['first_seen_ms'], 5000);
    expect(ep['end_ms'], _t0 + 20 * _min);
    expect(await pulseRows(db, 'pulse_ep_outbox'), hasLength(1));
    final o = await outbox('s:0');
    expect(o['state'], 'sent');
    expect(o['debt_ms'], 5000, reason: 'debt creation time is never renewed');
    expect(o['revision'], 1, reason: 'the delivered revision stays the one that was announced');
  });

  // WHY: shrink then regrow must not reset the consumed outcome.
  test('shrink and regrowth cannot reset a consumed outcome', () async {
    await publish(_pub(end: 20));
    await db.execute("UPDATE pulse_ep_outbox SET state='sent'");
    await publish(_pub(end: 10, sum: 'b', now: 6000));
    await publish(_pub(end: 25, sum: 'c', now: 7000));
    expect((await outbox('s:0'))['state'], 'sent');
    expect(await pulseRows(db, 'pulse_ep_episode'), hasLength(1));
    // Even a later pass that finds the recording poor cannot rewrite what was sent.
    await publish(_pub(end: 25, sum: 'd', eligible: false, now: 8000));
    final o = await outbox('s:0');
    expect((o['state'], o['reason'], o['revision']), ('sent', null, 1));
  });

  // WHY/CLAIM(pulse-no-realert): an algorithm-only regrouping of handled input
  // creates no new debt, and needs no alias table.
  test('a regrouped episode over consumed input owes nothing', () async {
    await publish(_pub(id: 's:0', start: 0, end: 30));
    await db.execute("UPDATE pulse_ep_outbox SET state='sent'");
    // Starts later than the old seed, so it is a different id over handled input.
    await publish(_pub(id: 's:10', start: 10, end: 40, keys: [_t0 + 12 * _min]));
    final o = await outbox('s:10');
    expect(PulseDelivery.parse(o['state']).consumed, isTrue);
    expect(PulseDelivery.parse(o['state']), isNot(PulseDelivery.owed));
  });

  test('a separate new episode with new support is owed', () async {
    await publish(_pub(id: 's:0', start: 0, end: 10));
    await db.execute("UPDATE pulse_ep_outbox SET state='sent'");
    await publish(_pub(id: 's:120', start: 120, end: 135, keys: [_t0 + 121 * _min]));
    expect((await outbox('s:120'))['state'], 'owed');
  });

  // WHY/CLAIM(pulse-upgrade-membership): an episode supported ONLY by records
  // that existed at the upgrade takes terminal "before this version" handling.
  test('R5 entirely pre-upgrade is before_version; one new key is insufficient', () async {
    await db.insert('pulse_ep_upgrade_record', {'source': 's', 'ts_ms': _t0});
    await db.insert('pulse_ep_upgrade_record', {'source': 's', 'ts_ms': _t0 + 1000});
    await publish(_pub(id: 's:0', keys: [_t0, _t0 + 1000]));
    expect((await outbox('s:0'))['state'], 'before_version');
    await publish(_pub(id: 's:200', start: 200, end: 210, windows: const [], keys: [_t0 + 200 * _min, _t0 + 1000]));
    expect((await outbox('s:200'))['state'], 'not_sent');
  });

  test('membership is per source: another source key does not suppress', () async {
    await db.insert('pulse_ep_upgrade_record', {'source': 'other', 'ts_ms': _t0});
    await publish(_pub(id: 's:0', keys: [_t0]));
    expect((await outbox('s:0'))['state'], 'owed');
  });

  test('a recording-quality episode is not sent, with the reason', () async {
    await publish(_pub(eligible: false));
    final o = await outbox('s:0');
    expect(o['state'], 'not_sent');
    expect(o['reason'], 'recording quality');
  });

  // WHY: a semantic retraction cancels owed debt but never un-sends.
  test('retraction cancels owed debt and keeps a sent record', () async {
    await publish(_pub(id: 's:0'));
    await publish(_pub(id: 's:90', start: 90, end: 100, keys: [_t0 + 91 * _min]));
    await db.execute("UPDATE pulse_ep_outbox SET state='sent' WHERE episode_id = 's:90'");
    expect(await PulseEpisodeStore.retract(db, 's:0', reason: 'motion', nowMs: 8000),
        isA<PulseApplied>());
    expect(await PulseEpisodeStore.retract(db, 's:90', reason: 'motion', nowMs: 8000),
        isA<PulseApplied>());
    final eps = {for (final r in await pulseRows(db, 'pulse_ep_episode')) r['id']: r};
    expect(eps['s:0']!['status'], 'retracted');
    expect((await outbox('s:0'))['state'], 'not_sent');
    expect((await outbox('s:0'))['reason'], 'retracted');
    expect((await outbox('s:90'))['state'], 'sent');
    expect(await PulseEpisodeStore.retract(db, 'missing', reason: 'x', nowMs: 1),
        isA<PulseRefused>());
  });

  test('a retracted episode that qualifies again is active and owed again if never consumed', () async {
    await publish(_pub());
    await PulseEpisodeStore.retract(db, 's:0', reason: 'motion', nowMs: 8000);
    await publish(_pub(sum: 'again', now: 9000));
    expect((await pulseRows(db, 'pulse_ep_episode')).single['status'], 'active');
    expect((await outbox('s:0'))['state'], 'owed');
  });

  // WHY: poor current evidence is a refusal, not proof of normal rhythm.
  test('a refusal keeps the previous decision and records why', () async {
    await publish(_pub());
    expect(await PulseEpisodeStore.recordRefusal(db, 's:0', reason: 'incomplete support'),
        isA<PulseApplied>());
    final ep = (await pulseRows(db, 'pulse_ep_episode')).single;
    expect(ep['status'], 'active');
    expect(ep['refusal'], 'incomplete support');
    expect((await outbox('s:0'))['state'], 'owed');
  });

  test('v1 stored decisions are protected from a v4 rewrite', () async {
    await publish(_pub(detector: 1));
    final r = await publish(_pub(detector: 4, sum: 'v4', now: 9000));
    expect(r, isA<PulseRefused>());
    expect((await pulseRows(db, 'pulse_ep_revision')).single['checksum'], 'sum-a');
  });

  test('a deleted recording is a tombstone: a new publication over it is refused', () async {
    await publish(_pub());
    await db.execute("UPDATE pulse_ep_episode SET status='deleted'");
    final r = await publish(_pub(sum: 'z', now: 9000));
    expect(r, isA<PulseRefused>());
    expect((await pulseRows(db, 'pulse_ep_revision')).single['checksum'], 'sum-a');
    expect((await pulseRows(db, 'pulse_ep_episode')).single['status'], 'deleted');
  });

  // WHY/R4: omitted evidence must never back dispatchable alert debt.
  // catches: forwarding alertEligible despite a null evidence envelope.
  test('R4 evidence omitted cannot create dispatchable debt', () async {
    await publish(_pub(noEvidence: true));
    expect((await pulseRows(db, 'pulse_ep_revision')).single['evidence_status'], 'omitted');
    expect(await pulseRows(db, 'pulse_ep_evidence'), isEmpty);
    expect((await outbox('s:0'))['state'], 'not_sent');
    expect((await outbox('s:0'))['reason'], contains('evidence'));
  });

  // ---- admission, checkpoint, prune -------------------------------------
  Future<void> admit(int startSec, int endSec, {String digest = 'd', int now = 1}) =>
      db.insert('pulse_ep_admission', {
        'source': 's', 'start_ms': startSec * 1000, 'end_ms': endSec * 1000, 'digest': digest,
        'records': 1, 'novel': 1, 'origin': 'recentSync', 'admitted_ms': now, 'historical': 0,
      });

  test('a checkpoint advances only forward and counts the batches it consumed', () async {
    await admit(100, 200);
    await admit(300, 400, digest: 'e');
    final stamp = await PulseEpisodeStore.readStamp(db, source: 's', fromMs: 0, toMs: 500000);
    expect(await PulseEpisodeStore.advanceCheckpoint(db,
        source: 's', throughMs: 250000, stamp: stamp, detector: 4, nowMs: 9), 1);
    expect(await pulseRows(db, 'pulse_ep_admission'), hasLength(2),
        reason: 'consumed batches wait for decoded retention to prune them');
    expect((await pulseRows(db, 'pulse_ep_checkpoint')).single['through_ms'], 250000);
    await PulseEpisodeStore.advanceCheckpoint(db,
        source: 's', throughMs: 100000, stamp: stamp, detector: 4, nowMs: 10);
    expect((await pulseRows(db, 'pulse_ep_checkpoint')).single['through_ms'], 250000,
        reason: 'the watermark never moves backwards');
  });

  // WHY (spec 4.2): while scheduling is disabled nothing was refused, so no
  // refused:unsupported row exists and unevaluated batches simply age out.
  test('with scheduling off, pruning drops old batches and writes no refusal', () async {
    await admit(100, 200);
    await db.transaction((t) async {
      expect(await PulseEpisodeStore.pruneAdmissions(t,
          cutoffMs: 1000000, hardFloorMs: 500, holdEnabled: false), 1);
    });
    expect(await pulseRows(db, 'pulse_ep_admission'), isEmpty);
    expect(await pulseRows(db, 'pulse_ep_checkpoint'), isEmpty);
  });

  // WHY/CLAIM(pulse-prune-floor): enabled, an unevaluated batch is HELD past the
  // cutoff, and only at the 14-day floor does it become a durable refusal that
  // is written before the batch disappears.
  test('with scheduling on, an unevaluated batch is held until the floor, then refused durably', () async {
    await admit(100, 200);
    await db.transaction((t) async {
      expect(await PulseEpisodeStore.pruneAdmissions(t,
          cutoffMs: 1000000, hardFloorMs: 50000, holdEnabled: true), 0);
    });
    expect(await pulseRows(db, 'pulse_ep_admission'), hasLength(1));
    await db.transaction((t) async {
      expect(await PulseEpisodeStore.pruneAdmissions(t,
          cutoffMs: 1000000, hardFloorMs: 300000, holdEnabled: true), 1);
    });
    expect(await pulseRows(db, 'pulse_ep_admission'), isEmpty);
    final cp = (await pulseRows(db, 'pulse_ep_checkpoint')).single;
    expect(cp['refused_json'], contains('unsupported'));
    expect(cp['refused_json'], contains('100000'));
  });

  test('an evaluated batch is pruned at the cutoff even when scheduling is on', () async {
    await admit(100, 200);
    final stamp = await PulseEpisodeStore.readStamp(db, source: 's', fromMs: 0, toMs: 1);
    await PulseEpisodeStore.advanceCheckpoint(db,
        source: 's', throughMs: 250000, stamp: stamp, detector: 4, nowMs: 9);
    await admit(100, 200, digest: 'late', now: 20);
    await db.transaction((t) async {
      await PulseEpisodeStore.pruneAdmissions(t,
          cutoffMs: 1000000, hardFloorMs: 50000, holdEnabled: true);
    });
    expect(await pulseRows(db, 'pulse_ep_admission'), hasLength(1),
        reason: 'only the evaluated batch went; the later unevaluated one is held');
  });

  // ---- retention -----------------------------------------------------------
  const day = 86400000;
  test('evidence older than 365 days expires; the header, revision and outcome survive', () async {
    await seedEpisode(db, id: 's:old', source: 's', startMs: _t0, endMs: _t0 + _min,
        startDay: _day, state: 'sent', createdMs: _t0 - 400 * day);
    await seedEpisode(db, id: 's:new', source: 's', startMs: _t0 + 5 * _min, endMs: _t0 + 6 * _min,
        startDay: _day, state: 'sent', createdMs: _t0 - 10 * day);
    final n = await PulseEpisodeStore.enforceRetention(db, nowMs: _t0);
    expect(n, 1);
    expect([for (final r in await pulseRows(db, 'pulse_ep_evidence')) r['episode_id']], ['s:new']);
    final rev = {for (final r in await pulseRows(db, 'pulse_ep_revision')) r['episode_id']: r};
    expect(rev['s:old']!['evidence_status'], 'expired');
    expect(rev['s:new']!['evidence_status'], 'available');
    expect(await pulseRows(db, 'pulse_ep_episode'), hasLength(2));
    expect((await outbox('s:old'))['state'], 'sent');
  });

  // WHY (spec 4.6): pressure expires the oldest unpinned evidence, and a live
  // pending claim's evidence is never evicted mid-handoff.
  test('the evidence budget evicts oldest unpinned first and never a pending claim', () async {
    for (final e in [('s:a', 'sent', 1), ('s:b', 'pending', 2), ('s:c', 'sent', 3)]) {
      await seedEpisode(db, id: e.$1, source: 's', startMs: _t0 + e.$3 * _min, endMs: _t0 + e.$3 * _min + _min,
          startDay: _day, state: e.$2, createdMs: _t0 - (10 - e.$3) * day,
          payload: List.filled(100, 1));
    }
    final n = await PulseEpisodeStore.enforceRetention(db, nowMs: _t0, budgetBytes: 220);
    expect(n, 1);
    final left = {for (final r in await pulseRows(db, 'pulse_ep_evidence')) r['episode_id']};
    expect(left, {'s:b', 's:c'}, reason: 'oldest unpinned (s:a) goes; pending s:b stays');
    await PulseEpisodeStore.enforceRetention(db, nowMs: _t0, budgetBytes: 100);
    expect({for (final r in await pulseRows(db, 'pulse_ep_evidence')) r['episode_id']}, {'s:b'});
  });

  // ---- upgrade capture (store-level) ----------------------------------------
  test('capture tolerates an absent decoded_rr and fails on a malformed one', () async {
    final scratch = await openDatabase(inMemoryDatabasePath, singleInstance: false);
    await scratch.execute('CREATE TABLE decoded_other(x INTEGER)');
    await scratch.transaction((t) async {
      await PulseEpisodeStore.createTables(t);
      await PulseEpisodeStore.captureUpgrade(t, nowMs: 1);
    });
    expect(await pulseRows(scratch, 'pulse_ep_upgrade'), hasLength(1));
    expect(await pulseRows(scratch, 'pulse_ep_upgrade_record'), isEmpty);

    final broken = await openDatabase(inMemoryDatabasePath, singleInstance: false);
    await broken.execute('CREATE TABLE decoded_rr(unrelated INTEGER)');
    await expectLater(
      broken.transaction((t) async {
        await PulseEpisodeStore.createTables(t);
        await PulseEpisodeStore.captureUpgrade(t, nowMs: 1);
      }),
      throwsA(anything),
    );
    expect(await broken.rawQuery(
        "SELECT name FROM sqlite_master WHERE name = 'pulse_ep_upgrade'"),
        isEmpty, reason: 'the failed capture rolled back with its tables');
  });

  test('capture is idempotent and never overwrites an initialized marker', () async {
    final scratch = await openDatabase(inMemoryDatabasePath, singleInstance: false);
    await scratch.execute('''CREATE TABLE decoded_rr(device_id TEXT NOT NULL DEFAULT '',
      ts_ms INTEGER NOT NULL DEFAULT 0, beat_index INTEGER NOT NULL,
      PRIMARY KEY(device_id, ts_ms, beat_index))''');
    await scratch.insert('decoded_rr', {'device_id': '', 'ts_ms': 1000, 'beat_index': 0});
    await scratch.transaction((t) async {
      await PulseEpisodeStore.createTables(t);
      await PulseEpisodeStore.captureUpgrade(t, nowMs: 10);
    });
    await scratch.insert('decoded_rr', {'device_id': '', 'ts_ms': 2000, 'beat_index': 0});
    await scratch.transaction((t) => PulseEpisodeStore.captureUpgrade(t, nowMs: 99));
    expect((await pulseRows(scratch, 'pulse_ep_upgrade')).single['recorded_ms'], 10);
    expect(await pulseRows(scratch, 'pulse_ep_upgrade_record'), hasLength(1));
  });

  // ---- admission recording, unit level --------------------------------------
  test('recordAdmission counts novelty by (device, record) before replacement', () async {
    await seedRr(db, 's', 100, 2);
    await db.transaction((t) async {
      final a = await PulseEpisodeStore.recordAdmission(t,
          source: 's',
          records: const [
            PulseAdmittedRecord(100000, [800, 810]), // stored
            PulseAdmittedRecord(101000, [790]), // new
          ],
          origin: ProcessingOrigin.recentSync,
          nowMs: 5);
      expect((a.records, a.novel), (2, 1));
    });
    expect((await pulseRows(db, 'pulse_ep_admission')).single['novel'], 1);
  });

  // ---- completeness ---------------------------------------------------------
  // WHY: a certificate names its range and its holes; it must not pledge more.
  test('a certificate stores range, holes and generation; a hole outside it is refused', () async {
    expect(await PulseEpisodeStore.certifyComplete(db,
        source: 's', startMs: 1000, endMs: 9000,
        holes: const [PulseRange(2000, 3000)], nowMs: 5), isA<PulseApplied>());
    final row = (await pulseRows(db, 'pulse_ep_complete')).single;
    expect((row['start_ms'], row['end_ms'], row['holes_json']), (1000, 9000, '[[2000,3000]]'));
    expect(await PulseEpisodeStore.certifyComplete(db,
        source: 's', startMs: 1000, endMs: 9000,
        holes: const [PulseRange(8000, 9500)], nowMs: 6), isA<PulseRefused>());
    expect(await PulseEpisodeStore.certifyComplete(db,
        source: 's', startMs: 5000, endMs: 5000, holes: const [], nowMs: 6), isA<PulseRefused>());
    expect(await pulseRows(db, 'pulse_ep_complete'), hasLength(1));
  });

  // WHY: a new certificate changes the stamp, so a decision prepared against the
  // old coverage cannot publish.
  test('certifying completeness invalidates a prepared decision', () async {
    final p = _pub();
    final stamp = await PulseEpisodeStore.readStamp(db,
        source: 's', fromMs: p.startMs, toMs: p.endMs);
    await PulseEpisodeStore.certifyComplete(db,
        source: 's', startMs: p.startMs, endMs: p.endMs, holes: const [], nowMs: 7);
    expect(await PulseEpisodeStore.publish(db, p, expected: stamp), isA<PulseRefused>());
  });

  // WHY (checklist 2): a hand-edited or newer-version state string degrades to
  // unknown, which is consumed: it can never become a second alert.
  test('an unknown stored delivery state is consumed and never owed', () {
    expect(PulseDelivery.parse('from-a-newer-build'), PulseDelivery.unknown);
    expect(PulseDelivery.parse(null), PulseDelivery.unknown);
    expect(PulseDelivery.parse('from-a-newer-build').consumed, isTrue);
    expect(PulseDelivery.parse('owed'), PulseDelivery.owed);
    expect(PulseDelivery.owed.consumed, isFalse);
    expect(PulseDelivery.held.consumed, isFalse);
    expect(PulseDelivery.notSent.consumed, isFalse);
    expect(PulseDelivery.pending.consumed, isTrue);
  });
  // WHY/R3: an old range must not refresh authority over a later replacement.
  // catches: max(old watermark, new end) paired with a fresh wall-clock time.
  test('R3 older evaluation cannot consume a replacement beyond its range', () async {
    await admit(100, 200);
    var stamp = await PulseEpisodeStore.readStamp(db, source: 's', fromMs: 0, toMs: 300000);
    await PulseEpisodeStore.advanceCheckpoint(db,
        source: 's', throughMs: 300000, stamp: stamp, detector: 4, nowMs: 10);
    await admit(100, 200, digest: 'replacement', now: 20);
    stamp = await PulseEpisodeStore.readStamp(db, source: 's', fromMs: 0, toMs: 100000);
    await PulseEpisodeStore.advanceCheckpoint(db,
        source: 's', throughMs: 100000, stamp: stamp, detector: 4, nowMs: 30);
    await db.transaction((txn) => PulseEpisodeStore.pruneAdmissions(txn,
        cutoffMs: 400000, hardFloorMs: 0, holdEnabled: true));
    final left = await pulseRows(db, 'pulse_ep_admission');
    expect(left.map((r) => r['digest']), ['replacement']);
  });

  // WHY/R3: even a zero-episode pass must recheck its admission snapshot.
  // catches: checkpointing new input that arrived after the worker's read.
  test('R3 checkpoint refuses a late admission and leaves it unconsumed', () async {
    final stamp = await PulseEpisodeStore.readStamp(db, source: 's', fromMs: 0, toMs: 300000);
    await admit(100, 200);
    await expectLater(PulseEpisodeStore.advanceCheckpoint(db,
        source: 's', throughMs: 300000, stamp: stamp, detector: 4, nowMs: 10),
        throwsA(anything));
    expect(await pulseRows(db, 'pulse_ep_checkpoint'), isEmpty);
  });

}
