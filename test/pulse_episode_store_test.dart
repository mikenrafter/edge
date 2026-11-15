import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/data/db.dart';
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
