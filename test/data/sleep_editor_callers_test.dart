import '../support/sleep_writes.dart';
// Sleep structural phase 2: the defined refusal of EVERY caller of the two
// table writers, the explicit Merge command, the typed editor commands and the
// draft invalidation fence.
//
// CLAIM(sleep-block-separation), CLAIM(sleep-block-explicit-merge),
// CLAIM(sleep-editor-final-blocks), CLAIM(sleep-editor-draft-generation).
// Real SQLite; each case says what it catches.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/sleep_draft_fence.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';
import 'package:openstrap_edge/data/sleep_block_store.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_apply.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/gestures/moment_review_service.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/platform/tasker_moment_export.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/state/prefs.dart';

import '../support/moment_review_fakes.dart';

const _day = '2026-10-12';
final _a0 = DateTime(2026, 10, 12, 14, 0).millisecondsSinceEpoch ~/ 1000;
const _min = 60;

Future<String> _everything(Database db) async {
  final out = <String, Object?>{};
  for (final t in [
    'sleep_block',
    'sleep_nap',
    'sleep_override',
    'sleep_edit_job',
    'activity_review_days',
    'activity_review_meta',
    'activity_suggestions',
    'wake_confirmation',
    'moment_label',
  ]) {
    out[t] = [
      for (final r in await db.query(t)) {for (final e in r.entries) e.key: e.value}
    ];
  }
  return jsonEncode(out);
}

