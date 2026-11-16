// Fix round 1, store level: episode identity across reconciles (review r1
// finding 2) and the retention read (finding 3).
import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/data/pulse_episode_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const slotMs = ana.pulseWindowMs;

ana.PulseWindow slot(int k, {bool qualified = true, bool refused = false}) =>
    ana.PulseWindow(
      source: 'strap',
      startMs: k * slotMs,
      endMs: (k + 1) * slotMs,
      pairs: 250,
      totalBeats: 300,
      cleanedBeats: 0,
      coverageMs: 290000,
      longestGapMs: 1000,
      sd1: 100,
      sd2: 120,
      ratio: .8,
      pnnPct: 60,
      pending: false,
      qualified: qualified,
      reasons: refused ? const ['coverage'] : const [],
      beats: const [],
    );

/// Twelve closed slots: [qualified] ones qualify, [refused] ones are refused
/// for a quality reason, the rest are good windows that do not qualify. Every
/// run of two or more qualified slots is an episode.
ana.PulseDetection det(Set<int> qualified, {Set<int> refused = const {}}) {
  final windows = [
    for (var k = 0; k < 12; k++)
      slot(k, qualified: qualified.contains(k), refused: refused.contains(k)),
  ];
  final episodes = <ana.PulseEpisode>[];
  var run = <ana.PulseWindow>[];
  void end() {
    if (run.length >= 2) episodes.add(ana.PulseEpisode('strap', run, ongoing: false));
    run = [];
  }

  for (final w in windows) {
    w.qualified ? run.add(w) : end();
  }
  end();
  return ana.PulseDetection(windows, episodes);
}

