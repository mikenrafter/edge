// Sleep structural phase 2, W group (storage and writes): the table writers
// themselves enforce the 30-minute separation between ANY two sleep blocks, and
// a removed block keeps the origin a later write lands on.
//
// Real SQLite through the public writers. Each case states WHY and a plausible
// wrong implementation it catches. Owner decision 2026-11-17: a change that
// creates or narrows a gap under 30 minutes is refused unless the caller
// explicitly authorizes the merge; a kept or widened historical gap saves
// normally; exactly 30:00 is allowed.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart'
    show ActivityReviewException;

// A fixed local afternoon, far in the past so nothing here is "in the future".
final _a0 = DateTime(2026, 10, 12, 14, 0).millisecondsSinceEpoch ~/ 1000;
const _day = '2026-10-12';
const _min = 60;

/// Every application table a write could touch, as comparable JSON.
Future<String> _everything(Database db) async {
  final out = <String, Object?>{};
  for (final t in [
    'sleep_nap',
    'sleep_override',
    'sleep_edit_job',
    'activity_review_days',
    'activity_review_meta',
    'wake_confirmation',
    'activity_suggestions',
  ]) {
    final rows = await db.query(t);
    // activated_at is stamped lazily on first use; it is not a write.
    out[t] = [
      for (final r in rows) {for (final e in r.entries) e.key: e.value}
    ];
  }
  return jsonEncode(out);
}

