// Fixtures for the structural Pulse store tests (pulse_ep_*). Literal rows, no
// production helpers: a test that derives its expectation from the code under
// test proves nothing.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:sqflite/sqflite.dart';

const kPulseEpTables = [
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

Future<Set<String>> pulseEpTablesPresent(DatabaseExecutor db) async => {
  for (final r in await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'pulse_ep_%'",
  ))
    r['name'] as String,
};

/// Rows of a pulse_ep table; asserts the table exists first so a missing
/// structural table is an assertion failure, not an incidental SQL error.
Future<List<Map<String, Object?>>> pulseRows(
  DatabaseExecutor db,
  String table, {
  String? orderBy,
  String? where,
  List<Object?>? whereArgs,
}) async {
  expect(await pulseEpTablesPresent(db), contains(table), reason: '$table exists');
  return db.query(table, orderBy: orderBy, where: where, whereArgs: whereArgs);
}

/// One band record per second `second`, carrying [rr] (ms) beats.
(RawRecord, Sample) pulseRecord(int second, List<int> rr, {int counter = 0}) {
  final c = counter == 0 ? second : counter;
  return (
    RawRecord(
      counter: c,
      packetType: 47,
      hex: '2f${second.toRadixString(16)}',
      recTs: second,
      capturedAt: second * 1000,
    ),
    Sample(
      tsEpoch: second,
      counter: c,
      hr: 70,
      tsSubsec: 0,
      rrIntervalsMs: rr,
    ),
  );
}

Future<void> commitRecords(
  List<(RawRecord, Sample)> records, {
  ProcessingOrigin origin = ProcessingOrigin.recentSync,
  String deviceId = LocalDb.kPrimaryDeviceId,
}) => LocalDb.commitSyncBatch(
  [for (final r in records) r.$1],
  [for (final r in records) r.$2],
  processingOrigin: origin,
  deviceId: deviceId,
);

/// Seeds decoded_rr directly, as an install that predates the Pulse tables has it.
Future<void> seedRr(DatabaseExecutor db, String device, int second, int beats) async {
  for (var i = 0; i < beats; i++) {
    await db.insert('decoded_rr', {
      'device_id': device,
      'ts_ms': second * 1000,
      'rec_ts': second,
      'beat_index': i,
      'rr_ts_ms': second * 1000,
      'rr_ms': 800 + i,
    });
  }
}

/// One episode with every dependent row, written by literal SQL so the tests
/// do not depend on the store's own writers. Times are epoch ms; `day` labels
/// are LOCAL and supplied by the caller.
Future<void> seedEpisode(
  DatabaseExecutor db, {
  required String id,
  String source = '',
  required int startMs,
  required int endMs,
  required String startDay,
  String? endDay,
  String status = 'active',
  String state = 'owed',
  String? reason,
  String origin = 'recentSync',
  int revision = 1,
  String checksum = 'sum-1',
  List<int> payload = const [1, 2, 3],
  bool evidence = true,
  int createdMs = 1000,
}) async {
  expect(await pulseEpTablesPresent(db), kPulseEpTables.toSet(), reason: 'pulse_ep tables exist');
  await db.insert('pulse_ep_episode', {
    'id': id, 'source': source,
    'seed_start_ms': startMs, 'seed_end_ms': startMs + 600000,
    'start_ms': startMs, 'end_ms': endMs, 'ongoing': 0,
    'start_day': startDay, 'end_day': endDay ?? startDay,
    'first_seen_ms': createdMs, 'revision': revision, 'status': status,
  });
  await db.insert('pulse_ep_revision', {
    'episode_id': id, 'revision': revision, 'detector': 4, 'algo': 126,
    'input_stamp': 's', 'summary_json': '{"windows":2}',
    'evidence_status': evidence ? 'available' : 'expired',
    'checksum': checksum, 'created_ms': createdMs,
  });
  if (evidence) {
    await db.insert('pulse_ep_evidence', {
      'episode_id': id, 'revision': revision, 'payload': payload,
      'encoded_bytes': payload.length, 'expanded_bytes': payload.length,
      'retained_json': '[]', 'omitted_json': '[]', 'created_ms': createdMs,
    });
  }
  await db.insert('pulse_ep_outbox', {
    'episode_id': id, 'delivery_key': 'pulse-episode:$id', 'revision': revision,
    'state': state, 'reason': reason, 'origin': origin,
    'debt_ms': createdMs, 'source_ms': endMs,
  });
}
