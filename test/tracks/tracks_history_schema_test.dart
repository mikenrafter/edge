// P8a item 1, storage side: schema v85 adds the daily-intake columns to
// track_setup_history. Additive migration, full backup restore, rebuild
// salvage, selected-day export and deleteDays must all carry or keep them.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/wake/wake_night_context_db.dart';
import '../backup/backup_support.dart';

// The shipped v84 shape of the table, copied from git (tracks_schema.dart at
// bd0b7cd8), NOT from the new code, so the migration test starts from the real
// previous head.
const _v84Table =
    'CREATE TABLE track_setup_history ('
    'id TEXT PRIMARY KEY, track_id TEXT NOT NULL, start_date TEXT NOT NULL, '
    'end_date TEXT NOT NULL, done INTEGER NOT NULL CHECK (done IN (0,1)), '
    'CHECK (start_date <= end_date))';

Map<String, Object?> _row(
  String id,
  String start,
  String end, {
  int done = 1,
  int? minute,
  double? amount,
  String? unit,
  String trackId = 'med:x',
}) => {
  'id': id,
  'track_id': trackId,
  'start_date': start,
  'end_date': end,
  'done': done,
  'approx_minute': minute,
  'amount': amount,
  'amount_unit': unit,
};

Future<Set<String>> _columns(Database db) async => {
  for (final c in await db.rawQuery('PRAGMA table_info(track_setup_history)'))
    c['name'] as String,
};