class _SpyTxn implements Transaction {
  _SpyTxn(this.inner, this.seen);
  final Transaction inner;
  final List<String> seen;
  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    seen.add('$table:${columns?.join(',') ?? '*'}');
    return inner.query(table, distinct: distinct, columns: columns, where: where,
        whereArgs: whereArgs, groupBy: groupBy, having: having, orderBy: orderBy,
        limit: limit, offset: offset);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? a]) {
    seen.add('raw:$sql');
    return inner.rawQuery(sql, a);
  }

  @override
  Future<int> update(String table, Map<String, Object?> values,
          {String? where, List<Object?>? whereArgs, ConflictAlgorithm? conflictAlgorithm}) =>
      inner.update(table, values, where: where, whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);
  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      inner.delete(table, where: where, whereArgs: whereArgs);
  @override
  Future<int> rawUpdate(String sql, [List<Object?>? a]) => inner.rawUpdate(sql, a);
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class _SpyDb implements Database {
  _SpyDb(this.inner);
  final Database inner;
  final seen = <String>[];
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action,
          {bool? exclusive}) =>
      inner.transaction((txn) => action(_SpyTxn(txn, seen)));
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Database db;
  late PulseEpisodeStore store;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp('pulse2-identity');
    db = await databaseFactory.openDatabase('${dir.path}/test.db');
    store = PulseEpisodeStore(db);
    await PulseEpisodeStore.create(db);
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<void> deliver(String id, {String state = 'sent'}) async {
    final ids = await store.claim([id], token: 't$id', nowMs: 5);
    await store.finish(ids, token: 't$id', state: state, nowMs: 6);
  }

  Future<List<String>> owedIds() async =>
      [for (final r in await store.owed()) r['episode_id'] as String];

  // WHY/CLAIM(pulse-identity): a trimmed start retires the old row; one stretch
  // is one active row and one owed alert, not two.
  test('a trimmed start retires the old row and owes one alert', () async {
    await store.reconcile(det({0, 1, 2}), origin: 'sync', nowMs: 1);
    await store.reconcile(det({1, 2}), origin: 'sync', nowMs: 2);
    final active = await store.list();
    expect(active.map((e) => e.id), ['strap:$slotMs']);
    expect(active.single.startMs, slotMs);
    expect(await owedIds(), ['strap:$slotMs']);
    expect((await store.get('strap:0'))!.id, 'strap:$slotMs');
  });

  test('a trimmed start after the alert went out stays consumed', () async {
    await store.reconcile(det({0, 1, 2}), origin: 'sync', nowMs: 1);
    await deliver('strap:0');
    await store.reconcile(det({1, 2}), origin: 'sync', nowMs: 2);
    expect((await store.list()).map((e) => e.id), ['strap:$slotMs']);
    expect(await owedIds(), isEmpty);
    expect((await store.get('strap:$slotMs'))!.alertState, 'sent');
  });

  // WHY/CLAIM(pulse-identity): a retracted episode that qualifies again must
  // still be able to alert.
  test('a retracted episode that comes back keeps a deliverable record',
      () async {
    await store.reconcile(det({0, 1, 2}), origin: 'sync', nowMs: 1);
    await store.reconcile(det({}), origin: 'sync', nowMs: 2);
    expect(await store.list(), isEmpty);
    expect(await owedIds(), isEmpty);
    await store.reconcile(det({0, 1, 2}), origin: 'sync', nowMs: 3);
    expect(await owedIds(), ['strap:0']);
    expect(await store.claim(['strap:0'], token: 'a', nowMs: 4), ['strap:0']);
  });

  test('a retracted episode that had already alerted does not alert again',
      () async {
    await store.reconcile(det({0, 1, 2}), origin: 'sync', nowMs: 1);
    await deliver('strap:0');
    await store.reconcile(det({}), origin: 'sync', nowMs: 2);
    await store.reconcile(det({0, 1, 2}), origin: 'sync', nowMs: 3);
    expect(await owedIds(), isEmpty);
    expect((await store.get('strap:0'))!.alertState, 'sent');
  });

  test('a merged-away episode that splits out again can still alert', () async {
    await store.reconcile(det({0, 1, 2, 6, 7, 8}), origin: 'sync', nowMs: 1);
    await store.reconcile(det({0, 1, 2, 3, 4, 5, 6, 7, 8}), origin: 'sync', nowMs: 2);
    expect((await store.list()).map((e) => e.id), ['strap:0']);
    await store.reconcile(det({0, 1, 2, 6, 7, 8}), origin: 'sync', nowMs: 3);
    expect(await owedIds(), unorderedEquals(['strap:0', 'strap:${6 * slotMs}']));
    expect((await store.list()), hasLength(2));
    expect((await store.get('strap:${6 * slotMs}'))!.id, 'strap:${6 * slotMs}');
  });

  // WHY/CLAIM(pulse-identity): a retired row never hands its id to a new
  // stretch, even when its old seed falls inside it.
  test('a merged-away row does not give its id to a later episode', () async {
    await store.reconcile(det({0, 1, 2, 6, 7, 8}), origin: 'sync', nowMs: 1);
    await store.reconcile(det({0, 1, 2, 3, 4, 5, 6, 7, 8}), origin: 'sync', nowMs: 2);
    await store.reconcile(det({5, 6, 7, 8}), origin: 'sync', nowMs: 3);
    expect((await store.list()).map((e) => e.id), ['strap:${5 * slotMs}']);
    expect(await owedIds(), ['strap:${5 * slotMs}']);
    expect((await store.get('strap:${6 * slotMs}'))!.id, 'strap:${5 * slotMs}');
  });

  // WHY/CLAIM(pulse-identity): a superseded row can qualify again at its
  // own seed after the replacement disappears. Its terminal record is not an
  // alert, and its alias must stop redirecting it (review r2 mutation M2).
  test('a superseded episode requalifies at its own start and alerts once',
      () async {
    await store.reconcile(det({0, 1, 2}), origin: 'sync', nowMs: 1);
    await store.reconcile(det({1, 2}), origin: 'sync', nowMs: 2);
    final retired = (await db.query('pulse_episode', where: "id='strap:0'")).single;
    expect(retired['status'], 'superseded');
    final record = (await db.query('pulse_episode_outbox',
        where: "episode_id='strap:0'")).single;
    expect(record['state'], 'not_sent');
    expect(record['reason'], 'superseded episode');
    await store.reconcile(det({}), origin: 'sync', nowMs: 3);
    await store.reconcile(det({0, 1, 2}), origin: 'sync', nowMs: 4);
    expect((await store.get('strap:0'))!.id, 'strap:0');
    expect(await owedIds(), ['strap:0']);
    await deliver('strap:0');
    await store.reconcile(det({0, 1, 2}), origin: 'sync', nowMs: 7);
    expect(await owedIds(), isEmpty);
    expect((await store.get('strap:0'))!.alertState, 'sent');
  });

  // WHY/CLAIM(pulse-identity): model check over reconcile sequences: trims,
  // growth, splits, merges, retraction and return, with delivery in between.
  // Never two active rows over one stretch; never two alerts for one stretch;
  // never a stretch left without its alert.
  test('model: reconcile sequences keep one row and one alert per stretch',
      () async {
    for (var seed = 0; seed < 40; seed++) {
      final random = Random(seed);
      for (final t in pulseEpisodeTables) {
        await db.delete(t);
      }
      final trace = <String>[];
      // A stretch is alerted against the rows that already carry an alert, at
      // the extent they have now. (An alerted row that later shrinks forgets the
      // part it dropped: a known limit, see the fix round 1 report.)
      Future<void> deliverAll() async {
        for (final r in await store.owed()) {
          final id = r['episode_id'] as String;
          final start = r['start_ms'] as int, end = r['end_ms'] as int;
          final alerted = await db.rawQuery(
            "SELECT e.id,e.start_ms,e.end_ms FROM pulse_episode e JOIN pulse_episode_outbox a "
            "ON a.episode_id=e.id WHERE a.state='sent' AND e.id != ? AND e.source='strap' "
            "AND e.start_ms < ? AND e.end_ms > ?",
            [id, end, start],
          );
          expect(alerted, isEmpty,
              reason: 'seed $seed: $id alerts over $alerted\n${trace.join('\n')}');
          final ids = await store.claim([id], token: 'm$id', nowMs: 5);
          if (ids.isEmpty) continue;
          trace.add('  deliver $id');
          await store.finish(ids, token: 'm$id', state: 'sent', nowMs: 6);
        }
      }

      for (var step = 0; step < 8; step++) {
        final slots = {for (var k = 0; k < 12; k++) if (random.nextDouble() < .6) k};
        final refused = {for (final k in List.generate(12, (k) => k)) if (!slots.contains(k) && random.nextDouble() < .15) k};
        trace.add('step $step slots ${(slots.toList()..sort())} refused ${(refused.toList()..sort())}');
        await store.reconcile(det(slots, refused: refused), origin: 'sync', nowMs: step + 1);
        trace.add('  rows: ${[for (final r in await db.query('pulse_episode')) '${r['id']}[${(r['start_ms'] as int) ~/ slotMs},${(r['end_ms'] as int) ~/ slotMs}) ${r['status']}'].join(' ')}');
        final active = await store.list(limit: 100);
        for (final a in active) {
          for (final b in active) {
            if (a.id == b.id) continue;
            expect(a.startMs < b.endMs && a.endMs > b.startMs, isFalse,
                reason: 'seed $seed step $step: ${a.id} and ${b.id} overlap');
          }
        }
        if (random.nextBool()) await deliverAll();
      }
      await deliverAll();
      for (final e in await store.list(limit: 100)) {
        expect(['sent', 'summary', 'pending', 'unknown'], contains(e.alertState),
            reason: 'seed $seed: ${e.id} was never alerted and nothing is owed');
      }
      expect(await owedIds(), isEmpty);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  // WHY/CLAIM(pulse-retention): the retention pass reads sizes and dates, never
  // the blobs (rule B8: Android cursor windows are about 2 MB).
  test('retention does not read evidence payloads', () async {
    await store.reconcile(det({0, 1, 2}), origin: 'sync', nowMs: 1);
    final spy = _SpyDb(db);
    await PulseEpisodeStore(spy).retain(nowMs: 400 * 86400000);
    final reads = spy.seen.where((s) => s.contains('pulse_evidence_chunk'));
    expect(reads, isNotEmpty);
    for (final r in reads) {
      expect(r, isNot(contains(':*')), reason: r);
      expect(r, isNot(contains('payload')), reason: r);
    }
    expect((await store.get('strap:0'))!.evidenceStatus, 'expired');
  });
}
