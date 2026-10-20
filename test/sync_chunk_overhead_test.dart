// Band-sync per-chunk overhead (design: edge.research/design-sync-throughput.md).
//
// The band waits for each HISTORY_END ACK before it sends the next burst, so
// every fixed cost per chunk caps sync throughput. Today a chunk pays for:
//   - PRAGMA synchronous=FULL, a read-back, then =NORMAL (3 round trips);
//   - a capture-freshness select + insert AFTER the commit, outside it;
//   - two sync_ledger upserts (select + insert each) after the ACK;
//   - no [perf] line at all, so nobody can see any of it.
//
// What must NOT change (AGENTS.md invariant 1): the rows + cursor commit in
// one transaction, at synchronous=FULL, BEFORE the verbatim token is echoed;
// a commit that fails produces no ACK.
//
// Layout:
//   A. LocalDb.commitSyncBatch round trips and durability (tests 1-3).
//   B. The engine's HISTORY_END path over a real database (tests 4-6).
//
// The sqflite logger sees every call LocalDb makes, the way
// import_bulk_restore_test.dart does. Calls made outside a transaction carry
// no transactionId; that is how "one transaction" is told from "N autocommits".

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ── call log ────────────────────────────────────────────────────────────────

/// One thing that happened, in order: either a sqflite call or a marker the
/// test dropped in ('ack', 'commit-start', 'commit-end').
class _Ev {
  final String? method; // null for a marker
  final List<String> sql;
  final Object? txId;
  final String mark;
  _Ev.call(this.method, this.sql, this.txId) : mark = '';
  _Ev.mark(this.mark) : method = null, sql = const [], txId = null;

  bool touches(String table) {
    final re = RegExp('\\b$table\\b');
    return sql.any(re.hasMatch);
  }

  bool get isWrite => sql.any(
        (s) => RegExp(r'^\s*(INSERT|UPDATE|DELETE|REPLACE)\b', caseSensitive: false)
            .hasMatch(s),
      );

  bool get isSynchronousPragma =>
      sql.any((s) => RegExp(r'pragma\s+synchronous', caseSensitive: false).hasMatch(s));

  bool get isSynchronousSet =>
      sql.any((s) => RegExp(r'pragma\s+synchronous\s*=', caseSensitive: false).hasMatch(s));

  bool sqlIs(String re) =>
      sql.any((s) => RegExp(re, caseSensitive: false).hasMatch(s));
}

final _log = <_Ev>[];
var _counting = false;

void _mark(String m) {
  if (_counting) _log.add(_Ev.mark(m));
}

/// Every SQL string one sqflite call carries (a batch carries one per op).
Iterable<String> _sqlOf(Object? args) sync* {
  if (args is Map) {
    final sql = args['sql'];
    if (sql is String) yield sql;
    for (final v in args.values) {
      if (v is List || v is Map) yield* _sqlOf(v);
    }
  } else if (args is List) {
    for (final v in args) {
      yield* _sqlOf(v);
    }
  }
}

/// How many separate commits the writes to [table] in [events] cost: every
/// autocommit write is one, and every transaction holding a write is one.
/// Reads do not count; a batch outside a transaction is one call.
int _commitsTouching(Iterable<_Ev> events, String table) {
  var autocommit = 0;
  final txns = <Object>{};
  for (final e in events) {
    if (e.method == null || !e.touches(table) || !e.isWrite) continue;
    if (e.txId == null) {
      autocommit++;
    } else {
      txns.add(e.txId!);
    }
  }
  return autocommit + txns.length;
}

// ── fixtures ────────────────────────────────────────────────────────────────

const _t0 = 1780000000;

String _hex(int counter) => '2f18${counter.toRadixString(16).padLeft(8, '0')}';

RawRecord _raw(int counter) => RawRecord(
      counter: counter,
      packetType: 0x2f,
      hex: _hex(counter),
      capturedAt: (_t0 + counter) * 1000,
      recTs: _t0 + counter,
    );

Sample _sample(int counter) =>
    Sample(tsEpoch: _t0 + counter, counter: counter, hr: 60);

