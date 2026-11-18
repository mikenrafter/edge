// Pulse worker: detection, evidence and decoding in registered entries, and the
// unscheduled coordinator against real SQLite.
// CLAIM(pulse-closed) CLAIM(pulse-evidence-atomic) CLAIM(pulse-no-realert)
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/pulse_ep_worker.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_codec.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_store.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_types.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import 'backup/backup_support.dart';
import 'pulse_ep_fixture.dart';
import 'pulse_ep_support.dart';

// 2026-11-10 00:00:00 UTC-aligned so five-minute windows line up with minutes.
const _t0 = 1794268800000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('pulse-ep-worker.db'));
  tearDownAll(() async => env.dispose());
  setUp(() async {
    await env.wipe();
    SharedPreferences.setMockInitialValues({});
  });

  final rows = irregularRows(_t0, 25);
  final detectInput = PulseDetectInput(
    source: '',
    rows: rowMaps(rows),
    completeThroughMs: _t0 + 35 * 60000,
    sourceStartMs: _t0 - 3600000,
  );

  // WHY: detection is heavy work; the registered entry must run in another
  // isolate and give the same answer as the direct call.
  test('detection runs in a worker and finds the irregular stretch', () async {
    final detection = (await Isolate.run(() => detectPulseEpisodesHeavy(detectInput))).detection;
    expect(detection.episodes, isNotEmpty);
    final episode = detection.episodes.first;
    expect(episode.windows.length, greaterThanOrEqualTo(2));
    expect(episode.startMs % 300000, 0, reason: 'episodes start on a UTC window');
    final direct = detectPulseEpisodesHeavy(detectInput).detection;
    expect(direct.episodes.map((e) => e.id), detection.episodes.map((e) => e.id));
  });

  // WHY: the detector's own steadiness check, so the fixture is not trivially
  // "irregular": regular beats must produce nothing.
  test('regular beats produce no episode', () async {
    final steady = [
      for (var i = 0; i < 1800; i++)
        ana.PulseBeatInput(
            id: ':${_t0 + i * 800}:0', source: '', index: i, timeMs: _t0 + i * 800, rawMs: 800.0 + (i % 3)),
    ];
    final d = ana.detectPulseEpisodes(steady,
        completeThroughMs: _t0 + 40 * 60000, sourceStartMs: _t0 - 3600000);
    expect(d.episodes, isEmpty);
  });

  test('evidence is typed, keeps ids, and ranks at most five jumps chronologically', () {
    final detection = ana.detectPulseEpisodes(beatInputs('', rows),
        completeThroughMs: _t0 + 35 * 60000, sourceStartMs: _t0 - 3600000);
    final e = detection.episodes.first;
    final ev = buildPulseEvidenceHeavy(e, detection);
    expect(ev.beats.length, e.beats.length);
    final first = e.beats.first;
    expect(ev.beats.first.idIn(''), first.id);
    expect(ev.beats.first.rawMs, first.rawMs);
    expect(ev.jumps.length, lessThanOrEqualTo(5));
    final times = {for (final b in e.beats) b.id: b.timeMs};
    final sorted = [for (final j in ev.jumps) times[j]!];
    expect(sorted, [...sorted]..sort(), reason: 'displayed chronologically');
    expect(ev.windows.length, e.windows.length);
    expect(ev.overview, isNotEmpty);
    for (final bin in ev.overview) {
      expect(bin.p10, lessThanOrEqualTo(bin.median));
      expect(bin.median, lessThanOrEqualTo(bin.p90));
    }
  });

  test('prepare encodes in a worker and decode reads it back in another', () async {
    final detection = ana.detectPulseEpisodes(beatInputs('', rows),
        completeThroughMs: _t0 + 35 * 60000, sourceStartMs: _t0 - 3600000);
    final prepared = await Isolate.run(() => preparePulseEvidenceHeavy(PulsePrepareInput(detection)));
    final enc = prepared.episodes[detection.episodes.first.id]!;
    expect(enc, isA<PulseEncoded>());
    final bytes = (enc as PulseEncoded).bytes;
    final sum = enc.checksum;
    final read = await PulseEpisodeWorker.decode(bytes, sum);
    expect(read, isA<PulseEvidenceAvailable>());
    expect((read as PulseEvidenceAvailable).evidence.beats.length,
        detection.episodes.first.beats.length);
  });

  Future<List<PulseApply>> evaluate(dynamic db, {int now = 1000}) =>
      PulseEpisodeWorker.evaluate(db,
          source: '',
          fromMs: _t0,
          toMs: _t0 + 30 * 60000,
          sourceStartMs: _t0 - 3600000,
          completeThroughMs: _t0 + 35 * 60000,
          origin: 'recentSync',
          nowMs: now);

  // WHY/CLAIM(pulse-evidence-atomic): reading committed beats through the real
  // table, detecting, encoding and publishing leaves one episode with evidence,
  // owed debt and an advanced checkpoint; a second pass changes nothing.
  test('evaluating committed beats publishes once and the second pass is unchanged', () async {
    final db = await LocalDb.instance;
    await insertRows(db, '', rows);
    final first = await evaluate(db);
    expect(first, isNotEmpty);
    expect(first.every((r) => r is PulseApplied), isTrue, reason: '$first');
    final ep = (await pulseRows(db, 'pulse_ep_episode')).first;
    expect(ep['status'], 'active');
    expect((await pulseRows(db, 'pulse_ep_evidence')), hasLength(first.length));
    expect((await pulseRows(db, 'pulse_ep_outbox')).first['state'], 'owed');
    expect((await pulseRows(db, 'pulse_ep_checkpoint')).single['through_ms'], _t0 + 30 * 60000);
    final again = await evaluate(db, now: 2000);
    expect(again.every((r) => r is PulseUnchanged), isTrue, reason: '$again');
    expect(await pulseRows(db, 'pulse_ep_episode'), hasLength(first.length));
  });

  // WHY/CLAIM(pulse-upgrade-membership): the same beats, all present at the
  // upgrade, are history: no new debt.
  test('beats that were present at the upgrade become before_version, not owed', () async {
    final db = await LocalDb.instance;
    await insertRows(db, '', rows);
    for (final r in rows) {
      await db.insert('pulse_ep_upgrade_record', {'source': '', 'ts_ms': r.tsMs},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await evaluate(db);
    expect([for (final o in await pulseRows(db, 'pulse_ep_outbox')) o['state']],
        everyElement('before_version'));
  });

  // WHY: a beat without a modeled position cannot be placed in time, so the
  // detector must refuse it instead of inheriting a fabricated time.
  test('rows with no modeled beat time never qualify', () async {
    final db = await LocalDb.instance;
    for (final r in rows) {
      await db.insert('decoded_rr', {
        'device_id': '', 'ts_ms': r.tsMs, 'rec_ts': r.tsMs ~/ 1000, 'beat_index': r.beatIndex,
        'rr_ts_ms': r.tsMs, 'rr_ms': r.rrMs,
      });
    }
    final out = await evaluate(db);
    expect(out, isEmpty);
    expect(await pulseRows(db, 'pulse_ep_episode'), isEmpty);
  });

  // WHY: phase 2 ships storage only; production must not schedule the worker.
  test('production scheduling is off in phase 2', () {
    expect(PulseEpisodeStore.schedulingEnabled, isFalse);
  });

  test('a stale read is refused: a late beat landing mid-evaluation changes nothing', () async {
    final db = await LocalDb.instance;
    await insertRows(db, '', rows);
    final stamp = await PulseEpisodeStore.readStamp(db, source: '', fromMs: _t0 - 600000, toMs: _t0 + 31 * 60000);
    final detection = ana.detectPulseEpisodes(beatInputs('', rows),
        completeThroughMs: _t0 + 35 * 60000, sourceStartMs: _t0 - 3600000);
    final e = detection.episodes.first;
    await db.insert('decoded_rr', {
      'device_id': '', 'ts_ms': _t0 + 5000, 'rec_ts': (_t0 + 5000) ~/ 1000, 'beat_index': 9,
      'rr_ts_ms': _t0 + 5000, 'beat_ts_ms': _t0 + 5400, 'rr_ms': 900,
    });
    final r = await PulseEpisodeStore.publish(
      db,
      PulsePublication(
        episodeId: e.id, source: '', seedStartMs: e.startMs, seedEndMs: e.windows.first.endMs,
        startMs: e.startMs, endMs: e.endMs, ongoing: false, startDay: '2026-11-10', endDay: '2026-11-10',
        detector: 4, algo: 126, alertEligible: true, origin: 'recentSync', summaryJson: '{}',
        evidence: null, supportKeysMs: const [], nowMs: 1,
      ),
      expected: stamp,
    );
    expect(r, isA<PulseRefused>());
    expect(await pulseRows(db, 'pulse_ep_episode'), isEmpty);
  });
}