void main() {
  late Database db;
  late LocalRepositoryImpl repo;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'sleep_editor_callers_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    db = await LocalDb.instance;
    await db.update('activity_review_meta', {'activated_at': _a0 - 86400});
    repo = LocalRepositoryImpl(getProfileMap: () => {});
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  tearDown(() async {
    await LocalDb.close();
  });

  Future<void> rawNap(int start,int end,{String source='manual',String? payload,String day=_day}) async {
    await db.insert('sleep_nap',{'day_id':day,'start_ts':start,'end_ts':end,'source':source,
      'created_at':_a0,'payload_json':payload});
    await TestSleepWrites.absorbFixtures(db);
  }
  group('CLAIM(sleep-block-separation) every caller has a defined refusal',
      () {
    // WHY: an opt-in auto-log must never extend or insert a window behind the
    // person's back; the detection stays pending and says why.
    // Catches a confirm path that silently logs a nap 20 minutes from another.
    test('auto-log leaves a too-close nap pending with a merge reason',
        () async {
      await rawNap(_a0, _a0 + 40 * _min);
      final store = ActivityStore(db);
      final s = (await store.reconcile(ActivityKind.nap, [
        {
          'start': _a0 + 60 * _min,
          'end': _a0 + 100 * _min,
          'duration_min': 40,
          'in_bed_min': 40,
          'confidence': 0.9,
        },
      ])).single;
      final before = (await db.query('sleep_nap')).length;
      final logged = await store.autoLogNaps(
        sinceSec: _a0 - 3600,
        dataEdgeSec: _a0 + 10 * 3600,
        settleSec: 0,
        current: [
          {'start': s.startTs, 'end': s.endTs}
        ],
      );
      expect(logged, 0);
      expect(await db.query('sleep_nap'), hasLength(before));
      final row = (await db.query('activity_suggestions',
          where: 'id = ?', whereArgs: [s.id])).single;
      expect(row['status'], 'pending');
      expect('${row['details_json']}', contains('merge_required'));
    });

    // WHY: interactive confirmation returns the typed proposal for Merge or
    // Cancel instead of a generic error or a silent union.
    test('confirming a too-close nap throws the typed merge proposal',
        () async {
      await rawNap(_a0, _a0 + 40 * _min);
      final store = ActivityStore(db);
      final s = (await store.reconcile(ActivityKind.nap, [
        {
          'start': _a0 + 60 * _min,
          'end': _a0 + 100 * _min,
          'duration_min': 40,
          'in_bed_min': 40,
          'confidence': 0.6,
        },
      ])).single;
      final before = await _everything(db);
      Object? caught;
      try {
        await store.confirm(s, startTs: s.startTs, endTs: s.endTs);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<SleepMergeRequiredException>());
      final proposal = (caught as SleepMergeRequiredException).proposal;
      expect(proposal.startTs, _a0);
      expect(proposal.endTs, _a0 + 100 * _min);
      expect(await _everything(db), before);
    });

    // WHY: a track nap returns a NAMED error and writes neither the event nor
    // the window (no partial change).
    test('a track nap event too close to a nap raises the merge error',
        () async {
      await rawNap(_a0, _a0 + 40 * _min);
      final before = await _everything(db);
      final start = (_a0 + 60 * _min) * 1000;
      await expectLater(
        TracksStore(db).log(TrackEvent(
          id: 'nap-1',
          trackId: 'naps',
          date: _day,
          atMs: start,
          amount: 30,
          unit: 'minutes',
        )),
        throwsA(isA<SleepMergeRequiredException>()),
      );
      expect(await _everything(db), before);
    });

    // WHY: a marked-moment range stops BEFORE the window write and clears only
    // the attempting marker; both marks stay pending and the range is not
    // stranded as an in-progress Save.
    test('a range nap refused for spacing keeps both marks pending and '
        'is not left in progress', () async {
      final log = WriteLog();
      final ranges = _RefusingRangeWriter(log: log);
      final applier = MomentReviewApplier(
        writer: FakeAnswerWriter(log: log),
        assumedWriter: FakeGlassWriter(log: log),
        ranges: ranges,
        exporter: TaskerMomentExport(connectionOn: () => false),
      );
      final progress = <ReviewRange>[];
      final q = MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap);
      final report = await applier.apply(q,
          moments: const [mA, mB],
          glasses: const [],
          now: reviewNow,
          onProgress: (r) async => progress.add(r));
      expect(ranges.loggedNaps, isEmpty, reason: 'no window written');
      expect(report.remaining.ranges, hasLength(1));
      final left = report.remaining.ranges.single;
      expect(left.inProgress, isFalse,
          reason: 'a proven pre-window refusal clears the attempting marker');
      expect(left.startLabelled || left.endLabelled, isFalse);
      expect(report.failed, isNotEmpty);
    });

    // WHY: a persisted main edit that would sit within 29:59 of a nap returns
    // the proposal to its route and leaves the assertions untouched.
    test('a coordinator main edit near a nap carries the merge proposal',
        () async {
      await rawNap(_a0, _a0 + 40 * _min);
      final before = await _everything(db);
      final c = SleepCoordinator(
        persist: (day, s, e) => TestSleepWrites.putSleepOverride(
            dayId: day, onsetTs: s, offsetTs: e, source: 'manual'),
        derive: (day) async => {'recalculating': true},
        saveSchedule: (_) async {},
      );
      final r = await c.setOverride(
        _day,
        DateTime.fromMillisecondsSinceEpoch((_a0 - 9 * 3600) * 1000),
        DateTime.fromMillisecondsSinceEpoch((_a0 + 20 * _min - 40 * _min) * 1000),
      );
      c.dispose();
      expect(r.success, isFalse);
      expect(r.mergeProposal, isNotNull);
      expect(await _everything(db), before);
    });

    // WHY: confirming a window is non-interactive: refused, assertions left
    // alone. Rejecting only removes a block, so it is allowed near a nap.
    test('a confirmed main is refused near a nap but a rejection is allowed',
        () async {
      await rawNap(_a0, _a0 + 40 * _min);
      final before = await _everything(db);
      await expectLater(
        TestSleepWrites.putSleepOverride(
            dayId: _day,
            onsetTs: _a0 - 9 * 3600,
            offsetTs: _a0 - 20 * _min,
            source: 'confirmed'),
        throwsA(isA<SleepMergeRequiredException>()),
      );
      expect(await _everything(db), before);
      await TestSleepWrites.putSleepOverride(
          dayId: _day,
          onsetTs: _a0 - 9 * 3600,
          offsetTs: _a0 - 20 * _min,
          source: 'rejected');
      expect((await db.query('sleep_override')).single['source'], 'rejected');
    });
  });

  group('CLAIM(sleep-block-explicit-merge) a confirmed Merge writes', () {
    // WHY: the refusal tests are only right if an approved merge SUCCEEDS:
    // one live union, absorbed blocks suppressed (not duplicated), every
    // affected day queued, all in one transaction.
    test('the proposal from a refusal, approved, commits one live union',
        () async {
      await rawNap(_a0, _a0 + 40 * _min);
      SleepMergeProposal? proposal;
      try {
        await TestSleepWrites.putNapEdit(
            dayId: _day,
            startTs: _a0 + 60 * _min,
            endTs: _a0 + 100 * _min,
            source: 'manual');
      } on SleepMergeRequiredException catch (e) {
        proposal = e.proposal;
      }
      expect(proposal, isNotNull, reason: 'the writer must ask first');
      expect(proposal!.startTs, _a0);
      expect(proposal.endTs, _a0 + 100 * _min);
      await TestSleepWrites.putNapEdit(
          dayId: _day,
          startTs: _a0 + 60 * _min,
          endTs: _a0 + 100 * _min,
          source: 'manual',
          merge: proposal.authorization);
      final live = await db.query('sleep_nap',
          where: "source != 'rejected'");
      expect(live, hasLength(1));
      expect(live.single['start_ts'], _a0);
      expect(live.single['end_ts'], _a0 + 100 * _min);
    });

    // WHY: the connected set is TRANSITIVE: the new block is 25 minutes from
    // A and 25 minutes from C, so approving the merge pulls both in, keeps A as
    // the survivor (earliest nap), tombstones C naming A, and leaves ONE live
    // union. Catches a merge that duplicates blocks or forgets the chain.
    test('a transitive chain merges once and tombstones the absorbed block',
        () async {
      await rawNap(_a0, _a0 + 30 * _min);
      await rawNap(_a0 + 100 * _min, _a0 + 130 * _min);
      SleepMergeProposal? proposal;
      try {
        await TestSleepWrites.putNapEdit(
            dayId: _day,
            startTs: _a0 + 55 * _min,
            endTs: _a0 + 75 * _min,
            source: 'manual');
      } on SleepMergeRequiredException catch (e) {
        proposal = e.proposal;
      }
      expect(proposal, isNotNull);
      expect(proposal!.participants, hasLength(2));
      expect(proposal.survivor.startTs, _a0);
      expect(proposal.endTs, _a0 + 130 * _min);
      await TestSleepWrites.putNapEdit(
          dayId: _day,
          startTs: _a0 + 55 * _min,
          endTs: _a0 + 75 * _min,
          source: 'manual',
          merge: proposal.authorization);
      final live = await db.query('sleep_nap', where: "source != 'rejected'");
      expect(live, hasLength(1));
      expect((live.single['start_ts'], live.single['end_ts']),
          (_a0, _a0 + 130 * _min));
      final gone = (await db.query('sleep_nap', where: "source = 'rejected'")).single;
      expect(gone['start_ts'], _a0 + 100 * _min);
      final block=(await db.query('sleep_block',where:"state = 'merged'")).single;
      final survivor=(await db.query('sleep_block',where:"state = 'live'")).single;
      expect(block['merged_into'],survivor['id']);
      expect(await db.query('sleep_edit_job'), isNotEmpty);
    });

    // WHY: a block that arrived after the person chose Merge must not be
    // absorbed silently; the stale approval is refused with a fresh proposal.
    test('a stale approval is refused again', () async {
      await rawNap(_a0, _a0 + 40 * _min);
      SleepMergeProposal? first;
      try {
        await TestSleepWrites.putNapEdit(
            dayId: _day,
            startTs: _a0 + 60 * _min,
            endTs: _a0 + 100 * _min,
            source: 'manual');
      } on SleepMergeRequiredException catch (e) {
        first = e.proposal;
      }
      await rawNap(_a0 - 60 * _min, _a0 - 20 * _min); // arrived meanwhile
      final before = await _everything(db);
      await expectLater(
        TestSleepWrites.putNapEdit(
            dayId: _day,
            startTs: _a0 + 60 * _min,
            endTs: _a0 + 100 * _min,
            source: 'manual',
            merge: first!.authorization),
        throwsA(isA<SleepMergeRequiredException>()),
      );
      expect(await _everything(db), before);
    });
  });

  group('CLAIM(sleep-editor-final-blocks) typed commands', () {
    SleepEditorPlan plan(List<SleepEditorCommand> c,
            {Map<String, int?> revisions = const {}, int? generation}) =>
        SleepEditorPlan(
          dayId: _day,
          commands: c,
          expectedRevisions: revisions,
          draftGeneration: generation ?? SleepDraftFence.shared.generationOf(_day),
        );

    Future<void> confirmedNap(int s, int e) => rawNap(s, e,
        source: 'confirmed',
        payload: jsonEncode({
          'start': s,
          'end': e,
          'duration_min': 47,
          'in_bed_min': 55,
          'confidence': 0.6,
          'source': 'confirmed',
        }));

    // WHY: unchanged Save is "No change" with no write, even when the displayed
    // data already overlaps something. Catches a Save that rewrites timestamps.
    test('an unchanged plan is No change and writes nothing', () async {
      await confirmedNap(_a0, _a0 + 60 * _min);
      final before = await _everything(db);
      final out = await repo.saveSleepEditor(plan([
        SetIntervals(
            StoredBlockRef('legacy:nap:$_day:$_a0',0),
            _a0,
            _a0 + 60 * _min),
      ]));
      expect(out, isA<SleepNoChange>());
      expect(await _everything(db), before);
    });

    // WHY: a boundary edit commits, keeps the DETECTED snapshot from before the
    // first edit through a second edit, and queues the day, in one transaction.
    test('two edits keep the first detected snapshot', () async {
      await confirmedNap(_a0, _a0 + 60 * _min);
      StoredBlockRef ref(int s,int e) => StoredBlockRef('legacy:nap:$_day:$_a0',e==_a0+60*_min?0:1);
      var out = await repo.saveSleepEditor(plan([
        SetIntervals(ref(_a0, _a0 + 60 * _min), _a0, _a0 + 50 * _min),
      ]));
      expect(out, isA<SleepSaved>());
      out = await repo.saveSleepEditor(plan([
        SetIntervals(ref(_a0, _a0 + 50 * _min), _a0 + 5 * _min, _a0 + 50 * _min),
      ]));
      expect(out, isA<SleepSaved>());
      final block=(await db.query('sleep_block')).single;
      expect((block['detected_start'],block['detected_end']),(_a0,_a0+60*_min));
      expect(block['id'],'legacy:nap:$_day:$_a0');
      expect(await db.query('sleep_edit_job'), isNotEmpty);
    });

    // WHY: Reset to detected restores the snapshot bounds; a manual block has
    // no history so the same command is refused with the reason, not guessed.
    test('reset to detected needs history', () async {
      await rawNap(_a0, _a0 + 60 * _min); // manual: no history
      final out = await repo.saveSleepEditor(plan([
        ResetToDetected(StoredBlockRef('legacy:nap:$_day:$_a0',0)),
      ]));
      expect(out, isA<SleepRefused>());
      expect((out as SleepRefused).reason, SleepRefusalReason.missingHistory);
    });

    // WHY: a row changed under the plan is a stale refusal naming the entry,
    // never a silent overwrite.
    test('a changed row refuses the plan as stale', () async {
      await confirmedNap(_a0, _a0 + 60 * _min);
      final out = await repo.saveSleepEditor(plan([
        SetIntervals(
            StoredBlockRef('legacy:nap:$_day:$_a0',7), // the row ends at +60
            _a0,
            _a0 + 30 * _min),
      ]));
      expect(out, isA<SleepRefused>());
      expect((out as SleepRefused).reason, SleepRefusalReason.staleEntry);
    });

    // WHY: Add then Remove in ONE plan creates no tombstone and no job.
    test('add-then-remove in one plan writes nothing', () async {
      final before = await _everything(db);
      final out = await repo.saveSleepEditor(plan([
        AddNap(_a0,_a0+40*_min),
        RemoveBlock(DetectedNapRef(_day,_a0,_a0+40*_min)),
      ]));
      expect(out, isA<SleepNoChange>());
      expect(await _everything(db), before);
    });

    // WHY: Remove keeps a selectable tombstone; Restore brings the SAME bounds
    // back with its retained measurement, through the same writer.
    test('remove then restore returns the original block', () async {
      await confirmedNap(_a0, _a0 + 60 * _min);
      final ref = StoredBlockRef('legacy:nap:$_day:$_a0',0);
      expect(await repo.saveSleepEditor(plan([RemoveBlock(ref)])),
          isA<SleepSaved>());
      var read = await repo.readSleepEditor(_day);
      expect(read.entries.single.removed, isTrue);
      expect(await repo.saveSleepEditor(plan([RestoreRemoved(StoredBlockRef('legacy:nap:$_day:$_a0',1))])),
          isA<SleepSaved>());
      read = await repo.readSleepEditor(_day);
      expect(read.entries.single.removed, isFalse);
      expect((read.entries.single.startTs, read.entries.single.endTs),
          (_a0, _a0 + 60 * _min));
    });

    // WHY: a plan that creates a sub-30-minute gap is refused with the typed
    // proposal and writes nothing; the SAME plan with a Merge command commits.
    test('a too-close Set refuses; an approved Merge commits', () async {
      await rawNap(_a0, _a0 + 40 * _min);
      final before = await _everything(db);
      final out = await repo.saveSleepEditor(plan([
        AddNap(_a0+60*_min,_a0+100*_min),
      ]));
      expect(out, isA<SleepRefused>());
      final refused = out as SleepRefused;
      expect(refused.reason, SleepRefusalReason.mergeRequired);
      expect(refused.proposal, isNotNull);
      expect(await _everything(db), before);
      final merged = await repo.saveSleepEditor(plan([
        AddNap(_a0+60*_min,_a0+100*_min),
        MergeBlocks(refused.proposal!),
      ]));
      expect(merged, isA<SleepSaved>());
      expect(await db.query('sleep_nap', where: "source != 'rejected'"),
          hasLength(1));
    });

    // WHY: a nap moved across a date queues BOTH ownership dates.
    test('moving a nap across midnight queues the old and new day', () async {
      final late = DateTime(2026, 10, 12, 23, 10).millisecondsSinceEpoch ~/ 1000;
      await rawNap(late, late + 30 * _min);
      final out = await repo.saveSleepEditor(plan([
        SetIntervals(
            StoredBlockRef('legacy:nap:$_day:$late',0),
            late + 60 * _min,
            late + 90 * _min),
      ]));
      expect(out, isA<SleepSaved>());
      expect((out as SleepSaved).days, {_day, '2026-10-13'});
    });
  });

  // WHY C24/C25: one local start-day rule applies to screen and track callers.
  test('C24 Naps screen repository files a crossing nap under its start day',() async {
    final at=DateTime(2026,10,11,23,30).millisecondsSinceEpoch~/1000;
    expect(await repo.putNap(dayId:_day,startTs:at,endTs:at+3600,source:'manual'),isA<SleepSaved>());
    final r=(await db.query('sleep_block')).single;
    expect([r['owner_day'],r['owner_rule']],['2026-10-11',1]);
    expect(await db.query('sleep_nap',where:'day_id = ?',whereArgs:[_day]),isEmpty);
  });
  test('C25 track nap ignores event.date when the start belongs to yesterday',() async {
    final at=DateTime(2026,10,11,23,30).millisecondsSinceEpoch;
    await TracksStore(db).log(TrackEvent(id:'crossing',trackId:'naps',date:_day,atMs:at,amount:60,unit:'minutes'));
    expect((await db.query('sleep_block')).single['owner_day'],'2026-10-11');
  });
  // WHY C26: block + suggestion are one receipt, including a failed update.
  test('C26 Keep and auto-log link block ids atomically and supersede leaves them confirmed',() async {
    for(final auto in [false,true]) {
      for(final t in ['sleep_block','sleep_nap','sleep_edit_job','activity_suggestions']) { await db.delete(t); }
      final store=ActivityStore(db);
      final s=(await store.reconcile(ActivityKind.nap,[{'start':_a0,'end':_a0+2400,'confidence':0.9,'duration_min':32}])).single;
      if(auto) {
        expect(await store.autoLogNaps(sinceSec:_a0-1,dataEdgeSec:_a0+7200,settleSec:0,current:[{'start':_a0,'end':_a0+2400}]),1);
      } else { await store.confirm(s,startTs:_a0,endTs:_a0+2400); }
      final block=(await db.query('sleep_block')).single;
      final suggestion=(await db.query('activity_suggestions')).single;
      expect([suggestion['status'],suggestion['linked_id']],['confirmed',block['id']]);
      await ActivityStore.supersede(db,ActivityKind.nap,_a0,_a0+2400);
      expect((await db.query('activity_suggestions')).single['status'],'confirmed');
      final next=(await store.reconcile(ActivityKind.nap,[{'id':'crash','start':_a0+14400,'end':_a0+16800,'confidence':0.9}])).single;
      await db.execute("CREATE TRIGGER crash_suggestion BEFORE UPDATE ON activity_suggestions WHEN NEW.id='crash' AND NEW.status='confirmed' BEGIN SELECT RAISE(ABORT,'injected crash'); END");
      final before=await _everything(db);
      await expectLater(store.confirm(next,startTs:next.startTs,endTs:next.endTs,auto:auto),throwsA(isA<DatabaseException>()));
      expect(await _everything(db),before);
      await db.execute('DROP TRIGGER crash_suggestion');
      final kept=(await store.get(s.id))!;
      await expectLater(store.discard(kept),completes);
      expect((await store.get(s.id))!.status,ActivityReviewStatus.discarded);
      expect((await db.query('sleep_block',where:'id = ?',whereArgs:[block['id']])).single['state'],'removed');
      expect(await db.query('activity_review_days'),isEmpty);

    }
  });
  // WHY: repository read/save must expose typed references, not natural keys.
  test('C22 editor repository reads stable ids after a boundary edit',() async {
    await rawNap(_a0,_a0+2400);
    final read=await repo.readSleepEditor(_day);
    expect(read.entries.single.ref,isA<StoredBlockRef>());
    final ref=read.entries.single.ref as StoredBlockRef;
    expect(await repo.saveSleepEditor(SleepEditorPlan(dayId:_day,
      commands:[SetIntervals(ref,_a0+60,_a0+2400)],expectedRevisions:{_day:read.revision},draftGeneration:read.draftGeneration)),isA<SleepSaved>());
    final after=await repo.readSleepEditor(_day);
    expect(after.entries.single.id,ref.id);expect(after.entries.single.revision,ref.expectedRevision+1);
    await db.execute("CREATE TRIGGER fail_block BEFORE INSERT ON sleep_block BEGIN SELECT RAISE(ABORT,'storage failure'); END");
    final before=await _everything(db);
    await expectLater(repo.putNap(dayId:_day,startTs:_a0+18000,endTs:_a0+20400,source:'manual'),
      completion(isA<SleepFailed>()));
    expect(await _everything(db),before);
    await db.execute('DROP TRIGGER fail_block');

  });
  test('C23 editor preflight and Save carry the same merge authorization',() async {
    await rawNap(_a0,_a0+2400);
    final read=await repo.readSleepEditor(_day);
    final plan=SleepEditorPlan(dayId:_day,commands:[AddNap(_a0+3000,_a0+5400)],
      expectedRevisions:{_day:read.revision},draftGeneration:read.draftGeneration);
    final proposal=await SleepBlockStore.preflight(db,plan);
    final refused=await repo.saveSleepEditor(plan);
    expect(proposal,isA<SleepProposalMergeRequired>());expect(refused,isA<SleepRefused>());
    expect((refused as SleepRefused).proposal!.authorization,(proposal as SleepProposalMergeRequired).proposal.authorization);
  });

  // WHY: the legacy Naps action identifies the projection-visible interval.
  // A second removed block at the same start must not redirect that Restore.
  test('C27 natural-key restore selects the projection winner by update order',() async {
    await rawNap(_a0,_a0+3600,source:'confirmed');
    final original=(await db.query('sleep_block')).single['id'] as String;
    requireSleepSaved(await repo.putNap(dayId:_day,startTs:_a0,endTs:_a0+3600,source:'rejected'));
    requireSleepSaved(await repo.putNap(dayId:_day,startTs:_a0,endTs:_a0+2400,source:'manual'));
    final manual=(await db.query('sleep_block',where:'id <> ?',whereArgs:[original])).single['id'] as String;
    requireSleepSaved(await repo.putNap(dayId:_day,startTs:_a0,endTs:_a0+2400,source:'rejected'));
    await db.update('sleep_block',{'updated_at':100},where:'id = ?',whereArgs:[manual]);
    await db.update('sleep_block',{'updated_at':200},where:'id = ?',whereArgs:[original]);
    await SleepBlockStore.projectForTest(db,{_day});
    expect((await db.query('sleep_nap')).single['end_ts'],_a0+3600);
    requireSleepSaved(await repo.deleteNap(_day,_a0));
    expect((await db.query('sleep_block',where:"state = 'live'")).single['id'],original);
  });

  // WHY: editing a proposal is the first mutation of a known detection, so its
  // old day must retain a suppression and both days need nap recomposition.
  test('C28 edited Keep records original detection and queues both ownership days',() async {
    final old=DateTime(2026,10,12,23,30).millisecondsSinceEpoch~/1000;
    final store=ActivityStore(db);
    final s=(await store.reconcile(ActivityKind.nap,[{'start':old,'end':old+2400,'duration_min':32}])).single;
    await store.confirm(s,startTs:old+3600,endTs:old+6000,edited:true);
    final r=(await db.query('sleep_block')).single;
    expect([r['owner_day'],r['owner_rule'],r['source'],r['history'],r['detected_start'],r['detected_end'],r['detected_day']],
      ['2026-10-13',1,'manual','known',old,old+2400,_day]);
    final edits=await SleepBlockStore.napEdits(db,_day);
    expect(edits,hasLength(1));expect([edits.single.kind.name,edits.single.startSec,edits.single.endSec],['rejected',old,old+2400]);
    expect((await db.query('sleep_edit_job')).map((r)=>r['day_id']).toSet(),{_day,'2026-10-13'});
  });

  group('CLAIM(sleep-editor-draft-generation) invalidation', () {
    // WHY: an add-only plan has no revision row to go stale, so deleting the
    // day must advance the generation and refuse the old plan at commit.
    // Catches a Save that recreates a deleted day through an open route.
    test('an add-only plan is refused after Delete day', () async {
      final service = MomentReviewService();
      final gen = SleepDraftFence.shared.generationOf(_day);
      final plan = SleepEditorPlan(
        dayId: _day,
        commands: [
          AddNap(_a0,_a0+40*_min)
        ],
        expectedRevisions: const {_day: null},
        draftGeneration: gen,
      );
      service.stageSleepEditorDraft(_day, plan);
      expect(service.readSleepEditorDraft(_day).plan, isNotNull);
      service.clearDayDrafts({_day});
      SleepDraftFence.shared.advanceDays({_day});
      expect(service.readSleepEditorDraft(_day).plan, isNull);
      final before = await _everything(db);
      final out = await repo.saveSleepEditor(plan);
      expect(out, isA<SleepRefused>());
      expect((out as SleepRefused).reason, SleepRefusalReason.staleDraft);
      expect(await _everything(db), before);
    });

    // WHY: Delete everything clears every day's session draft and advances the
    // dataset generation, so older plans cannot be saved.
    test('clearAllDrafts drops every staged plan and advances the dataset',
        () async {
      final service = MomentReviewService();
      for (final d in ['2026-10-12', '2026-10-13']) {
        service.stageSleepEditorDraft(
            d,
            SleepEditorPlan(
                dayId: d,
                commands: const [],
                expectedRevisions: const {},
                draftGeneration: SleepDraftFence.shared.generationOf(d)));
      }
      final g = SleepDraftFence.shared.generationOf(_day);
      service.clearAllDrafts();
      SleepDraftFence.shared.advanceDataset();
      expect(service.readSleepEditorDraft('2026-10-12').plan, isNull);
      expect(service.readSleepEditorDraft('2026-10-13').plan, isNull);
      expect(SleepDraftFence.shared.generationOf(_day), greaterThan(g));
    });

    // WHY: Delete day clears queued review choices that belong to the deleted
    // day through the service, so a reopened screen cannot Save a decision for
    // a day that is gone.
    test('Delete day clears that day\'s queued decision', () async {
      final service = MomentReviewService.shared;
      await service.edit((q) => q.withDecision(
          ReviewKey.moment(mA), const ReviewDecision.skip()));
      service.clearDayDrafts({mA.date});
      expect(service.queue.decisionFor(ReviewKey.moment(mA)), isNull);
    });
  });

  group('CLAIM(timeline-draft-lifetime) kill after windowWritten', () {
    // WHY: a Save cut off after the window was written resumes at restart with
    // no second window and no repeat of an announcement already recorded.
    // Real Prefs round trip through a second service (the restart).
    test('restart finishes labels once and never re-announces', () async {
      final first = MomentReviewService();
      final started = MomentReviewQueue.empty
          .withRange(mA, mB, MomentChoice.nap)
          .withRangeProgress(MomentReviewQueue.empty
              .withRange(mA, mB, MomentChoice.nap)
              .ranges
              .single
              .copyWith(
                  windowWritten: true, startLabelled: false, announced: true));
      await first.edit((_) => started);

      final restarted = MomentReviewService(); // a new process
      expect(restarted.queue.ranges.single.windowWritten, isTrue);
      final log = WriteLog();
      final ranges = FakeRangeWriter(log: log);
      final sent = <Map<String, Object>>[];
      final applier = MomentReviewApplier(
        writer: FakeAnswerWriter(log: log),
        assumedWriter: FakeGlassWriter(log: log),
        ranges: ranges,
        exporter: TaskerMomentExport(
            connectionOn: () => true,
            emit: (e, x) async {
              sent.add(x);
              return true;
            }),
      );
      final report = await restarted.save(applier,
          moments: const [mA, mB], glasses: const [], now: reviewNow);
      expect(ranges.loggedNaps, isEmpty, reason: 'no second window');
      expect(sent, isEmpty, reason: 'announced was already recorded');
      expect(report.remaining.isEmpty, isTrue);
    });
  });
  // WHY B1: a stale Discard must never delete the main/older nap survivor.
  test('B1 Discard refuses a kept nap merged into another sleep',() async {
    for(final kind in [SleepBlockKind.main,SleepBlockKind.nap]) {
      for(final t in ['sleep_block','sleep_nap','sleep_override','sleep_edit_job','activity_suggestions']) { await db.delete(t); }
      await db.insert('sleep_block',SleepBlockStore.encodeBlock(
        SleepBlock(id:'survivor',kind:kind,day:_day,startTs:_a0,endTs:_a0+2400),
        source:SleepBlockSource.manual,state:SleepBlockState.live,createdAt:1));
      await SleepBlockStore.projectForTest(db,{_day});
      final store=ActivityStore(db);
      final suggestion=(await store.reconcile(ActivityKind.nap,[
        {'start':_a0+3600,'end':_a0+6000,'duration_min':40}])).single;
      SleepMergeProposal? proposal;
      try { await store.confirm(suggestion,startTs:_a0+3600,endTs:_a0+6000); }
      on SleepMergeRequiredException catch(e) { proposal=e.proposal; }
      expect(proposal,isNotNull);
      await store.confirm(suggestion,startTs:_a0+3600,endTs:_a0+6000,merge:proposal!.authorization);
      final kept=(await store.get(suggestion.id))!;
      final before=await db.query('sleep_block');
      await expectLater(store.discard(kept),throwsA(isA<ActivityReviewException>()));
      expect(await db.query('sleep_block'),before);
      expect((await store.get(suggestion.id))!.status,ActivityReviewStatus.confirmed);
      expect((await db.query('sleep_block',where:'id = ?',whereArgs:['survivor'])).single['state'],'live');
    }
  });
  // WHY CB1: Keep snapshots the refined proposal, while detection_* retains
  // every earlier envelope. That ordinary refinement must not lock Discard.
  // CLAIM(sleep-editor-callers).
  test('CB1 Discard accepts a kept nap after detection refinement',() async {
    final store=ActivityStore(db);
    final first=(await store.reconcile(ActivityKind.nap,[
      {'start':_a0,'end':_a0+2700,'duration_min':45}])).single;
    await store.reconcile(ActivityKind.nap,[
      {'start':_a0,'end':_a0+2400,'duration_min':40}]);
    final refined=(await store.get(first.id))!;
    expect(refined.id,first.id);
    await store.confirm(refined,startTs:refined.startTs,endTs:refined.endTs);
    final kept=(await store.get(first.id))!;
    // A later decided re-detection also widens only the evidence envelope.
    await store.reconcile(ActivityKind.nap,[
      {'start':_a0,'end':_a0+3000,'duration_min':50}]);
    final suggestion=(await db.query('activity_suggestions',where:'id = ?',whereArgs:[first.id])).single;
    final saved=(await db.query('sleep_block')).single;
    expect([suggestion['end_ts'],suggestion['detection_end'],saved['detected_end']],
      [_a0+2400,_a0+3000,_a0+2400]);
    Object? discardError;
    try { await store.discard(kept); } catch(error) { discardError=error; }
    expect(discardError,isNull,reason:'refining detection must not turn an ordinary kept nap into a merge');
    expect((await store.get(first.id))!.status,ActivityReviewStatus.discarded);
    expect((await db.query('sleep_block')).single['state'],'removed');
  });

}

/// A range writer whose nap write refuses for spacing, as the real one does.
class _RefusingRangeWriter extends FakeRangeWriter {
  _RefusingRangeWriter({super.log});

  @override
  Future<void> logNap(
      {required String dayId, required int startSec, required int endSec}) {
    throw SleepMergeRequiredException(SleepMergeProposal(
      survivor: SleepBlock(
          kind: SleepBlockKind.nap, day: dayId, startTs: 1, endTs: 2),
      absorbed: const [],
      startTs: startSec,
      endTs: endSec,
    ));
  }


}