/// `n` consecutive records starting at counter `from`.
(List<RawRecord>, List<Sample?>) _records(int from, int n) => (
      [for (var i = 0; i < n; i++) _raw(from + i)],
      <Sample?>[for (var i = 0; i < n; i++) _sample(from + i)],
    );

Future<void> _commit(int from, int n, {String? token}) {
  final (raws, samples) = _records(from, n);
  return LocalDb.commitSyncBatch(raws, samples, trimToken: token);
}

late String _dbDir;

Future<Database> _freshLocal() async {
  await LocalDb.close();
  await databaseFactory.deleteDatabase(p.join(_dbDir, LocalDb.dbName));
  SharedPreferences.setMockInitialValues({});
  return LocalDb.instance;
}

/// `PRAGMA synchronous` as the connection reports it now: 2 FULL, 1 NORMAL.
Future<int?> _syncLevel() async {
  final db = await LocalDb.instance;
  final rows = await db.rawQuery('PRAGMA synchronous');
  final v = rows.isEmpty ? null : rows.first.values.firstOrNull;
  return v is num ? v.toInt() : null;
}

Future<int> _count(String table, [String where = '1=1']) async {
  final db = await LocalDb.instance;
  final r = await db.rawQuery('SELECT COUNT(*) AS c FROM $table WHERE $where');
  return (r.first['c'] as num).toInt();
}

// ── engine rig (B) ──────────────────────────────────────────────────────────

int _wallNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Uint8List _historyStart() =>
    Uint8List.fromList(<int>[PacketType.metadata, 0x01, SyncMeta.historyStart]);

Uint8List _historyComplete() => Uint8List.fromList(
    <int>[PacketType.metadata, 0x03, SyncMeta.historyComplete]);

Uint8List _historyEnd({required int expected, required int token}) {
  final inner = Uint8List(24);
  inner[0] = PacketType.metadata;
  inner[1] = 0x02;
  inner[2] = SyncMeta.historyEnd;
  final v = ByteData.sublistView(inner);
  v.setUint32(3, 1786000000, Endian.little);
  v.setUint32(9, expected, Endian.little);
  v.setUint32(13, token, Endian.little);
  v.setUint32(17, 0x18, Endian.little);
  return inner;
}

Uint8List _gen5V18Inner({required int ts, required int counter}) {
  final inner = Uint8List(kGen5V18InnerLen);
  final v = ByteData.sublistView(inner);
  inner[0] = PacketType.historicalData;
  inner[1] = 18;
  inner[2] = 0x80;
  v.setUint32(3, counter, Endian.little);
  v.setUint32(7, ts, Endian.little);
  inner[14] = 64;
  v.setFloat32(33, 0.5, Endian.little);
  v.setFloat32(45, 1.0, Endian.little);
  return inner;
}

/// The same fake gen5 link history_task_safety_test.dart uses, but its commit
/// sink is the REAL `LocalDb.commitSyncBatch`, so the call log sees the
/// commit, the ACK write and the post-ACK ledger writes in one timeline.
class _Rig {
  final logs = <String>[];
  final acks = <List<int>>[]; // body of each success result, in order
  late final BleEngine engine;

