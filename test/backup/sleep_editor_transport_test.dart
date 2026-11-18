// Sleep structural phase 2, T group (transport): how sleep assertions travel
// through import, and which review state survives an upgrade or an export.
//
// Owner decisions 2026-11-17: local-wins import with a report (regardless of
// either created_at); close pairs from one import source restore whole;
// review choices are session-only while in-progress Save progress stays
// durable (kPrefsNotBackedUp, "resume an interrupted Save").
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/gestures/moment_review_service.dart';
import 'package:openstrap_edge/gestures/moment_review_store.dart';
import 'package:openstrap_edge/state/prefs.dart';

const _day = '2026-10-12';
final _t0 = DateTime(2026, 10, 12, 14, 0).millisecondsSinceEpoch ~/ 1000;
const _min = 60;
const _momentA = PendingMoment(date: _day, hhmm: '08:00');
final _keyA = ReviewKey.moment(_momentA);

Future<String> _snapshot(String name) async {
  final dir = await databaseFactory.getDatabasesPath();
  final path = p.join(dir, name);
  if (File(path).existsSync()) File(path).deleteSync();
  await (await LocalDb.instance).execute("VACUUM INTO '$path'");
  return path;
}

Future<void> _clear(Database db) async {
  for (final t in ['sleep_override', 'sleep_nap', 'sleep_edit_job']) {
    await db.delete(t);
  }
}

Map<String, Object?> _nap(int s, int e,
        {String source = 'manual', int created = 1000, String? payload}) =>
    {
      'day_id': _day,
      'start_ts': s,
      'end_ts': e,
      'source': source,
      'created_at': created,
      'payload_json': payload,
    };