Future<int> _userVersion(Database db) async =>
    (await db.rawQuery('PRAGMA user_version')).first.values.first as int;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUp(() async => env = await BackupEnv.create('tracks_history_schema_p8a.db'));
  tearDown(() async {
    await env.dispose();
    for (final f in Directory(env.dbDir).listSync()) {
      if (f is File &&
          p.basename(f.path).startsWith('tracks_history_schema_p8a.db.')) {
        f.deleteSync();
      }
    }
  });

  Future<void> rewindToV84(List<Map<String, Object?>> oldRows) async {
    await LocalDb.close();
    final legacy = await databaseFactory.openDatabase(
      p.join(env.dbDir, LocalDb.dbName),
    );
    await legacy.execute('DROP TABLE track_setup_history');
    await legacy.execute(_v84Table);
    for (final r in oldRows) {
      await legacy.insert('track_setup_history', r);
    }
    await legacy.execute('PRAGMA user_version = 84');
    await legacy.close();
  }

  group('migration', () {
    // why: schema 85 must be the next free version and purely additive. The
    // v84 rows (the only history that exists in the field) keep every value.
    // proves: CLAIM(range-columns), additive idempotent migrations (AGENTS 3)
    test('v84 history gains three nullable columns and keeps its rows', () async {
      await LocalDb.instance;
      await rewindToV84([
        {
          'id': 'old-yes',
          'track_id': 'med:x',
          'start_date': '2026-01-01',
          'end_date': '2026-01-31',
          'done': 1,
        },
        {
          'id': 'old-no',
          'track_id': 'med:x',
          'start_date': '2026-02-01',
          'end_date': '2026-02-10',
          'done': 0,
        },
      ]);
      final db = await LocalDb.instance;
      expect(LocalDb.schemaVersion, greaterThanOrEqualTo(85));
      expect(await _userVersion(db), LocalDb.schemaVersion);
      expect(
        await _columns(db),
        containsAll(['approx_minute', 'amount', 'amount_unit']),
      );
      expect(
        await db.query('track_setup_history', orderBy: 'start_date'),
        [
          _row('old-yes', '2026-01-01', '2026-01-31'),
          _row('old-no', '2026-02-01', '2026-02-10', done: 0),
        ],
        reason: 'old rows keep their values; new columns are NULL (unknown)',
      );
      // The table-level CHECK survives the migration: it is still enforced.
      await expectLater(
        db.insert('track_setup_history', _row('bad', '2026-03-05', '2026-03-01')),
        throwsA(anything),
      );
      // Positive control: the new columns and the ongoing end are writable.
      await db.insert(
        'track_setup_history',
        _row('new', '2026-03-01', '9999-12-31', minute: 480, amount: 50, unit: 'mg'),
      );
      expect(await db.query('track_setup_history'), hasLength(3));
    });

    test('reopening after the migration changes nothing', () async {
      await LocalDb.instance;
      await rewindToV84([
        {
          'id': 'old',
          'track_id': 'med:x',
          'start_date': '2026-01-01',
          'end_date': '2026-01-31',
          'done': 1,
        },
      ]);
      final first = await (await LocalDb.instance).query('track_setup_history');
      await LocalDb.close();
      final again = await LocalDb.instance;
      expect(await again.query('track_setup_history'), first);
      expect(await _userVersion(again), LocalDb.schemaVersion);
    });

    test('a fresh install has the columns from the start', () async {
      final db = await LocalDb.instance;
      expect(
        await _columns(db),
        containsAll(['approx_minute', 'amount', 'amount_unit']),
      );
    });
  });

  group('carried by every data path', () {
    final ongoing = _row(
      'ongoing',
      '2026-10-20',
      '9999-12-31',
      minute: 495,
      amount: 2.5,
      unit: 'mg',
    );
    final notDone = _row('stopped', '2026-09-01', '2026-09-30', done: 0);

    // why: R2-7/S9 lesson: a table that restores without its new columns turns
    // a timed 50 mg history back into an unknown one. proves: restore parity.
    test('full backup restore returns every column, ongoing end included', () async {
      final db = await LocalDb.instance;
      await db.insert('track_setup_history', ongoing);
      await db.insert('track_setup_history', notDone);
      await env.seedData();
      final backup = await LocalDb.exportCopy();
      await env.wipe();
      await LocalDb.instance;
      await LocalDb.importFromDbFile(backup);
      expect(
        await (await LocalDb.instance).query(
          'track_setup_history',
          orderBy: 'start_date',
        ),
        [notDone, ongoing],
      );
    });

    // why: a backup written by the previous release has no intake columns. It
    // must restore as ranges with unknown time and amount, not fail.
    test('a v84 backup file restores with unknown intake', () async {
      final db = await LocalDb.instance;
      await db.insert('track_setup_history', _row('old', '2026-01-01', '2026-01-31'));
      await env.seedData();
      final backup = await LocalDb.exportCopy();
      final file = await databaseFactory.openDatabase(backup);
      await file.execute('DROP TABLE track_setup_history');
      await file.execute(_v84Table);
      await file.insert('track_setup_history', {
        'id': 'old',
        'track_id': 'med:x',
        'start_date': '2026-01-01',
        'end_date': '2026-01-31',
        'done': 1,
      });
      await file.close();
      await env.wipe();
      await LocalDb.instance;
      await LocalDb.importFromDbFile(backup);
      expect(
        await (await LocalDb.instance).query('track_setup_history'),
        [_row('old', '2026-01-01', '2026-01-31')],
      );
    });

    // why: a rebuild after a failed migration salvages hand-entered rows; the
    // wearer's "taken daily" history is the only copy of that knowledge.
    test('rebuild salvage keeps the intake columns', () async {
      final db = await LocalDb.instance;
      await db.insert('track_setup_history', ongoing);
      await LocalDb.close();
      final raw = await databaseFactory.openDatabase(
        p.join(env.dbDir, LocalDb.dbName),
      );
      // Same brick the recovery suite plants: the ladder throws on next open.
      await raw.execute('CREATE TABLE _raw_old (hex TEXT)');
      await raw.execute('PRAGMA user_version = 2');
      await raw.close();
      LocalDb.lastRebuild = null;
      final rebuilt = await LocalDb.instance;
      expect(LocalDb.lastRebuild, isNotNull, reason: 'the brick must trip a rebuild');
      expect(LocalDb.lastRebuild!.salvaged['track_setup_history'], 1);
      expect(await rebuilt.query('track_setup_history'), [ongoing]);
    });

    // why: S9 again, tightened by review P8a-P2. A selected-day export cannot
    // carry the real logs, absences and not-done overrides of days it did not
    // select, so it carries only the SELECTED days of each period (clipped,
    // never ongoing). The restored dates outside the selection stay unstated
    // instead of becoming nominal doses. An ongoing period that starts after
    // the day is not carried.
    test('selected-day export clips a period to the selected days', () async {
      final db = await LocalDb.instance;
      await db.insert('track_setup_history', ongoing);
      await db.insert(
        'track_setup_history',
        _row('future', '2026-11-05', '9999-12-31', minute: 60),
      );
      await db.insert('track_setup_history', notDone);
      await env.seedData();
      final days = await LocalDb.exportDaysDb({'2026-10-26'});
      await env.wipe();
      await LocalDb.instance;
      await LocalDb.importFromDbFile(days);
      expect(await (await LocalDb.instance).query('track_setup_history'), [
        _row('ongoing@2026-10-26', '2026-10-26', '2026-10-26',
            minute: 495, amount: 2.5, unit: 'mg'),
      ]);
    });

    test('two selected runs of one period come back as two clipped rows', () async {
      final db = await LocalDb.instance;
      await db.insert('track_setup_history', ongoing);
      await env.seedData();
      final days = await LocalDb.exportDaysDb({'2026-10-22', '2026-10-23', '2026-10-26'});
      await env.wipe();
      await LocalDb.instance;
      await LocalDb.importFromDbFile(days);
      expect(
        await (await LocalDb.instance).query('track_setup_history', orderBy: 'start_date'),
        [
          _row('ongoing@2026-10-22', '2026-10-22', '2026-10-23', minute: 495, amount: 2.5, unit: 'mg'),
          _row('ongoing@2026-10-26', '2026-10-26', '2026-10-26', minute: 495, amount: 2.5, unit: 'mg'),
        ],
      );
    });

    // why: the wake profile reads setup history by SQL range. "Since March"
    // must still cover tonight, and a period that ended must not.
    // proves: CLAIM(ongoing-sentinel)
    test('an ongoing done period reaches tonight\'s wake profile; an ended one does not', () async {
      final db = await LocalDb.instance;
      await db.insert('track_definition', {
        'id': 'reading',
        'payload_json': jsonEncode({
          'id': 'reading',
          'name': 'Reading',
          'kind': 'activity',
          'roles': ['own_sleep'],
          'systems': ['sleep'],
        }),
      });
      Future<Set<String>> tonight() async => (await loadWakeProfile(
        db,
        DateTime(2026, 10, 26),
        DateTime(2026, 10, 27),
        DateTime(2026, 10, 26, 23),
      )).userTrackIds;
      await db.insert(
        'track_setup_history',
        _row('ended', '2026-03-01', '2026-09-30', trackId: 'reading'),
      );
      expect(await tonight(), isEmpty, reason: 'the period ended before tonight');
      await db.insert(
        'track_setup_history',
        _row('since', '2026-10-01', '9999-12-31', trackId: 'reading'),
      );
      expect(await tonight(), {'reading'});
    });

    // why: end to end through the real store, isolate and SQLite: the period
    // feeds learning (three nights are counted as exposed with a dose inside
    // 24 h), yet NOTHING is written to track_event and nothing shows in the
    // event feed or the log list. Without the range the same nights count 0.
    // proves: CLAIM(range-exposure), "never persisted, never shown"
    test('a period feeds learning but never becomes a stored or listed event', () async {
      final db = await LocalDb.instance;
      final store = TracksStore(db);
      await store.saveDefinition(
        TrackDefinition(
          id: 'custom',
          name: 'Custom',
          icon: 'track',
          kind: 'consumed',
          unit: 'mg',
          systems: const ['hr'],
          kinetics: const TrackKinetics({
            'half_life_hours': TrackKineticField(value: 5),
            'onset_hours': TrackKineticField(value: 1),
          }),
        ),
      );
      for (var i = 0; i < 3; i++) {
        final onset = DateTime(2026, 5, 1 + i, 22);
        await db.insert('day_result', {
          'day_id': '2026-05-0${i + 2}',
          'algo_version': 118,
          'computed_at': 1,
          'finalized': 1,
          'partial': 0,
          'window_json': jsonEncode({
            'value': {
              'onset_ms': onset.millisecondsSinceEpoch,
              'offset_ms': onset
                  .add(const Duration(hours: 8))
                  .millisecondsSinceEpoch,
            },
          }),
          'payload_json': jsonEncode({
            'scalars': {'rhr': 58 + i * 2},
          }),
        });
      }
      final now = DateTime.utc(2026, 10, 27, 12);
      Map statisticsOf(Map<String, Map<String, Object?>> summary) =>
          ((summary['custom']!['statistics'] as Map)['hr'] as Map);
      expect(
        statisticsOf(await store.refreshLearning(asOf: now))['count'],
        0,
        reason: 'control: without a period no night has a dose or completeness',
      );
      await store.saveHistory('custom', [
        DoneRange(
          id: 'daily',
          trackId: 'custom',
          startDate: '2026-04-01',
          intake: const DailyIntake(
            approxMinute: 480,
            amount: DailyAmount(50, 'mg'),
          ),
        ),
      ]);
      final stats = statisticsOf(await store.refreshLearning(asOf: now));
      // hand: rhr 58, 60, 62 -> mean 60
      expect(stats['count'], 3);
      expect(stats['mean'], 60.0);
      expect(await db.query('track_event'), isEmpty);
      expect(
        await db.query('track_event_feed', where: "track_id = 'custom'"),
        isEmpty,
      );
      expect(await store.events(trackId: 'custom'), isEmpty);
    });

    // why: review P8a-P3. deleteDays removes a day's real logs and absences,
    // which were the overrides of the period. If the period kept covering the
    // day, learning would invent the nominal dose there. So the deleted days
    // leave the period (they become unstated, i.e. unknown) while every other
    // day, and the intake, stays.
    test('deleteDays removes the deleted days from periods and keeps the rest', () async {
      final db = await LocalDb.instance;
      await db.insert('track_setup_history', ongoing);
      await db.insert('track_setup_history', notDone);
      await LocalDb.deleteDays({'2026-10-26', '2026-09-15'});
      expect(
        await db.query('track_setup_history', orderBy: 'start_date'),
        [
          _row('stopped', '2026-09-01', '2026-09-14', done: 0),
          _row('stopped@2026-09-16', '2026-09-16', '2026-09-30', done: 0),
          _row('ongoing', '2026-10-20', '2026-10-25', minute: 495, amount: 2.5, unit: 'mg'),
          _row('ongoing@2026-10-27', '2026-10-27', '9999-12-31', minute: 495, amount: 2.5, unit: 'mg'),
        ],
      );
    });

    test('deleteDays on days no period covers leaves history untouched', () async {
      final db = await LocalDb.instance;
      await db.insert('track_setup_history', ongoing);
      await db.insert('track_setup_history', notDone);
      await LocalDb.deleteDays({'2026-10-19', '2026-08-01'});
      expect(await db.query('track_setup_history', orderBy: 'start_date'), [notDone, ongoing]);
    });
  });
}