  _Rig() {
    engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {}, log: logs.add);
    engine.debugInstallFakeLink(
      band: BandProfile.gen5,
      onCommit: (raws, samples, token,
          {archives, ecgRawPackets, deviceFamily}) async {
        _mark('commit-start');
        await LocalDb.commitSyncBatch(
          raws,
          samples,
          trimToken: token,
          archives: archives,
          ecgRawPackets: ecgRawPackets,
          deviceFamily: deviceFamily,
        );
        _mark('commit-end');
      },
      onWrite: (f) async {
        final parsed = parseFrame(f, profile: BandProfile.gen5);
        if (parsed == null || !parsed.valid) return true;
        final opcode = parsed.inner[2];
        final body = parsed.inner.sublist(3);
        if (opcode == Cmd.getClock) {
          final seq = parsed.inner[1];
          scheduleMicrotask(() => engine.debugAbsorbDecoded(Decoded(
                'cmd_response',
                {
                  'opcode': Cmd.getClock,
                  'req_seq': seq,
                  'cmd_status': 1,
                  'clock_epoch': _wallNow(),
                },
              )));
        }
        if (opcode == Cmd.historicalDataResult &&
            body.isNotEmpty &&
            body[0] == 0x01) {
          acks.add(body);
          _mark('ack');
        }
        return true;
      },
    );
  }

  void rx(Uint8List inner) =>
      engine.debugReceiveFrame(Frame(inner, true, true), role: 'data');

  /// One full burst: [n] records, then the marker for [token].
  void chunk(int n, int token, {required int ts, required int counter}) {
    for (var i = 0; i < n; i++) {
      rx(_gen5V18Inner(ts: ts + i, counter: counter + i));
    }
    rx(_historyEnd(expected: n, token: token));
  }

  /// Wait until the timeline and the log stop growing: the commit, the ACK
  /// and the post-ACK writes are all async over the ffi isolate.
  Future<void> settle() async {
    var last = -1;
    var stable = 0;
    for (var i = 0; i < 200 && stable < 4; i++) {
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final now = _log.length + logs.length;
      stable = now == last ? stable + 1 : 0;
      last = now;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUpAll(() async {
    sqfliteFfiInit();
    // The logger is the only public hook that sees every sqflite call.
    // ignore: experimental_member_use
    databaseFactory = SqfliteDatabaseFactoryLogger(
      databaseFactoryFfi,
      options: SqfliteLoggerOptions(
        type: SqfliteDatabaseFactoryLoggerType.invoke,
        log: (e) {
          if (_counting && e is SqfliteLoggerInvokeEvent) {
            final args = e.arguments;
            _log.add(_Ev.call(
              e.method,
              _sqlOf(args).toList(),
              args is Map ? args['transactionId'] : null,
            ));
          }
        },
      ),
    );
    SharedPreferences.setMockInitialValues({});
    LocalDb.dbName = 'openstrap_sync_chunk_overhead_test.db';
    LocalDb.nowMs = () => 1790000000000;
    _dbDir = await databaseFactory.getDatabasesPath();
    tmp = await Directory.systemTemp.createTemp('openstrap_chunk_overhead_');
  });

  tearDownAll(() async {
    _counting = false;
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(_dbDir, LocalDb.dbName));
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  setUp(() async {
    _counting = false;
    _log.clear();
    await _freshLocal();
  });

  tearDown(() async {
    _counting = false;
    // A session left open by a failing assertion must not leak FULL (or an
    // open-session flag) into the next test.
    await LocalDb.endOffloadSession();
  });

  group('A. commitSyncBatch round trips and durability', () {
    // 1. The bracket is per session, not per chunk.
    test('1. ten commits inside an offload session make no PRAGMA synchronous '
        'call', () async {
      await LocalDb.beginOffloadSession();
      _counting = true;
      for (var i = 0; i < 10; i++) {
        await _commit(1 + i * 50, 50, token: 'tok$i');
      }
      _counting = false;

      final pragmas = _log.where((e) => e.isSynchronousPragma).toList();
      expect(
        pragmas,
        isEmpty,
        reason: 'FULL is set once when the offload starts, so a chunk commit '
            'runs no synchronous pragma; saw ${pragmas.length} in 10 commits '
            '(today: set FULL + read back + set NORMAL per commit = 30)',
      );
      expect(_log.where((e) => e.sqlIs(r'^\s*COMMIT')), hasLength(10),
          reason: 'harness check: ten real transactions committed');
      expect(await _count('samples'), 500);
      await LocalDb.endOffloadSession();
    });

    test('1b. a whole session costs at most one set to FULL and one back to '
        'NORMAL', () async {
      _counting = true;
      await LocalDb.beginOffloadSession();
      for (var i = 0; i < 10; i++) {
        await _commit(1 + i * 50, 50, token: 'tok$i');
      }
      await LocalDb.endOffloadSession();
      _counting = false;

      final sets = _log.where((e) => e.isSynchronousSet).length;
      expect(sets, lessThanOrEqualTo(2),
          reason: 'begin sets FULL, end sets NORMAL; commits set nothing '
              '(today: 20 sets over the same ten commits)');
    });

    // 2. Durability is unchanged.
    test('2a. inside a session the connection is FULL (2) after every commit',
        () async {
      await LocalDb.beginOffloadSession();
      expect(await _syncLevel(), 2,
          reason: 'beginOffloadSession raises the connection to FULL');
      for (var i = 0; i < 3; i++) {
        await _commit(1 + i * 50, 50, token: 'tok$i');
        expect(await _syncLevel(), 2,
            reason: 'commit $i must not drop the session back to NORMAL '
                '(today the per-commit finally resets it to 1)');
      }
      await LocalDb.endOffloadSession();
    });

    test('2b. after endOffloadSession the connection is NORMAL (1) '
        '(guard: holds today, must stay)', () async {
      await LocalDb.beginOffloadSession();
      await _commit(1, 50, token: 't');
      await LocalDb.endOffloadSession();
      expect(await _syncLevel(), 1);
    });

    test('2c. a throwing commit does not leak FULL past endOffloadSession',
        () async {
      await LocalDb.beginOffloadSession();
      expect(await _syncLevel(), 2, reason: 'harness check: session is FULL');
      final db = await LocalDb.instance;
      await db.execute('CREATE TRIGGER t_cursor_boom BEFORE INSERT ON sync_cursor '
          "WHEN NEW.name = 'strap_trim' BEGIN SELECT RAISE(ABORT, 'boom'); END");
      await expectLater(_commit(1, 50, token: 't'), throwsA(anything));
      await db.execute('DROP TRIGGER t_cursor_boom');
      await LocalDb.endOffloadSession();
      expect(await _syncLevel(), 1,
          reason: 'sticky-latch rule (AGENTS 4.3): the session ends on the '
              'failure path too');
    });

    test('2d. a commit OUTSIDE a session still runs at FULL, bracketed per '
        'commit (today\'s path)', () async {
      _counting = true;
      await _commit(1, 50, token: 't');
      _counting = false;

      final idx = (bool Function(_Ev) f) => _log.indexWhere(f);
      final full = idx((e) => e.sqlIs(r'pragma\s+synchronous\s*=\s*FULL'));
      final begin = idx((e) => e.sqlIs(r'^\s*BEGIN'));
      final commit = idx((e) => e.sqlIs(r'^\s*COMMIT'));
      final normal = idx((e) => e.sqlIs(r'pragma\s+synchronous\s*=\s*NORMAL'));
      expect(full, isNonNegative);
      expect(begin, greaterThan(full), reason: 'FULL is set BEFORE the txn opens');
      expect(commit, greaterThan(begin));
      expect(normal, greaterThan(commit), reason: 'NORMAL restored after COMMIT');
      expect(await _syncLevel(), 1);
    });

    // 3. Freshness rides in the batch transaction.
    test('3a. a failing freshness write rolls the whole batch back '
        '(freshness is inside the transaction)', () async {
      final db = await LocalDb.instance;
      await db.execute(
          'CREATE TRIGGER t_fresh_boom BEFORE INSERT ON compute_freshness '
          "WHEN NEW.\"key\" = 'capture' BEGIN SELECT RAISE(ABORT, 'boom'); END");

      await expectLater(_commit(1, 50, token: 't'), throwsA(anything));

      expect(await _count('samples'), 0,
          reason: 'the rows must roll back with the freshness row; today the '
              'batch is already committed when freshness fails');
      expect(await _count('sync_cursor', "name = 'counter_hw'"), 0,
          reason: 'and so must the cursor');
      expect(await _count('compute_freshness', "\"key\" = 'capture'"), 0);
    });

    test('3b. a failing cursor write leaves neither rows nor freshness '
        '(guard: holds today, must stay)', () async {
      final db = await LocalDb.instance;
      await db.execute('CREATE TRIGGER t_cursor_boom BEFORE INSERT ON sync_cursor '
          "WHEN NEW.name = 'strap_trim' BEGIN SELECT RAISE(ABORT, 'boom'); END");

      await expectLater(_commit(1, 50, token: 't'), throwsA(anything));

      expect(await _count('samples'), 0);
      expect(await _count('sync_cursor', "name = 'counter_hw'"), 0);
      expect(await _count('compute_freshness', "\"key\" = 'capture'"), 0);
    });

    test('3c. the capture-freshness select and write happen inside the batch '
        'transaction, not after it', () async {
      _counting = true;
      await _commit(1, 50, token: 't');
      _counting = false;

      final fresh = _log.where((e) => e.touches('compute_freshness')).toList();
      expect(fresh, isNotEmpty, reason: 'harness check: freshness is written');
      final outside = fresh.where((e) => e.txId == null).length;
      expect(outside, 0,
          reason: '$outside freshness call(s) ran outside the commit '
              'transaction (today: a select and an insert, 2 extra round trips)');
    });

    test('3d. the freshness row still carries the batch max record time '
        '(guard: holds today, must stay)', () async {
      await _commit(1, 50, token: 't');
      final row = await LocalDb.computeFreshness('capture');
      expect(row, isNotNull);
      expect(row!['payload_json'] as String,
          contains('"latest_raw_rec_ts":${_t0 + 50}'));
    });
  });

  group('B. HISTORY_END over a real database', () {
    final ts = _wallNow() - 3600;

    // 4. Ledger: one transaction per marker.
    test('4. the two post-ACK ledger upserts cost one commit, and both rows '
        'still land', () async {
      final r = _Rig();
      r.engine.debugClaimHistoryTask();
      await LocalDb.instance; // opened before counting: opening is not the cost
      _counting = true;
      r.rx(_historyStart());
      r.chunk(3, 0xB400, ts: ts, counter: 4000);
      await r.settle();
      _counting = false;

      expect(r.acks, hasLength(1), reason: 'harness check: the chunk was ACKed');
      final ackAt = _log.indexWhere((e) => e.mark == 'ack');
      expect(ackAt, isNonNegative);
      final after = _log.sublist(ackAt + 1);
      final commits = _commitsTouching(after, 'sync_ledger');
      expect(commits, lessThanOrEqualTo(1),
          reason: 'one marker costs at most one ledger commit after the ACK; '
              'today it is $commits (two separate upserts)');

      // Same content as before: the 'capture' row and the per-token row.
      final ledger = await LocalDb.syncLedger();
      final capture = ledger.where((e) => e['chunk_id'] == 'capture').toList();
      expect(capture, hasLength(1));
      expect(capture.single['status'], 'acknowledged');
      expect(capture.single['meta_json'] as String, contains('last_batch_token'));
      final tok = ledger.where((e) => (e['chunk_id'] as String).startsWith('batch:'));
      expect(tok, hasLength(1));
      expect(tok.single['status'], 'acked');
      expect(tok.single['meta_json'] as String, contains('"chunk_rows":3'));
    });

    // 5. Perf line.
    test('5. each HISTORY_END commit logs exactly one [perf] sync chunk line '
        'with per-chunk counts and timings', () async {
      final r = _Rig();
      r.engine.debugClaimHistoryTask();
      r.rx(_historyStart());
      r.chunk(3, 0xB500, ts: ts, counter: 5000);
      await r.settle();
      r.chunk(2, 0xB501, ts: ts + 100, counter: 5100);
      await r.settle();

      expect(r.acks, hasLength(2), reason: 'harness check: both chunks ACKed');
      final lines = r.logs.where((l) => l.contains('[perf] sync chunk')).toList();
      expect(lines, hasLength(2),
          reason: 'one line per HISTORY_END, no more, no fewer; saw $lines');

      final re = RegExp(r'\brecords=(\d+)\b.*\bbeats=(\d+)\b.*\bcommit_ms=(\d+)\b'
          r'.*\back_ms=(\d+)\b.*\bpost_ms=(\d+)\b');
      for (final l in lines) {
        expect(re.hasMatch(l), isTrue,
            reason: 'line must carry records= beats= commit_ms= ack_ms= '
                'post_ms= in that order: $l');
      }
      // Per chunk, not cumulative for the connection.
      expect(re.firstMatch(lines[0])!.group(1), '3');
      expect(re.firstMatch(lines[1])!.group(1), '2');
    });

    // 6. Invariant guards (must pass today and stay green).
    test('6a. the ACK is written only after the commit completed, and echoes '
        'the verbatim token (guard)', () async {
      final r = _Rig();
      r.engine.debugClaimHistoryTask();
      _counting = true;
      r.rx(_historyStart());
      r.chunk(3, 0xB600, ts: ts, counter: 6000);
      await r.settle();
      _counting = false;

      final commitEnd = _log.indexWhere((e) => e.mark == 'commit-end');
      final txnCommit = _log.indexWhere((e) => e.sqlIs(r'^\s*COMMIT'));
      final ack = _log.indexWhere((e) => e.mark == 'ack');
      expect(commitEnd, isNonNegative);
      expect(txnCommit, isNonNegative);
      expect(ack, greaterThan(commitEnd),
          reason: 'ACK must follow commitSyncBatch returning');
      expect(ack, greaterThan(txnCommit));
      expect(r.acks.single.take(9).toList(), [
        0x01,
        0x00, 0xB6, 0x00, 0x00, // token u32 LE
        0x18, 0x00, 0x00, 0x00, // batch id u32 LE
      ]);
    });

    test('6b. a commit that throws produces no ACK and no acked ledger row '
        '(guard)', () async {
      final db = await LocalDb.instance;
      await db.execute('CREATE TRIGGER t_cursor_boom BEFORE INSERT ON sync_cursor '
          "WHEN NEW.name = 'strap_trim' BEGIN SELECT RAISE(ABORT, 'boom'); END");
      final r = _Rig();
      r.engine.debugClaimHistoryTask();
      r.rx(_historyStart());
      r.chunk(3, 0xB601, ts: ts, counter: 6100);
      await r.settle();

      expect(r.acks, isEmpty, reason: 'no ACK for a chunk that rolled back');
      expect(await _count('samples'), 0, reason: 'harness check: it rolled back');
      final ledger = await LocalDb.syncLedger();
      expect(
          ledger.where((e) => e['status'] == 'acked' || e['status'] == 'acknowledged'),
          isEmpty);
      expect(r.logs.where((l) => l.contains('[perf] sync chunk')), isEmpty,
          reason: 'a failed commit is not a completed chunk');
    });

    // The engine brackets the session around the offload (plan 2, test 1/2).
    test('7. the engine holds FULL for the whole offload and releases it on '
        'COMPLETE and on a mid-offload disconnect', () async {
      final r = _Rig();
      r.engine.debugClaimHistoryTask();
      r.rx(_historyStart());
      r.chunk(3, 0xB700, ts: ts, counter: 7000);
      await r.settle();
      expect(r.acks, hasLength(1), reason: 'harness check: chunk ACKed');
      expect(r.engine.offloadActive, isTrue,
          reason: 'harness check: still mid-offload after the first chunk');
      expect(await _syncLevel(), 2,
          reason: 'FULL is held for the offload, not toggled per chunk');

      // COMPLETE may auto-continue into a new history task (rows banked, trim
      // advanced), so the offload can still be active here. Whatever the
      // engine decided, the session follows it: FULL exactly while offloading.
      r.rx(_historyComplete());
      await r.settle();
      expect(await _syncLevel(), r.engine.offloadActive ? 2 : 1,
          reason: 'FULL exactly while an offload is active');

      // Second offload, ended by a link drop instead of COMPLETE.
      r.engine.debugClaimHistoryTask();
      r.rx(_historyStart());
      r.chunk(2, 0xB701, ts: ts + 100, counter: 7100);
      await r.settle();
      expect(await _syncLevel(), 2,
          reason: 'harness check: the new offload holds FULL again');
      await r.engine.disconnect();
      await r.settle();
      expect(await _syncLevel(), 1,
          reason: 'a dropped link must not leave FULL latched (AGENTS 4.3)');
    });
  });
}