void main() {
  late Database db;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'sleep_editor_transport_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    db = await LocalDb.instance;
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  tearDown(() async {
    await LocalDb.close();
  });

  group('CLAIM(sleep-editor-transport) local wins', () {
    // WHY: owner S7. A backup newer than the local row used to win the whole
    // day. Catches the old newest-created_at rule for sleep overrides.
    test('a newer imported main override never replaces the local one',
        () async {
      await _clear(db);
      await db.insert('sleep_override', {
        'day_id': _day, 'onset_ts': 500, 'offset_ts': 600,
        'source': 'manual', 'created_at': 3000,
      });
      final backup = await _snapshot('sleep_newer_override.db');
      await db.update('sleep_override',
          {'onset_ts': 100, 'offset_ts': 200, 'created_at': 1000});
      await LocalDb.importFromDbFile(backup);
      final row = (await db.query('sleep_override')).single;
      expect(row['onset_ts'], 100);
      expect(row['offset_ts'], 200);
    });

    // WHY: a nap at the SAME key with other bounds is a conflict; the local row
    // stays whole whichever timestamp is newer.
    test('a newer imported nap on the same key never replaces the local row',
        () async {
      await _clear(db);
      await db.insert('sleep_nap', _nap(_t0, _t0 + 90 * _min, created: 3000));
      final backup = await _snapshot('sleep_same_key.db');
      await db.update('sleep_nap',
          {'end_ts': _t0 + 40 * _min, 'created_at': 1000});
      await LocalDb.importFromDbFile(backup);
      final row = (await db.query('sleep_nap')).single;
      expect(row['end_ts'], _t0 + 40 * _min);
    });

    // WHY: an imported nap overlapping a different local nap is refused, even
    // when the backup's copy is newer. Catches the old created_at check that
    // let a newer backup add a second row over the same afternoon.
    test('an imported nap overlapping a local nap is not copied', () async {
      await _clear(db);
      await db.insert('sleep_nap',
          _nap(_t0 + 10 * _min, _t0 + 70 * _min, created: 3000));
      final backup = await _snapshot('sleep_overlap.db');
      await db.update('sleep_nap',
          {'start_ts': _t0, 'end_ts': _t0 + 60 * _min, 'created_at': 1000});
      await LocalDb.importFromDbFile(backup);
      final rows = await db.query('sleep_nap');
      expect(rows, hasLength(1));
      expect(rows.single['start_ts'], _t0);
    });

    // WHY: a local removal marker answers the window; an imported live nap at
    // the same start must not bring it back.
    test('a local tombstone beats an imported live nap at the same start',
        () async {
      await _clear(db);
      await db.insert('sleep_nap', _nap(_t0, _t0 + 60 * _min, created: 3000));
      final backup = await _snapshot('sleep_tombstone.db');
      await db.update('sleep_nap',
          {'source': 'rejected', 'created_at': 1000});
      await LocalDb.importFromDbFile(backup);
      expect((await db.query('sleep_nap')).single['source'], 'rejected');
    });

    // Coverage already true on the base: identical rows skip, and keys missing
    // locally import. Kept so the new rule cannot break either.
    test('an identical row skips and an absent key imports', () async {
      await _clear(db);
      await db.insert('sleep_nap', _nap(_t0, _t0 + 60 * _min));
      await db.insert('sleep_nap',
          _nap(_t0 + 5 * 3600, _t0 + 5 * 3600 + 40 * _min));
      final backup = await _snapshot('sleep_identical.db');
      await db.delete('sleep_nap',
          where: 'start_ts = ?', whereArgs: [_t0 + 5 * 3600]);
      await LocalDb.importFromDbFile(backup);
      final rows = await db.query('sleep_nap', orderBy: 'start_ts');
      expect(rows, hasLength(2));
      expect(rows.first['created_at'], 1000);
    });

    // WHY: historical close pairs inside ONE source restore whole into an empty
    // database; the interactive spacing rule must not apply to import.
    test('a source-internal 20-minute nap pair restores whole', () async {
      await _clear(db);
      await db.insert('sleep_nap', _nap(_t0, _t0 + 40 * _min));
      await db.insert('sleep_nap',
          _nap(_t0 + 60 * _min, _t0 + 100 * _min));
      final backup = await _snapshot('sleep_close_pair.db');
      await _clear(db);
      await LocalDb.importFromDbFile(backup);
      expect(await db.query('sleep_nap'), hasLength(2));
    });
  });

  group('CLAIM(timeline-draft-lifetime) legacy queue pref', () {
    ReviewRange range(String a, String b,
            {bool attempting = false, bool windowWritten = false}) =>
        ReviewRange(
          choice: MomentChoice.nap,
          startKey: a,
          endKey: b,
          startSec: 100,
          endSec: 200,
          attempting: attempting,
          windowWritten: windowWritten,
        );

    // WHY: owner decision: review choices and unstarted ranges are
    // session-only; only a Save that already started keeps its progress.
    // Catches a store that still reloads every legacy decision.
    test('upgrade keeps only in-progress ranges from the stored queue',
        () async {
      final legacy = MomentReviewQueue(
        decisions: {_keyA: const ReviewDecision.skip()},
        ranges: [
          range('2026-10-12 08:00', '2026-10-12 08:30'),
          range('2026-10-12 09:00', '2026-10-12 09:30', windowWritten: true),
          range('2026-10-12 10:00', '2026-10-12 10:30', attempting: true),
        ],
      );
      Prefs.setString(MomentReviewStore.prefKey, jsonEncode(legacy.toJson()));
      final service = MomentReviewService();
      expect(service.queue.decisions, isEmpty);
      expect(service.queue.ranges.map((r) => r.startKey),
          ['2026-10-12 09:00', '2026-10-12 10:00']);
      // Idempotent: loading what the filter left changes nothing.
      expect(MomentReviewService().queue.ranges, hasLength(2));
    });

    // WHY: a decision made this session must not outlive the session.
    test('a new decision is not written to the stored queue', () async {
      final service = MomentReviewService();
      await service.edit((q) => q.withDecision(
          _keyA, const ReviewDecision.skip()));
      expect(const MomentReviewStore().load().decisions, isEmpty);
    });

    // WHY: the choice does not travel; the pref is device-bound recovery state.
    test('the queue pref is excluded from exports with its reason', () {
      expect(prefsKeyBackedUp(MomentReviewStore.prefKey), isFalse);
      expect(kPrefsNotBackedUp[MomentReviewStore.prefKey],
          'resume an interrupted Save');
      expect(kPrefTypes.containsKey(MomentReviewStore.prefKey), isFalse);
    });
  });
}
