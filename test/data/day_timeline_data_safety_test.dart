// Pilot day-timeline, spec Tests §3 (data safety), against a real SQLite
// database: the sleep editor's Save is one durable transaction (and an
// invalid one writes nothing); Discard is reversible for every detected type
// and Restore brings the item back, taking back only what its Discard wrote.
import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/data/review_restore.dart';
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const day = '2026-11-14';
int at(int h, [int m = 0, int d = 14]) =>
    DateTime(2026, 11, d, h, m).millisecondsSinceEpoch ~/ 1000;

void main() {
  late Directory dir;
  late Database db;
  late ActivityStore store;
  final oldName = LocalDb.dbName;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    dir = await Directory.systemTemp.createTemp('day-timeline-safety-');
    LocalDb.dbName = '${dir.path}/t.db';
    db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': at(0, 0, 1), 'legacy_migrated': 1});
    store = ActivityStore(db);
  });
  tearDown(() async {
    await LocalDb.close();
    LocalDb.dbName = oldName;
    await dir.delete(recursive: true);
  });

  Future<List<Map<String, Object?>>> rows(String t) => db.query(t, orderBy: 'rowid');

  group('§3 the sleep editor Save', () {
    test('writes the window and the naps in one durable transaction', () async {
      final plan = SleepEditPlan(day: day, window: (at(23, 10, 13), at(7, 5)), naps: [
        NapWrite(start: at(14), end: at(14, 40)),
      ]);
      await writeSleepEdit(db, plan);
      // Durable: read back through a NEW connection.
      await LocalDb.close();
      db = await LocalDb.instance;
      // WHY: the new durable runner must see editor assertions after restart.
      // catches: writing overrides without enqueuing their recomputation.
      final jobs = await rows('sleep_edit_job');
      expect(jobs.map((r) => [r['day_id'], r['phase']]), [[day, 'queued']]);
      final o = await rows('sleep_override');
      expect(o.single['day_id'], day);
      expect([o.single['onset_ts'], o.single['offset_ts'], o.single['source']],
          [at(23, 10, 13), at(7, 5), 'manual']);
      final n = await rows('sleep_nap');
      expect([n.single['start_ts'], n.single['end_ts'], n.single['source']],
          [at(14), at(14, 40), 'manual']);
    });

    // WHY: CLAIM(sleep-editor-receipt). A batch must publish assertions,
    // invalidation and every affected day together, including moved naps.
    // catches: queueing after commit or only queueing the selected night.
    test('batch receipt queues both nap dates and releases only its own pin atomically', () async {
      await db.insert('sync_cursor', {'name': LocalDb.kFrozenHeadlineCursor,
        'value': jsonEncode({'day': day, 'value': 71}), 'updated_at': 1},
        conflictAlgorithm: ConflictAlgorithm.replace);
      await db.transaction((tx) async {
        await writeSleepEditInTransaction(tx, SleepEditPlan(day: day,
          naps: [NapWrite(start: at(21), end: at(21, 30),
            fromStart: at(19, 0, 13), fromEnd: at(19, 30, 13))]));
        expect((await tx.query('sleep_edit_job', orderBy: 'day_id'))
          .map((r) => [r['day_id'], r['revision'], r['phase']]),
          [['2026-11-13', 1, 'queued'], [day, 1, 'queued']]);
        expect(await tx.query('sync_cursor', where: 'name = ?',
          whereArgs: [LocalDb.kFrozenHeadlineCursor]), isEmpty);
      });
      await LocalDb.close(); db = await LocalDb.instance;
      expect((await rows('sleep_edit_job')).length, 2);
      final before = await rows('sleep_edit_job');
      await expectLater(db.transaction((tx) async {
        await writeSleepEditInTransaction(tx, SleepEditPlan(day: day,
          window: (at(23, 0, 13), at(7))));
        throw StateError('rollback the surrounding batch');
      }), throwsStateError);
      expect(await rows('sleep_override'), isEmpty);
      expect(await rows('sleep_edit_job'), before);
    });

    // WHY: CLAIM(sleep-editor-entry). Rejecting/restoring main sleep must
    // preserve unrelated logged naps and durably queue the selected night.
    test('entry actions survive restart and preserve every unrelated nap', () async {
      await writeSleepEdit(db, SleepEditPlan(day: day,
        window: (at(23, 0, 13), at(7)), naps: [
          NapWrite(start: at(14), end: at(14, 30)),
          NapWrite(start: at(16), end: at(16, 40))]));
      final originalNaps = await rows('sleep_nap');
      Future<void> mainAction(SleepEntryAction action) => writeSleepEdit(db,
        SleepEditPlan(day: day, entry: SleepEntryEdit(main: true,
          start: at(23, 0, 13), end: at(7),
          source: action == SleepEntryAction.automatic ? 'rejected' : 'manual', action: action)));
      await mainAction(SleepEntryAction.notSleep);
      await LocalDb.close(); db = await LocalDb.instance;
      expect((await rows('sleep_override')).single['source'], 'rejected');
      expect(await rows('sleep_nap'), originalNaps);
      expect((await rows('sleep_edit_job')).single['revision'], 2);
      await mainAction(SleepEntryAction.automatic);
      expect(await rows('sleep_override'), isEmpty);
      expect(await rows('sleep_nap'), originalNaps);
      await writeSleepEdit(db, SleepEditPlan(day: day, entry: SleepEntryEdit(
        main: false, start: at(14), end: at(14, 30), source: 'manual',
        action: SleepEntryAction.notSleep)));
      await LocalDb.close(); db = await LocalDb.instance;
      final naps = await rows('sleep_nap');
      expect(naps.map((r) => [r['start_ts'], r['source']]), [
        [at(16), 'manual'], [at(14), 'rejected']]);
      expect((await rows('sleep_edit_job')).single['revision'], 4);
      expect((await rows('sleep_edit_job')).single['phase'], 'queued');
    });

    // WHY: CLAIM(sleep-editor-entry). A late action must not reject a newer
    // manual night just because it still has the same source name.
    test('stale entry actions refuse without changing the newer receipt', () async {
      await writeSleepEdit(db, SleepEditPlan(day: day, window: (at(23, 0, 13), at(7))));
      await writeSleepEdit(db, SleepEditPlan(day: day, window: (at(23, 30, 13), at(8))));
      final before = await rows('sleep_override');
      final jobs = await rows('sleep_edit_job');
      await expectLater(writeSleepEdit(db, SleepEditPlan(day: day,
        entry: SleepEntryEdit(main: true, start: at(23, 0, 13), end: at(7),
          source: 'manual', action: SleepEntryAction.notSleep))), throwsA(isA<SleepEditInvalid>()));
      expect(await rows('sleep_override'), before);
      expect(await rows('sleep_edit_job'), jobs);
    });

    // WHY: CLAIM(sleep-legacy-entry). A retained snapshot is persisted identity,
    // not a user assertion to erase. Reject/restore must preserve its measures.
    test('R1 legacy recalculate reject automatic retain snapshot after restart', () async {
      final snapshot = jsonEncode({'start': at(14), 'end': at(14, 30),
        'duration_min': 21, 'in_bed_min': 30, 'source': 'legacy', 'confidence': .8});
      await db.insert('sleep_nap', {'day_id': day, 'start_ts': at(14),
        'end_ts': at(14, 30), 'source': 'legacy', 'created_at': 1, 'payload_json': snapshot});
      await writeSleepEdit(db, SleepEditPlan(day: day,
        naps: [NapWrite(start: at(16), end: at(16, 40))]));
      final other = (await rows('sleep_nap')).last;
      Future<void> act(String source, SleepEntryAction action) => writeSleepEdit(db,
        SleepEditPlan(day: day, entry: SleepEntryEdit(main: false,
          start: at(14), end: at(14, 30), source: source, action: action)));
      await act('legacy', SleepEntryAction.recalculate);
      await act('legacy', SleepEntryAction.automatic);
      await act('legacy', SleepEntryAction.notSleep);
      await LocalDb.close(); db = await LocalDb.instance;
      expect((await rows('sleep_nap')).where((r) => r['start_ts'] == at(14)).single['source'], 'rejected');
      await act('rejected', SleepEntryAction.automatic);
      await LocalDb.close(); db = await LocalDb.instance;
      final naps = await rows('sleep_nap');
      final restored = naps.where((r) => r['start_ts'] == at(14)).single;
      expect([restored['source'], restored['payload_json']], ['legacy', snapshot]);
      expect(naps.where((r) => r['start_ts'] == at(16)).single, other);
      expect((await rows('sleep_edit_job')).single['revision'], 5);
    });

    // WHY: boundary edits must not erase a legacy detector snapshot. Automatic
    // restores original bounds and asleep minutes, including a moved start.
    for (final shift in [0, 10, 1440]) {
      test('R1 legacy moved by $shift minutes restores the preserved snapshot', () async {
        final snapshot = jsonEncode({'start': at(14), 'end': at(14, 30),
          'duration_min': 21, 'in_bed_min': 30, 'source': 'legacy', 'confidence': .8});
        await db.insert('sleep_nap', {'day_id': day, 'start_ts': at(14),
          'end_ts': at(14, 30), 'source': 'legacy', 'created_at': 1, 'payload_json': snapshot});
        await writeSleepEdit(db, SleepEditPlan(day: day,
          naps: [NapWrite(start: at(16), end: at(16, 40))]));
        final other = (await rows('sleep_nap')).last;
        await writeSleepEdit(db, SleepEditPlan(day: day, naps: [NapWrite(
          start: at(14, shift), end: at(14, shift + 40), fromStart: at(14),
          fromEnd: at(14, 30), fromSource: 'legacy')]));
        await LocalDb.close(); db = await LocalDb.instance;
        final edits = await ActivityStore.napEdits(db, shift == 1440 ? '2026-11-15' : day);
        final userNap = edits.where((e) => e.startSec == at(14, shift)).single;
        expect(userNap.snapshot, isNull, reason: 'a moved manual window has no measured split');
        await writeSleepEdit(db, SleepEditPlan(day: day, entry: SleepEntryEdit(
          main: false, start: at(14, shift), end: at(14, shift + 40), source: 'manual',
          action: SleepEntryAction.automatic)));
        await LocalDb.close(); db = await LocalDb.instance;
        final naps = await rows('sleep_nap');
        expect(naps, hasLength(2));
        final restored = naps.where((r) => r['start_ts'] == at(14)).single;
        expect([restored['source'], restored['end_ts']], ['legacy', at(14, 30)]);
        expect(jsonDecode(restored['payload_json'] as String), jsonDecode(snapshot));
        expect(naps.where((r) => r['start_ts'] == at(16)).single, other);
        expect({for (final j in await rows('sleep_edit_job')) j['day_id']: j['revision']},
          {day: 3, if (shift == 1440) '2026-11-15': 2});
      });
    }

    test('an invalid edit writes nothing at all', () async {
      final before = {for (final t in ['sleep_override', 'sleep_nap']) t: await rows(t)};
      for (final bad in [
        // Overlapping blocks.
        SleepEditPlan(day: day, window: (at(23, 0, 13), at(7)),
            naps: [NapWrite(start: at(6, 30), end: at(8))]),
        // A wake before the onset.
        SleepEditPlan(day: day, window: (at(7), at(6))),
        // A nap of 2 minutes.
        SleepEditPlan(day: day, naps: [NapWrite(start: at(14), end: at(14, 2))]),
      ]) {
        await expectLater(writeSleepEdit(db, bad), throwsA(isA<SleepEditInvalid>()));
      }
      for (final t in before.keys) {
        expect(await rows(t), before[t], reason: t);
      }
    });

    // why: R1 S1. Only exact replacements may be excluded; every unchanged
    // stored interval must be checked under the write transaction.
    // proves: CLAIM(sleep-edit-final-blocks)
    // catches: validating only the windows supplied by the editor.
    test('wheel-only and nap-only saves respect unchanged stored blocks', () async {
      await writeSleepEdit(db, SleepEditPlan(day: day,
          window: (at(23, 0, 13), at(7)),
          naps: [NapWrite(start: at(14), end: at(14, 30))]));
      final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'");
      final before = {for (final t in tables) t['name'] as String:
          await db.query(t['name'] as String)};
      for (final plan in [
        SleepEditPlan(day: day, window: (at(23, 0, 13), at(15))),
        SleepEditPlan(day: day, naps: [NapWrite(start: at(6), end: at(8))]),
        SleepEditPlan(day: day, naps: [NapWrite(start: at(14, 15), end: at(15))]),
        // The editor saw a detection, but another flow accepted that window.
        SleepEditPlan(day: day, naps: [NapWrite(start: at(16), end: at(16, 30),
            fromStart: at(14), fromEnd: at(14, 30))]),
        // A source row changed since the editor opened: do not exclude it.
        SleepEditPlan(day: day, naps: [NapWrite(start: at(14, 10), end: at(15),
            fromStart: at(14), fromEnd: at(14, 20), fromSource: 'manual')]),
      ]) {
        await expectLater(writeSleepEdit(db, plan), throwsA(isA<SleepEditInvalid>()));
        for (final t in before.keys) { expect(await db.query(t), before[t], reason: t); }
      }
      // Positive control: replacing the exact row permits an overlapping move.
      await writeSleepEdit(db, SleepEditPlan(day: day, naps: [NapWrite(
          start: at(14, 10), end: at(14, 40), fromStart: at(14),
          fromEnd: at(14, 30), fromSource: 'manual')]));
      expect((await rows('sleep_nap')).single['start_ts'], at(14, 10));
    });

    // why: R1 S1. Neighboring wake dates and bare/enveloped detected windows
    // are effective sleep too; an override replaces only its own day.
    test('nap-only plans respect neighboring effective main sleep and detected naps', () async {
      for (final envelope in [false, true]) {
        await db.delete('day_result');
        final window = {'onset_ms': at(23, 0, 14) * 1000,
            'offset_ms': at(7, 0, 15) * 1000};
        await db.insert('day_result', {'day_id': '2026-11-15', 'algo_version': 1,
            'payload_json': jsonEncode({'naps': {'value': [
              {'start': at(18), 'end': at(18, 30)}]}}),
            'window_json': jsonEncode(envelope ? {'value': window} : window),
            'computed_at': 1});
        for (final bounds in [(at(22, 45), at(23, 15)), (at(18, 15), at(18, 45))]) {
          await expectLater(writeSleepEdit(db, SleepEditPlan(day: day,
              naps: [NapWrite(start: bounds.$1, end: bounds.$2)])),
              throwsA(isA<SleepEditInvalid>()));
          expect(await rows('sleep_nap'), isEmpty);
        }
      }
      await writeSleepEdit(db, SleepEditPlan(day: '2026-11-15',
          window: (at(1, 0, 15), at(8, 0, 15))));
      await writeSleepEdit(db, SleepEditPlan(day: day,
          naps: [NapWrite(start: at(23), end: at(23, 30))]));
      expect((await rows('sleep_nap')).single['end_ts'], at(23, 30));
    });

    // why: R1 S1. A plan prepared before another transaction inserts a nap
    // must see that committed nap when its own transaction finally starts.
    test('concurrent insertion refuses a stale plan without changing any rows', () async {
      final entered = Completer<void>(), release = Completer<void>();
      final insert = db.transaction((tx) async {
        await tx.insert('sleep_nap', {'day_id': day, 'start_ts': at(14),
            'end_ts': at(14, 30), 'source': 'manual', 'created_at': 1});
        entered.complete();
        await release.future;
      });
      await entered.future;
      final save = expectLater(writeSleepEdit(db, SleepEditPlan(day: day,
          window: (at(23, 0, 13), at(15)))), throwsA(isA<SleepEditInvalid>()));
      release.complete();
      await insert;
      await save;
      expect(await rows('sleep_override'), isEmpty);
      expect((await rows('sleep_nap')).single['end_ts'], at(14, 30));
      expect(await rows('activity_review_days'), isEmpty);
    });

    // why: R1 S1. Two simultaneous saves must not both validate an empty
    // snapshot before either writes; validation belongs under the same lock.
    test('simultaneous overlapping plans serialize validation with their writes', () async {
      Future<bool> attempt(SleepEditPlan plan) async {
        try { await writeSleepEdit(db, plan); return true; }
        on SleepEditInvalid { return false; }
      }
      final saved = await Future.wait([
        attempt(SleepEditPlan(day: day, naps: [NapWrite(start: at(14), end: at(14, 30))])),
        attempt(SleepEditPlan(day: day, naps: [NapWrite(start: at(14, 15), end: at(14, 45))])),
      ]);
      expect(saved.where((ok) => ok), hasLength(1));
      final naps = await rows('sleep_nap');
      expect(naps, hasLength(1));
      expect(naps.single['source'], 'manual');
    });

    // why: missing nap input is an abstention envelope, not a JSON object.
    test('absent derived naps do not block a real reported window', () async {
      await db.insert('day_result', {'day_id': day, 'algo_version': 1,
          'payload_json': jsonEncode({'naps': {'value': '—'}}),
          'window_json': jsonEncode({'value': '—'}), 'computed_at': 1});
      await writeSleepEdit(db, SleepEditPlan(day: day,
          naps: [NapWrite(start: at(14), end: at(14, 30))]));
      expect((await rows('sleep_nap')).single['end_ts'], at(14, 30));
    });

    test('a moved detected nap is suppressed at its old window, never deleted', () async {
      await writeSleepEdit(db, SleepEditPlan(day: day, naps: [
        NapWrite(start: at(15), end: at(15, 50), fromStart: at(14), fromEnd: at(14, 40)),
      ]));
      final n = await rows('sleep_nap');
      expect({for (final r in n) (r['start_ts'], r['source'])},
          {(at(14), 'rejected'), (at(15), 'manual')});
    });

    test('a moved nap the user logged moves: its old row goes', () async {
      await LocalDb.putNapEdit(dayId: day, startTs: at(14), endTs: at(14, 40), source: 'manual');
      await writeSleepEdit(db, SleepEditPlan(day: day, naps: [
        NapWrite(start: at(16), end: at(16, 30), fromStart: at(14), fromEnd: at(14, 40),
            fromSource: 'manual'),
      ]));
      final n = await rows('sleep_nap');
      expect([for (final r in n) (r['start_ts'], r['source'])], [(at(16), 'manual')]);
    });
  });

  group('§3 discard is reversible for every type; Restore brings it back', () {
    Future<ActivitySuggestion> seed(ActivityKind kind, Map<String, dynamic> c) async {
      final made = await store.reconcile(kind, [c]);
      return made.single;
    }

    for (final kind in ActivityKind.values) {
      test('${kind.name}: discarded keeps the row; Restore makes it pending again', () async {
        final s = await seed(kind, {
          'id': 'x-${kind.name}',
          'start': at(12), 'end': at(12, 30),
          if (kind == ActivityKind.track) ...{'track_id': 'tr1', 'prompt': true},
        });
        await store.discard(s);
        final gone = await store.get(s.id);
        expect(gone!.status, ActivityReviewStatus.discarded, reason: 'never deleted');
        expect((await discardedOn(db, day)).activities.map((x) => x.id), [s.id]);
        expect(await db.transaction((tx) => ActivityStore.restore(tx, s.id)), isTrue);
        final back = (await store.get(s.id))!;
        expect(back.status, ActivityReviewStatus.pending);
        expect(back.revision, s.revision + 1,
            reason: 'a decision staged on the discarded row cannot apply');
        expect((await store.pending(nowTs: at(13))).map((x) => x.id), contains(s.id));
        expect((await discardedOn(db, day)).activities, isEmpty);
        // A second Restore is a no-op.
        expect(await db.transaction((tx) => ActivityStore.restore(tx, s.id)), isFalse);
      });
    }

    test('a track question: Restore takes back only the absence its Discard wrote', () async {
      final s = await seed(ActivityKind.track,
          {'id': 'q1', 'start': at(12), 'end': at(12, 30), 'track_id': 'tr1', 'prompt': true});
      await store.discard(s);
      expect(await rows('track_absence'), hasLength(1));
      await db.transaction((tx) => ActivityStore.restore(tx, s.id));
      expect(await rows('track_absence'), isEmpty);

      // An absence recorded elsewhere first is not this Discard's to remove.
      await db.insert('track_absence', {'track_id': 'tr2', 'date': day});
      final q2 = await seed(ActivityKind.track,
          {'id': 'q2', 'start': at(13), 'end': at(13, 30), 'track_id': 'tr2', 'prompt': true});
      await store.discard(q2);
      await db.transaction((tx) => ActivityStore.restore(tx, q2.id));
      expect([for (final r in await rows('track_absence')) r['track_id']], ['tr2']);
    });

    test('a skipped marked moment: Restore unanswers it; a real answer is untouched', () async {
      await LocalDb.putMomentLabel(MomentLabel(date: day, hhmm: '09:15', answeredAtMs: 1));
      await LocalDb.putMomentLabel(
          MomentLabel(date: day, hhmm: '10:00', label: 'meal', answeredAtMs: 1));
      final d = await discardedOn(db, day);
      expect(d.moments.map((m) => m.key), ['$day 09:15']);
      expect(await db.transaction((tx) => restoreSkippedMoment(tx, d.moments.single)), isTrue);
      expect([for (final r in await rows('moment_label')) r['hhmm']], ['10:00']);
      expect(await db.transaction((tx) => restoreSkippedMoment(tx, const SkippedMoment(day, '10:00'))),
          isFalse);
    });

    test('a removed glass: Restore puts its ml back and makes it reviewable again', () async {
      await LocalDb.logAssumedWater(date: day, atMin: 600, ml: 250, loggedAtMs: 1);
      Future<double?> water() async => ((await db.query('journal_metric',
              where: 'date = ? AND field = ?', whereArgs: [day, 'water_ml']))
          .firstOrNull?['value'] as num?)?.toDouble();
      expect(await water(), 250);
      await LocalDb.removeAssumedWater(
          (await LocalDb.assumedWater(date: day)).single);
      expect(await water(), isNull);
      final d = await discardedOn(db, day);
      expect(d.glasses.single.ml, 250);
      expect(await db.transaction((tx) => restoreRemovedGlass(tx, d.glasses.single)), isTrue);
      expect(await water(), 250);
      final g = (await db.query('assumed_water')).single;
      expect([g['state'], g['ml']], [AssumedState.assumed.name, 250.0]);
      expect((await discardedOn(db, day)).glasses, isEmpty);
    });
  });
}
