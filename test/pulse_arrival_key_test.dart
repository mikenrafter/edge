// WHY: the novelty lookup and the derive enqueue run inside the ACK-gating
// commit of every gen5 chunk. The lookup must ride the primary key
// (device_id, ts_ms), never walk every row of the band, and the enqueue must
// commit or roll back with the chunk it describes.
// PROVES: CLAIM(pulse-arrival-key), CLAIM(pulse-arrival-same-txn).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _day = 86400;
const _trim = '0011223344556677';

/// The lookup as it was written before the key change: the oracle the new one
/// must agree with on every fixture.
String _oldSql(int n) {
  final m = List.filled(n, '?').join(',');
  return 'SELECT rec_ts FROM decoded_onehz WHERE device_id = ? AND rec_ts IN ($m) '
      'UNION SELECT rec_ts FROM decoded_rr WHERE device_id = ? AND rec_ts IN ($m)';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final events = <String>[];
  late String path;

  setUpAll(() {
    sqfliteFfiInit();
    // ignore: experimental_member_use
    databaseFactory = SqfliteDatabaseFactoryLogger(databaseFactoryFfi,
        options: SqfliteLoggerOptions(log: (e) {
      if (e is SqfliteLoggerSqlEvent) events.add(e.sql);
    }));
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'pulse_arrival_key.db';
    path = p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName);
    await databaseFactory.deleteDatabase(path);
    events.clear();
  });

  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(path);
  });

  RawRecord raw(int counter, int ts, int capturedAt) => RawRecord(
        counter: counter,
        packetType: 47,
        hex: '2f18${counter.toRadixString(16).padLeft(8, '0')}',
        recTs: ts,
        capturedAt: capturedAt,
      );
  Sample sample(int counter, int ts) =>
      Sample(tsEpoch: ts, counter: counter, hr: 70, rrIntervalsMs: [800]);

  // why: a lookup on device_id alone walks every row the band ever banked, in
  // the ACK-gating transaction. proves: CLAIM(pulse-arrival-key).
  test('the arrival lookup plans on the primary key of both decoded tables', () async {
    final db = await LocalDb.instance;
    final plan = await db.rawQuery(
      'EXPLAIN QUERY PLAN ${LocalDb.pulseArrivalSql(3)}',
      ['', 1, 2, 3, '', 1, 2, 3],
    );
    final lines = [for (final r in plan) r['detail'].toString()];
    final searches = [
      for (final l in lines)
        if (l.startsWith('SEARCH') || l.startsWith('SCAN')) l,
    ];
    expect(searches.where((l) => l.contains('decoded_onehz')), hasLength(1),
        reason: '$lines');
    expect(searches.where((l) => l.contains('decoded_rr')), hasLength(1),
        reason: '$lines');
    for (final l in searches) {
      expect(l, startsWith('SEARCH'), reason: 'a full scan: $lines');
      expect(l, contains('device_id=? AND ts_ms=?'),
          reason: 'not the (device_id, ts_ms) key: $lines');
    }
  });

  // why: the key change must not move a single result. Rows are written the
  // way the writers store them (ts_ms = rec_ts * 1000); the oracle is the old
  // query. proves: CLAIM(pulse-arrival-key).
  test('the keyed lookup returns what the rec_ts lookup returned', () async {
    final db = await LocalDb.instance;
    final top = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 20 * _day;
    // One second per distinct day, so the day-keyed context shows each.
    final secs = [for (var k = 0; k < 8; k++) top - k * _day];
    Future<void> onehz(int s, String dev) => db.insert('decoded_onehz', {
          'device_id': dev, 'ts_ms': s * 1000, 'rec_ts': s, 'counter': s, 'hr': 70,
        });
    Future<void> rr(int s, String dev) => db.insert('decoded_rr', {
          'device_id': dev, 'ts_ms': s * 1000, 'rec_ts': s,
          'beat_index': 0, 'rr_ts_ms': s * 1000, 'rr_ms': 800,
        });
    await onehz(secs[0], ''); //            onehz only
    await rr(secs[1], ''); //               rr only
    await onehz(secs[2], '');
    await rr(secs[2], ''); //               both
    //                                      secs[3]: neither
    await onehz(secs[4], 'AA:BB');
    await rr(secs[4], 'AA:BB'); //          another device only
    await onehz(secs[5] + 1, ''); //        a neighbouring second only
    await rr(secs[6] + 1, ''); //           same, rr
    //                                      secs[7]: neither
    final raws = [for (var i = 0; i < secs.length; i++) raw(i + 1, secs[i], 1000 + i)];
    final samples = [for (var i = 0; i < secs.length; i++) sample(i + 1, secs[i])];

    final got = await db.transaction(
        (txn) => LocalDb.pulseArrivalContext(txn, raws, samples));

    final known = <int>{};
    for (final r in await db.rawQuery(_oldSql(secs.length),
        ['', ...secs, '', ...secs])) {
      known.add((r['rec_ts'] as num).toInt());
    }
    final want = ProcessingContext.arrival([
      for (var i = 0; i < secs.length; i++)
        if (!known.contains(secs[i])) (recordedMs: secs[i] * 1000, arrivedMs: 1000 + i),
    ]);
    expect(known, {secs[0], secs[1], secs[2]}, reason: 'fixture lost its mix');
    expect(want.pulseDays, hasLength(5));
    expect(got.origin, ProcessingOrigin.recentSync);
    expect(got.pulseDays, want.pulseDays);
    expect(got.pulseDays.keys.toSet(), {
      for (final i in [3, 4, 5, 6, 7])
        dayLabelOf(DateTime.fromMillisecondsSinceEpoch(secs[i] * 1000)),
    });
  });

  // why: the lookup keys on ts_ms = rec_ts * 1000, so every writer must store
  // exactly that. proves: CLAIM(pulse-arrival-key).
  test('the app writers store ts_ms = rec_ts * 1000 in both decoded tables', () async {
    final base = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600;
    final raws = [for (var i = 0; i < 4; i++) raw(i + 1, base + i, 5000)];
    final samples = [for (var i = 0; i < 4; i++) sample(i + 1, base + i)];
    await LocalDb.commitSyncBatch(raws, samples,
        trimToken: _trim, processingOrigin: ProcessingOrigin.recentSync);
    await LocalDb.commitSyncBatch(
        [raw(9, base + 100, 5000)], [sample(9, base + 100)],
        trimToken: _trim);
    await LocalDb.insertRecord(raw(10, base + 200, 5000), sample(10, base + 200));
    await LocalDb.insertRecordsBatch(
        [raw(11, base + 300, 5000)], [sample(11, base + 300)]);
    final db = await LocalDb.instance;
    for (final t in ['decoded_onehz', 'decoded_rr']) {
      expect((await db.rawQuery('SELECT COUNT(*) c FROM $t')).first['c'], greaterThan(0));
      expect(
          (await db.rawQuery('SELECT COUNT(*) c FROM $t WHERE ts_ms != rec_ts * 1000'))
              .first['c'],
          0,
          reason: t);
    }
  });

  // why: ACK follows the commit; the enqueue is the commit's own write, so a
  // rolled-back chunk leaves no job and a committed one always has it, with no
  // second fsync'd transaction behind the commit. proves: CLAIM(pulse-arrival-same-txn).
  group('enqueue rides the commit transaction', () {
    final base = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600;
    late List<RawRecord> raws;
    late List<Sample?> samples;
    setUp(() {
      raws = [for (var i = 0; i < 3; i++) raw(i + 1, base + i, 5000)];
      samples = [for (var i = 0; i < 3; i++) sample(i + 1, base + i)];
    });

    Future<int> arrivalJobs() async => [
          for (final j in await LocalDb.computeJobs())
            if (j['reason'] == 'recent_pulse_sync') j,
        ].length;

    test('a committed chunk carries its job, written inside that transaction', () async {
      await LocalDb.commitSyncBatch(raws, samples,
          trimToken: _trim, processingOrigin: ProcessingOrigin.recentSync);
      expect(await arrivalJobs(), 1);

      // Serial number of the transaction each statement ran in.
      var serial = 0;
      final txnOf = <String, int>{};
      for (final sql in events) {
        if (sql.startsWith('BEGIN')) serial++;
        if (sql.startsWith('INSERT') && sql.contains('compute_jobs')) {
          txnOf['jobs'] = serial;
        }
        if (!sql.startsWith('SELECT') && sql.contains('compute_freshness')) {
          txnOf['commit'] = serial;
        }
      }
      expect(serial, greaterThan(0), reason: 'no BEGIN logged: $events');
      expect(txnOf['jobs'], isNotNull, reason: '$events');
      expect(txnOf['jobs'], txnOf['commit'],
          reason: 'the job was written outside the chunk commit: $events');
    });

    // why: a failed enqueue is swallowed inside the transaction; a failed
    // statement aborts only itself, so the chunk must still commit (and the
    // band be ACKed) and the failure must be reported, not silent.
    test('a failing enqueue neither blocks the commit nor stays silent', () async {
      final db = await LocalDb.instance;
      await db.execute('CREATE TRIGGER fail_jobs BEFORE INSERT ON compute_jobs '
          "BEGIN SELECT RAISE(ABORT, 'no jobs'); END");
      final notes = <String>[];
      await LocalDb.commitSyncBatch(raws, samples,
          trimToken: _trim,
          processingOrigin: ProcessingOrigin.recentSync,
          onCheckpoint: notes.add);
      expect((await db.rawQuery('SELECT COUNT(*) c FROM decoded_onehz')).first['c'], 3);
      expect(await LocalDb.getCursor('strap_trim'), _trim);
      expect(await arrivalJobs(), 0);
      expect(notes.where((n) => n.contains('pulse arrival enqueue failed')), hasLength(1));
    });

    test('a chunk that rolls back enqueues nothing', () async {
      final db = await LocalDb.instance;
      // The last statement of the commit transaction; the enqueue has run by then.
      await db.execute('CREATE TRIGGER fail_fresh BEFORE INSERT ON compute_freshness '
          "BEGIN SELECT RAISE(ABORT, 'no'); END");
      await db.execute('CREATE TRIGGER fail_fresh_u BEFORE UPDATE ON compute_freshness '
          "BEGIN SELECT RAISE(ABORT, 'no'); END");
      await expectLater(
          LocalDb.commitSyncBatch(raws, samples,
              trimToken: _trim, processingOrigin: ProcessingOrigin.recentSync),
          throwsA(anything));
      expect(await db.rawQuery('SELECT 1 FROM decoded_onehz'), isEmpty);
      expect(await arrivalJobs(), 0);
    });
  });
}
