// Test-only bridge for pre-2.5 suites. Legacy fixture rows are absorbed before
// invoking the new command owner; production has no natural-key writers.
import 'package:sqflite/sqflite.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/sleep_block_store.dart';
import 'package:openstrap_edge/data/sleep_editor.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';

abstract final class TestSleepWrites {
  static Future<void> absorbFixtures(DatabaseExecutor tx) async {
    final existing=await tx.query('sleep_block');
    final naps=[for(final n in await tx.query('sleep_nap'))
      if(!existing.any((b)=>b['kind']=='nap' && b['owner_day']==n['day_id'] && b['start_ts']==n['start_ts'])) n];
    final mains=[for(final n in await tx.query('sleep_override'))
      if(!existing.any((b)=>b['kind']=='main' && b['owner_day']==n['day_id'])) n];
    await SleepBlockStore.absorb(tx,overrides:mains,naps:naps,mode:AbsorbMode.backfill);
  }
  // A fixture for an already stored legacy assertion, not a command receipt.
  static Future<void> seedLegacyMain({required String dayId,required int onsetTs,
    required int offsetTs,required String source}) async {
    await (await LocalDb.instance).transaction((tx) async {
      await SleepBlockStore.absorb(tx,overrides:[{'day_id':dayId,'onset_ts':onsetTs,
        'offset_ts':offsetTs,'source':source,'created_at':1}],naps:[],mode:AbsorbMode.backfill);
      await SleepBlockStore.projectForTest(tx,{dayId});
    });
  }
  static Future<NapResolution?> putNapEdit({required String dayId,required int startTs,
      required int endTs,required String source,Transaction? transaction,SleepMergeAuthorization? merge}) async {
    Future<NapResolution?> write(Transaction tx) async {
      await absorbFixtures(tx);
      if(source=='legacy') {
        await SleepBlockStore.absorb(tx,overrides:[],naps:[{'day_id':dayId,'start_ts':startTs,'end_ts':endTs,
          'source':source,'created_at':1,'payload_json':null}],mode:AbsorbMode.backfill);
        await SleepBlockStore.projectForTest(tx,{dayId}); return null;
      }
      final read=await SleepBlockStore.read(tx,dayId);
      final existing=read.entries.where((e)=>e.kind==SleepBlockKind.nap && e.startTs==startTs && !e.removed).firstOrNull;
      final c=source=='rejected'?RemoveBlock(existing?.ref??DetectedNapRef(dayId,startTs,endTs)):
        existing==null?AddNap(startTs,endTs,source:source):SetIntervals(existing.ref,startTs,endTs);
      final plan=await SleepBlockStore.plan(tx,dayId,[c]);
      final p=await SleepBlockStore.preflight(tx,plan);
      requireSleepSaved(await SleepBlockStore.apply(plan,tx:tx,merge:merge));
      if(p is! SleepProposalMergeRequired) return null;
      final proposal=p.proposal;
      return (startTs:proposal.startTs,endTs:proposal.endTs,extended:[for(final b in proposal.participants)
        (kind:b.kind==SleepBlockKind.main?'main_sleep':'nap',day:b.day,startTs:b.startTs,endTs:b.endTs)]);
    }
    return transaction==null?await (await LocalDb.instance).transaction(write):await write(transaction);
  }
  static Future<void> putSleepOverride({required String dayId,required int onsetTs,
    required int offsetTs,required String source,SleepMergeAuthorization? merge}) async {
    await (await LocalDb.instance).transaction((tx) async {
      await absorbFixtures(tx);
      final read=await SleepBlockStore.read(tx,dayId);
      final existing=read.entries.where((e)=>e.kind==SleepBlockKind.main).firstOrNull;
      final c=source=='rejected'?RemoveBlock(existing?.ref??NoDetectionMainRef(dayId)):
        existing==null?AddMain(dayId,onsetTs,offsetTs):SetIntervals(existing.ref,onsetTs,offsetTs);
      requireSleepSaved(await SleepBlockStore.apply(await SleepBlockStore.plan(tx,dayId,[c]),tx:tx,merge:merge));
      if(source=='confirmed') { requireSleepSaved(await SleepBlockStore.apply(
        await SleepBlockStore.plan(tx,dayId,[ConfirmMain(dayId,onsetTs,offsetTs)]),tx:tx)); }
    });
  }
  static Future<Map<String,int>> applyNapWork() async {
    final revisions=<String,int>{};
    for(final job in await SleepEditStore.pending(retryFailed:true)) {
      if(job.mainPending) continue;
      if((await SleepEditStore.status(job.day))!['nap_applied_revision']!=job.napRevision) {
        await LocalDb.recomposeNaps(job.day,job.napRevision);
      }
      revisions[job.day]=job.napRevision;
    }
    return revisions;
  }
  static Future<void> finishNapWork(Map<String,int> revisions) async {
    for(final job in await SleepEditStore.pending(retryFailed:true)) {
      if(revisions[job.day]==job.napRevision && !job.mainPending) {
        await SleepEditStore.advance(job,SleepEditPhase.done);
      }
    }
  }
  static Future<bool> refreshNapReviews(DerivationEngine engine,Profile profile) async {
    final jobs=(await SleepEditStore.pending(retryFailed:true)).where((j)=>!j.mainPending).toList();
    if(jobs.isEmpty) return true;
    final revisions=await applyNapWork();
    try {
      final last=jobs.last;
      if(!await engine.refreshNapEdits(profile,last.day,last.napRevision)) return false;
      await finishNapWork(revisions);return true;
    } catch (_) { return false; }
  }
  static Future<bool> napOverlapsMainSleep(int start,int end) async {
    await absorbFixtures(await LocalDb.instance);
    return (await SleepBlockStore.live(await LocalDb.instance,start,end)).any((b)=>b.kind==SleepBlockKind.main && b.startTs<end && b.endTs>start);
  }
  static Future<void> deleteNapEdit(String day,int startTs,{SleepMergeAuthorization? merge}) async {
    await absorbFixtures(await LocalDb.instance);
    requireSleepSaved(await LocalRepositoryImpl(getProfileMap:()=>{}).deleteNap(day,startTs,merge:merge));
  }
  static Future<void> deleteSleepOverride(String day) async => (await LocalDb.instance).transaction((tx) async {
    await absorbFixtures(tx);
    requireSleepSaved(await SleepBlockStore.apply(await SleepBlockStore.plan(tx,day,[ClearMain(day)]),tx:tx));
  });
}
