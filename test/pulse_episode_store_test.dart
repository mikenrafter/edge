import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ana.PulseDetection detection({int offset = 0}) {
  final random = Random(17);
  final beats = <ana.PulseBeatInput>[];
  var t = offset.toDouble();
  while (t < offset + 25 * 60000) {
    final rr = 750 + random.nextDouble() * 500;
    t += rr;
    beats.add(
      ana.PulseBeatInput(
        id: '${t.round()}',
        source: 'strap',
        index: beats.length,
        timeMs: t.round(),
        rawMs: rr,
      ),
    );
  }
  return ana.detectPulseEpisodes(
    beats,
    completeThroughMs: offset + 1200000,
    sourceStartMs: offset,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Database db;
  late PulseEpisodeStore store;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp('pulse2-store');
    db = await databaseFactory.openDatabase('${dir.path}/test.db');
    store = PulseEpisodeStore(db);
    await PulseEpisodeStore.create(db);
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  // WHY/CLAIM(pulse-version-history): a new detector cannot rewrite stored decisions.
  // # catches: retracting or revising a previous-version episode during replay.
  test('v1 detector history and delivery remain byte-identical', () async {
    final old = detection();
    await store.reconcile(old, origin: 'sync', nowMs: 1);
    await db.update('pulse_episode_revision', {'detector': 1});
    await db.insert('pulse_episode_alias', {'alias':'previous-alias','episode_id':'strap:0'});
    final claimed = await store.claim(['strap:0'], token: 'previous', nowMs: 2);
    await store.finish(claimed, token: 'previous', state: 'sent', nowMs: 3);
    final before = [for (final table in pulseEpisodeTables.take(5))
      jsonEncode(await db.query(table))];
    final quiet = ana.PulseDetection([
      for (final w in old.windows) ana.PulseWindow(
        source: w.source, startMs: w.startMs, endMs: w.endMs, pairs: w.pairs,
        totalBeats: w.totalBeats, cleanedBeats: w.cleanedBeats,
        coverageMs: w.coverageMs, longestGapMs: w.longestGapMs,
        sd1: w.sd1, sd2: w.sd2, ratio: w.ratio, pnnPct: w.pnnPct,
        pending: false, qualified: false, reasons: const [], beats: w.beats)
    ], const []);
    await store.reconcile(quiet, origin: 'bulk', nowMs: 4);
    await store.reconcile(old, origin: 'bulk', nowMs: 5);
    expect([for (final table in pulseEpisodeTables.take(5))
      jsonEncode(await db.query(table))], before);
    expect(await store.owed(), isEmpty);
  });
  // WHY/CLAIM(pulse-version-history): protecting old history must not hide a new tail.
  // # catches: dropping an entire new episode because its prefix overlaps history.
  test('a qualifying tail beyond protected history creates its own alert once', () async {
    await store.reconcile(detection(), origin: 'sync', nowMs: 1);
    await db.update('pulse_episode_revision', {'detector': 1});
    final old = jsonEncode(await db.query('pulse_episode', where: 'id=?', whereArgs: ['strap:0']));
    await store.reconcile(detection(offset: 600000), origin: 'sync', nowMs: 2);
    expect(jsonEncode(await db.query('pulse_episode', where: 'id=?', whereArgs: ['strap:0'])), old);
    expect((await store.list()).map((e) => e.id), ['strap:900000','strap:0']);
    await store.reconcile(detection(offset: 600000), origin: 'sync', nowMs: 3);
    expect(await db.query('pulse_episode_outbox'), hasLength(2));
  });
  // WHY/CLAIM(pulse-late-context): late semantic exclusions cancel only unclaimed debt.
  // # catches: treating semantic reasons as quality refusal or reviving notifications-off debt.
  for (final previousVersion in [2, 3]) {
  for (final reason in ['motion', 'offWrist', 'charging', 'sleepBreathing']) {
    for (final state in ['owed', 'notifications off', 'sent', 'summary', 'unknown', 'pending']) {
      test('v$previousVersion late $reason retracts while preserving $state ancestry', () async {
        final prior = detection();
        await store.reconcile(prior, origin: 'sync', nowMs: 1);
        // V2 and V3 rows remain correctable across V4; only V1 is frozen.
        await db.update('pulse_episode_revision', {'detector': previousVersion});
        await db.update('pulse_episode_outbox', {
          'state': state == 'notifications off' ? 'not_sent' : state,
          'reason': state == 'notifications off' ? state : null,
          'token': state == 'pending' ? 'in-flight' : null,
        });
        final evidence = [for (final table in ['pulse_episode_revision', 'pulse_evidence_chunk', 'pulse_episode_alias'])
          jsonEncode(await db.query(table))];
        final outbox = jsonEncode(await db.query('pulse_episode_outbox'));
        final excluded = ana.PulseDetection([for (final w in prior.windows)
          ana.PulseWindow(source: w.source, startMs: w.startMs, endMs: w.endMs,
            pairs: w.pairs, totalBeats: w.totalBeats, cleanedBeats: w.cleanedBeats,
            coverageMs: w.coverageMs, longestGapMs: w.longestGapMs,
            sd1: w.sd1, sd2: w.sd2, ratio: w.ratio, pnnPct: w.pnnPct,
            pending: w.pending, qualified: false, reasons: [reason], beats: w.beats)], const []);
        await store.reconcile(excluded, origin: 'bulk', nowMs: 2);
        expect((await store.get(prior.episodes.single.id))!.row['status'], 'retracted');
        expect([for (final table in ['pulse_episode_revision', 'pulse_evidence_chunk', 'pulse_episode_alias'])
          jsonEncode(await db.query(table))], evidence);
        expect(await store.owed(), isEmpty);
        expect(await store.claim([prior.episodes.single.id], token: 'retry', nowMs: 3), isEmpty);
        if (['sent', 'summary', 'unknown', 'pending'].contains(state)) {
          expect(jsonEncode(await db.query('pulse_episode_outbox')), outbox);
        } else {
          expect((await db.query('pulse_episode_outbox')).single['reason'], 'decision changed');
        }
      });
    }
  }
  }
  // WHY: inadequate late recordings cannot retract an existing supported episode.
  // # catches: ignoring quality refusals when a semantic exclusion is also present.
  test('semantic context plus poor recording retains the earlier decision', () async {
    final prior = detection();
    await store.reconcile(prior, origin: 'sync', nowMs: 1);
    final before = [for (final table in pulseEpisodeTables.take(5)) jsonEncode(await db.query(table))];
    final refused = ana.PulseDetection([for (final w in prior.windows)
      ana.PulseWindow(source: w.source, startMs: w.startMs, endMs: w.endMs,
        pairs: w.pairs, totalBeats: w.totalBeats, cleanedBeats: w.cleanedBeats,
        coverageMs: w.coverageMs, longestGapMs: w.longestGapMs,
        sd1: w.sd1, sd2: w.sd2, ratio: w.ratio, pnnPct: w.pnnPct,
        pending: false, qualified: false, reasons: const ['motion', 'coverage'], beats: w.beats)], const []);
    await store.reconcile(refused, origin: 'bulk', nowMs: 2);
    expect([for (final table in pulseEpisodeTables.take(5)) jsonEncode(await db.query(table))], before);
  });
  // WHY/CLAIM(pulse-atomic): storage failure cannot authorize an alert.
  test(
    'evidence and outbox are one transaction; failure rolls back everything',
    () async {
      await db.execute(
        "CREATE TRIGGER fail_evidence BEFORE INSERT ON pulse_evidence_chunk BEGIN SELECT RAISE(ABORT, 'disk full'); END",
      );
      await expectLater(
        store.reconcile(detection(), origin: 'sync', nowMs: 1),
        throwsA(anything),
      );
      expect(await db.query('pulse_episode'), isEmpty);
      expect(await db.query('pulse_episode_outbox'), isEmpty);
    },
  );
  // WHY/CLAIM(pulse-atomic): a concurrent raw replacement invalidates the prepared
  // recording before any episode or intent can commit.
  test('changed input revision refuses the complete reconciliation', () async {
    await db.execute('CREATE TABLE input_rev (bucket INTEGER PRIMARY KEY,rev INTEGER)');
    await db.insert('input_rev',{'bucket':0,'rev':2});
    await expectLater(store.reconcile(detection(),origin:'sync',nowMs:1,
      inputStamp:const PulseInputStamp(0,0,1)),throwsA(isA<PulseInputChanged>()));
    expect(await db.query('pulse_episode'),isEmpty);
    expect(await db.query('pulse_episode_outbox'),isEmpty);
  });
  // WHY/CLAIM(pulse-claim): a crashed handoff is unknown and never resent, even after reopen.
  test(
    'concurrent claims have one owner; abandoned claim becomes unknown',
    () async {
      await store.reconcile(detection(), origin: 'sync', nowMs: 1);
      final results = await Future.wait([
        store.claim(['strap:0'], token: 'a', nowMs: 2),
        store.claim(['strap:0'], token: 'b', nowMs: 2),
      ]);
      expect(results.expand((x) => x), hasLength(1));
      await store.recoverClaims(beforeMs: 3);
      expect((await store.get('strap:0'))!.alertState, 'unknown');
      expect(await store.claim(['strap:0'], token: 'c', nowMs: 4), isEmpty);
    },
  );
  // WHY/CLAIM(pulse-lineage): a split must use the old bounds for every child,
  // even after the seed-containing child shrank the parent's stored bounds.
  test('split children inherit a consumed parent claim', () async {
    final a=detection(),b=detection(offset:900000);
    final first=a.episodes.single.windows.take(2).toList();
    final second=b.episodes.single.windows.take(2).toList();
    final joined=ana.PulseEpisode('strap',[...first,a.episodes.single.windows.last,...second],ongoing:false);
    await store.reconcile(ana.PulseDetection(joined.windows,[joined]),origin:'sync',nowMs:1);
    final ids=await store.claim([joined.id],token:'sent',nowMs:2);
    await store.finish(ids,token:'sent',state:'sent',nowMs:3);
    final children=[ana.PulseEpisode('strap',first,ongoing:false),ana.PulseEpisode('strap',second,ongoing:false)];
    await store.reconcile(ana.PulseDetection([...first,...second],children),origin:'bulk',nowMs:4);
    expect((await store.get('strap:0'))!.alertState,'sent');
    expect((await store.get('strap:900000'))!.alertState,'sent');
    expect(await store.owed(),isEmpty);
  });
  // WHY/CLAIM(pulse-lineage): merging into an unconsumed earliest seed cannot
  // forget that a later contributing episode already alerted.
  test('merge consumes earliest root if a later root already alerted', () async {
    final a=detection(),b=detection(offset:900000);
    final first=a.episodes.single.windows.take(2).toList();
    final second=b.episodes.single.windows.take(2).toList();
    final children=[ana.PulseEpisode('strap',first,ongoing:false),ana.PulseEpisode('strap',second,ongoing:false)];
    await store.reconcile(ana.PulseDetection([...first,...second],children),origin:'bulk',nowMs:1);
    final ids=await store.claim(['strap:900000'],token:'sent',nowMs:2);
    await store.finish(ids,token:'sent',state:'sent',nowMs:3);
    final joined=ana.PulseEpisode('strap',[...first,a.episodes.single.windows.last,...second],ongoing:false);
    await store.reconcile(ana.PulseDetection(joined.windows,[joined]),origin:'bulk',nowMs:4);
    expect((await store.get('strap:0'))!.alertState,'sent');
    expect((await store.get('strap:900000'))!.id,'strap:0');
    expect(await store.owed(),isEmpty);
  });
  // WHY/CLAIM(pulse-evidence): a trace survives raw removal and repeated derive without duplicate intent.
  test('retained evidence, stable identity and explicit expiry', () async {
    await store.reconcile(detection(), origin: 'sync', nowMs: 1);
    await store.reconcile(detection(), origin: 'bulk', nowMs: 2);
    expect(await db.query('pulse_episode_outbox'), hasLength(1));
    final episode = (await store.get('strap:0'))!;
    expect(episode.beats, isNotEmpty);
    expect(episode.evidenceStatus, 'complete');
    await store.retain(nowMs: 366 * 86400000);
    expect((await store.get('strap:0'))!.evidenceStatus, 'expired');
    expect(await db.query('pulse_episode_outbox'), hasLength(1));
  });
  // WHY/CLAIM(pulse-additive): additive creation never touches unrelated durable rows.
  test(
    'migration twice preserves raw, decoded and frozen legacy output checksums',
    () async {
      for (final table in [
        'raw_records',
        'decoded_onehz',
        'decoded_rr',
        'day_result',
      ]) {
        await db.execute(
          'CREATE TABLE $table (id INTEGER PRIMARY KEY, payload TEXT)',
        );
        await db.insert(table, {'id': 1, 'payload': 'legacy-$table'});
      }
      Future<String> digest() async => sha256
          .convert(
            utf8.encode(
              jsonEncode([
                for (final table in [
                  'raw_records',
                  'decoded_onehz',
                  'decoded_rr',
                  'day_result',
                ])
                  await db.query(table),
              ]),
            ),
          )
          .toString();
      final before = await digest();
      await PulseEpisodeStore.create(db);
      await PulseEpisodeStore.create(db);
      await store.reconcile(detection(), origin: 'bulk', nowMs: 1);
      await store.retain(nowMs: 500 * 86400000);
      expect(await digest(), before);
    },
  );
  // WHY/CLAIM(pulse-corruption): checksum failures cannot be handed to delivery.
  test(
    'a corrupted evidence blob is a read failure and cannot be claimed',
    () async {
      await store.reconcile(detection(), origin: 'sync', nowMs: 1);
      await db.update('pulse_evidence_chunk', {'payload': '{}'});
      await expectLater(store.get('strap:0'), throwsStateError);
      expect(await store.claim(['strap:0'], token: 'x', nowMs: 2), isEmpty);
    },
  );
}