void main() {
  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'sleep_editor_write_contract_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': _a0 - 86400});
  });
  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  Future<void> rawNap(int s, int e,
          {String source = 'manual', String? payload, String day = _day}) =>
      db.insert('sleep_nap', {
        'day_id': day,
        'start_ts': s,
        'end_ts': e,
        'source': source,
        'created_at': _a0,
        'payload_json': payload,
      });

  Future<void> rawMain(int s, int e,
          {String day = _day, String source = 'manual'}) =>
      db.insert('sleep_override', {
        'day_id': day,
        'onset_ts': s,
        'offset_ts': e,
        'source': source,
        'created_at': _a0,
      });

  Future<void> putNap(int s, int e, {String source = 'manual'}) =>
      LocalDb.putNapEdit(dayId: _day, startTs: s, endTs: e, source: source);

  group('CLAIM(sleep-block-separation) nap writer', () {
    // WHY: two blocks 29:59 apart are one sleep to the wearer; the owner wants
    // that decided by a person, never saved as two. Catches a writer that only
    // refuses overlap.
    test('a nap 29:59 after another is refused and nothing is written',
        () async {
      await rawNap(_a0, _a0 + 40 * _min);
      final before = await _everything(db);
      await expectLater(
        putNap(_a0 + 40 * _min + 30 * _min - 1, _a0 + 100 * _min),
        throwsA(isA<ActivityReviewException>()),
      );
      expect(await _everything(db), before);
    });

    // WHY: touching naps used to be silently unioned (grow mode). Catches an
    // implementation that keeps the silent union beneath the writer.
    test('touching naps are refused, not silently unioned', () async {
      await rawNap(_a0, _a0 + 40 * _min);
      final before = await _everything(db);
      await expectLater(
        putNap(_a0 + 40 * _min, _a0 + 90 * _min),
        throwsA(isA<ActivityReviewException>()),
      );
      expect(await _everything(db), before);
    });

    test('an overlapping nap is refused and the existing row is untouched',
        () async {
      await rawNap(_a0, _a0 + 40 * _min);
      final before = await _everything(db);
      await expectLater(
        putNap(_a0 + 20 * _min, _a0 + 90 * _min),
        throwsA(isA<ActivityReviewException>()),
      );
      expect(await _everything(db), before);
    });

    // WHY: the owner chose "under 1800 s", so exactly 30:00 is two blocks.
    // Catches an off-by-one (<=) that refuses a legal separate nap.
    test('exactly 30:00 apart saves as two separate rows', () async {
      await rawNap(_a0, _a0 + 40 * _min);
      await putNap(_a0 + 70 * _min, _a0 + 110 * _min);
      final rows = await db.query('sleep_nap', orderBy: 'start_ts');
      expect([for (final r in rows) r['start_ts']],
          [_a0, _a0 + 70 * _min]);
    });

    // WHY: a historical close pair stays visible and its far ends may move.
    // Catches a writer that refuses ANY row near another block.
    test('a far-end edit of a historical close pair saves normally',
        () async {
      await rawNap(_a0, _a0 + 40 * _min);
      await rawNap(_a0 + 60 * _min, _a0 + 100 * _min); // 20 min gap, historical
      await putNap(_a0 + 60 * _min, _a0 + 130 * _min); // later end only
      final r = await db.query('sleep_nap',
          where: 'start_ts = ?', whereArgs: [_a0 + 60 * _min]);
      expect(r.single['end_ts'], _a0 + 130 * _min);
    });

    // WHY: a gap that would shrink is "narrowed" and needs a decision, even
    // when the pair was already under 30 minutes.
    test('moving the near end of a historical close pair closer is refused',
        () async {
      await rawNap(_a0, _a0 + 40 * _min);
      await rawNap(_a0 + 60 * _min, _a0 + 100 * _min);
      final before = await _everything(db);
      // The first nap now ends 10 minutes later: the 20-minute gap narrows to 10.
      await expectLater(
        putNap(_a0, _a0 + 50 * _min),
        throwsA(isA<ActivityReviewException>()),
      );
      expect(await _everything(db), before);
    });

    // WHY: a removal only widens gaps, so it is never refused for spacing.
    test('removing a nap that sits in a close pair is allowed', () async {
      await rawNap(_a0, _a0 + 40 * _min);
      await rawNap(_a0 + 60 * _min, _a0 + 100 * _min);
      await putNap(_a0 + 60 * _min, _a0 + 100 * _min, source: 'rejected');
      final rows = await db.query('sleep_nap',
          where: "source = 'rejected'");
      expect(rows, hasLength(1));
    });
  });

  group('CLAIM(sleep-block-separation) main writer', () {
    // WHY: main and nap are the same kind of block for spacing. Catches a
    // check that only compares nap with nap.
    test('a nap 29:59 after a main sleep is refused', () async {
      await rawMain(_a0 - 9 * 3600, _a0 - 3600);
      final before = await _everything(db);
      await expectLater(
        putNap(_a0 - 3600 + 30 * _min - 1, _a0 - 3600 + 80 * _min),
        throwsA(isA<ActivityReviewException>()),
      );
      expect(await _everything(db), before);
    });

    // WHY: the override writer is the other table writer; a main edit that
    // brings the night to within 20 minutes of a nap is refused too.
    test('a main edit that closes within 20 minutes of a nap is refused',
        () async {
      await rawMain(_a0 - 9 * 3600, _a0 - 2 * 3600);
      await rawNap(_a0, _a0 + 40 * _min);
      final before = await _everything(db);
      await expectLater(
        LocalDb.putSleepOverride(
          dayId: _day,
          onsetTs: _a0 - 9 * 3600,
          offsetTs: _a0 - 20 * _min,
          source: 'manual',
        ),
        throwsA(isA<ActivityReviewException>()),
      );
      expect(await _everything(db), before);
    });

    // WHY: moving the main's far end later widens nothing it should not;
    // the near gap stays. Catches a writer that refuses all edits near a nap.
    test('a main edit that widens the gap to a nap saves', () async {
      await rawMain(_a0 - 9 * 3600, _a0 - 40 * _min);
      await rawNap(_a0, _a0 + 40 * _min); // 40 min gap
      await LocalDb.putSleepOverride(
        dayId: _day,
        onsetTs: _a0 - 9 * 3600,
        offsetTs: _a0 - 90 * _min,
        source: 'manual',
      );
      final r = (await db.query('sleep_override')).single;
      expect(r['offset_ts'], _a0 - 90 * _min);
    });
  });

  group('CLAIM(sleep-block-separation) detected main, real stored shape', () {
    // day_compute stores `SleepWindow.toJson()` UNWRAPPED in window_json
    // ({onset_ms, offset_ms, spt_sec}); only older fixtures used the
    // {value: {...}} envelope. Both shapes must be read.
    Future<void> detectedNight(int on, int off, {bool wrapped = false}) {
      final window = {'onset_ms': on * 1000, 'offset_ms': off * 1000, 'spt_sec': off - on};
      return LocalDb.putDayResult(
        dayId: _day,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode({
          'scalars': {'rhr': 53, 'readiness': 74, 'nap_min': 0},
          'naps': {'value': [], 'count': 0},
        }),
        windowJson: jsonEncode(wrapped ? {'value': window} : window),
        finalized: true,
        source: 'band',
        rhr: 53,
        readiness: 74,
        series: {'rhr': 53, 'readiness': 74, 'nap_min': 0},
      );
    }

    // WHY: with no user override the night is known only from the stored
    // window. Catches a lookup that reads only the wrapped shape: a nap logged
    // 10 minutes after waking would then save with no Merge prompt.
    test('a nap 10 minutes after an UNWRAPPED detected night needs a merge',
        () async {
      final wake = _a0 - 3600;
      await detectedNight(wake - 8 * 3600, wake);
      final before = await _everything(db);
      await expectLater(
        putNap(wake + 10 * _min, wake + 50 * _min),
        throwsA(isA<ActivityReviewException>()),
      );
      expect(await _everything(db), before);
    });

    test('the wrapped shape older fixtures used is still read', () async {
      final wake = _a0 - 3600;
      await detectedNight(wake - 8 * 3600, wake, wrapped: true);
      await expectLater(
        putNap(wake + 10 * _min, wake + 50 * _min),
        throwsA(isA<ActivityReviewException>()),
      );
    });

    // WHY: exactly 30:00 after the stored wake is two blocks, in the real shape.
    test('exactly 30:00 after an unwrapped detected night saves', () async {
      final wake = _a0 - 3600;
      await detectedNight(wake - 8 * 3600, wake);
      await putNap(wake + 30 * _min, wake + 70 * _min);
      expect(await db.query('sleep_nap'), hasLength(1));
    });
  });

  group('CLAIM(sleep-editor-nap-key) tombstone origin', () {
    // WHY: remove detected 14:00-15:00, add manual 14:00-14:40 at the SAME
    // start key, remove it again. The key is one row, so the detected
    // snapshot and the suppression it carried must survive every step.
    // Catches a writer that REPLACEs the tombstone with a null payload.
    test('remove detected, add manual at the same start, remove manual',
        () async {
      final detEnd = _a0 + 60 * _min;
      await rawNap(_a0, detEnd,
          source: 'confirmed',
          payload: jsonEncode({
            'start': _a0,
            'end': detEnd,
            'duration_min': 47,
            'in_bed_min': 55,
            'confidence': 0.6,
            'source': 'confirmed',
          }));
      await putNap(_a0, detEnd, source: 'rejected');
      await putNap(_a0, _a0 + 40 * _min); // manual over the tombstone
      var row = (await db.query('sleep_nap')).single;
      expect(row['source'], 'manual');
      expect(row['payload_json'], isNotNull,
          reason: 'the replacement row must carry the tombstone origin');
      expect('${row['payload_json']}', contains('$detEnd'));
      await putNap(_a0, _a0 + 40 * _min, source: 'rejected');
      row = (await db.query('sleep_nap')).single;
      expect(row['source'], 'rejected');
      final text = '${row['payload_json']}';
      expect(text, contains('$detEnd'), reason: 'detected end survives');
      expect(text, contains('47'), reason: 'detected measurement survives');
    });
  });
}
