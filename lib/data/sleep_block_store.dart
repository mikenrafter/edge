// Owner: SleepBlockStore owns sleep assertions and their legacy projections.
// Callers supply the executor and transaction. Storage errors propagate, so a
// failed write never leaves a half-written projection. Commands land in slice B.
import 'package:flutter/foundation.dart' show visibleForTesting, mapEquals;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../health/health_nap_export.dart';
import 'sleep_edit_store.dart';
import 'sleep_spacing.dart';
import '../compute/nap_edits.dart';
import 'db.dart';
import 'db/input_read_tracker.dart';
import 'day_label.dart';
import 'json_payload_lane.dart';
import 'sleep_draft_fence.dart';
import 'sleep_editor.dart';
import 'sleep_import_rules.dart';
import 'sleep_ownership.dart';

enum AbsorbMode { backfill, importFile }
enum SleepBlockState { live, removed, merged }
enum SleepBlockSource { manual, confirmed, legacy, detected }

class _StoredBlock {
  _StoredBlock(this.row) {
    final kind = SleepBlockKind.values.where((v) => v.name == row['kind']).firstOrNull;
    final source = SleepBlockSource.values.where((v) => v.name == row['source']).firstOrNull;
    final rawState = SleepBlockState.values.where((v) => v.name == row['state']).firstOrNull;
    state = kind == null || source == null || rawState == null
        ? SleepBlockState.removed : rawState;
    block = SleepBlock(
      id: row['id'] as String, kind: kind ?? SleepBlockKind.nap,
      day: row['owner_day'] as String, ownerRule: row['owner_rule'] as int, startTs: row['start_ts'] as int,
      endTs: row['end_ts'] as int, revision: row['revision'] as int,
      provenance: switch (source) {
        SleepBlockSource.manual => SleepEntryProvenance.manual,
        SleepBlockSource.confirmed => SleepEntryProvenance.confirmed,
        SleepBlockSource.legacy => SleepEntryProvenance.legacy,
        _ => SleepEntryProvenance.automatic,
      },
    );
    final a = row['detected_start'], b = row['detected_end'], day = row['detected_day'];
    history = kind == null || source == null || rawState == null
        ? const DetectedUnavailable('unknown stored block shape')
        : switch (row['history']) {
      'absent' => const DetectedAbsent(),
      'known' when a is int && b is int && b > a && day is String =>
        DetectedKnown(startTs: a, endTs: b, sourceDay: day),
      _ => const DetectedUnavailable('stored history unavailable'),
    };
  }
  final Map<String, Object?> row;
  late final SleepBlock block;
  late final SleepBlockState state;
  late final DetectedHistory history;
}

class _SleepWork {
  _SleepWork(this.row,this.original,{this.beforeKey});
  final Map<String,Object?> row;
  final Map<String,Object?>? original;
  final String? beforeKey;
  bool get dirty => original==null || !mapEquals(row,original);
}
class _PreparedSleep {
  final work= <String,_SleepWork>{};
  final deleted=<String>{},stageDays=<String>{},mergedNapDays=<String>{},stageMainDays=<String>{};
  SleepRefused? refusal;
  SleepMergeProposal? merge;
}

abstract final class SleepBlockStore {
  static Future<SleepEditorPlan> plan(DatabaseExecutor tx,String day,List<SleepEditorCommand> commands) async {
    final current=await read(tx,day);
    return SleepEditorPlan(dayId:day,commands:commands,expectedRevisions:{day:current.revision},draftGeneration:current.draftGeneration);
  }

  // Preparation is read-only. Refusals cannot leak even when the caller commits
  // its transaction. The same prepared proposal powers preflight and Save.
  static Future<SleepEditorProposal> preflight(DatabaseExecutor tx, SleepEditorPlan plan) async {
    final p = await _prepare(tx, plan);
    if (p.refusal case final r?) return SleepProposalInvalid(r.reason, target:r.target);
    return p.merge == null ? const SleepProposalClear() : SleepProposalMergeRequired(p.merge!);
  }

  static Future<SleepEditorOutcome> apply(SleepEditorPlan plan, {
    required Transaction tx, SleepMergeAuthorization? merge,
  }) async {
    final p = await _prepare(tx, plan);
    if (p.refusal case final r?) return r;
    final proposal = p.merge;
    final approved = merge ?? plan.commands.whereType<MergeBlocks>().firstOrNull?.proposal.authorization;
    if (proposal != null && proposal.authorization != approved) {
      return SleepRefused(SleepRefusalReason.mergeRequired, proposal:proposal);
    }
    if (proposal != null) await _mergeRows(tx, p, proposal);
    final changed = p.work.values.where((w)=>w.dirty).toList();
    if (changed.isEmpty && p.deleted.isEmpty && p.stageDays.isEmpty) return const SleepNoChange();
    final days = <String>{...p.stageDays,...p.mergedNapDays};
    final mainDays = <String>{...p.stageMainDays};
    final deletes = <Map<String,dynamic>>[], exports = <Map<String,dynamic>>[];
    for (final day in p.deleted) {
      final old = await tx.query('sleep_block',where:"kind = 'main' AND owner_day = ?",whereArgs:[day]);
      if (old.isEmpty) continue;
      await _clearMain(tx,day); days.add(day); mainDays.add(day);
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Demote absorbed mains before promoting a survivor, to respect the index.
    changed.sort((a,b)=>(a.row['state']=='live'?1:0).compareTo(b.row['state']=='live'?1:0));
    for (final w in changed) {
      final row = w.row;
      final id = row['id'] as String;
      if (id.startsWith('new:')) row['id'] = const Uuid().v4();
      row['updated_at'] = now;
      if (w.original == null) {
        row['created_at'] = now;
        await tx.insert('sleep_block',row);
      } else {
        row['revision'] = (w.original!['revision'] as int)+1;
        await tx.update('sleep_block',row,where:'id = ?',whereArgs:[id]);
      }
      final day = row['owner_day'] as String;
      days.add(day);
      if (w.original != null) days.add(w.original!['owner_day'] as String);
      if (row['kind']=='main') {
        mainDays.add(day);
      } else {
        if (w.original != null && w.original!['state']=='live') deletes.add(_healthEntry(w.original!));
        if (row['state']=='live') exports.add(_healthEntry(row));
      }
    }
    await _project(tx,days);
    for (final day in days) {
      await SleepEditStore.enqueue(tx,day,main:mainDays.contains(day));
      if (mainDays.contains(day)) await tx.delete('wake_confirmation',where:'day_id = ?',whereArgs:[day]);
    }
    // Keep/auto-log and its suggestion are one receipt. Supersede excludes it.
    final confirmed = <String>{};
    for (final c in plan.commands.whereType<AddNap>()) {
      if (c.suggestionId == null) continue;
      final survivorId = proposal == null
          ? changed.where((w)=>w.row['state']=='live' && w.row['kind']=='nap' &&
              w.row['start_ts']==c.startTs).firstOrNull?.row['id']
          : p.work[proposal.survivor.key]?.row['id'];
      if (survivorId == null) throw StateError('confirmed nap has no block');
      final count=await tx.update('activity_suggestions',{'status':'confirmed',
        'linked_id':survivorId,'updated_at':now*1000},where:"id = ? AND status = 'pending'",whereArgs:[c.suggestionId]);
      if (count != 1) throw StateError('nap suggestion changed before commit');
      confirmed.add(c.suggestionId!);
    }
    for (final w in changed.where((w)=>w.row['kind']=='nap' && w.row['state']=='live')) {
      final candidates=await tx.query('activity_suggestions',columns:['id'],
        where:"kind = 'nap' AND status = 'pending' AND start_ts < ? AND end_ts > ?",
        whereArgs:[w.row['end_ts'],w.row['start_ts']]);
      for(final s in candidates) {
        if(confirmed.contains(s['id'])) continue;
        await tx.update('activity_suggestions',{'status':'superseded','updated_at':now*1000},where:'id = ?',whereArgs:[s['id']]);
      }
    }
    await HealthNapExporter.queueInTx(tx,deletes:deletes,exports:exports);
    return SleepSaved(days);
  }

  static Map<String,dynamic> _healthEntry(Map<String,Object?> r) => {
    'blockId':r['id'],'dayId':r['owner_day'],'startTs':r['start_ts'],'endTs':r['end_ts'],
  };
  static Future<void> _clearMain(DatabaseExecutor tx,String day) async {
    await tx.delete('sleep_block',where:"kind = 'main' AND owner_day = ?",whereArgs:[day]);
  }

  static Future<_PreparedSleep> _prepare(DatabaseExecutor tx,SleepEditorPlan plan) async {
    final p = _PreparedSleep();
    void refuse(SleepRefusalReason reason,[SleepBlockRef? target]) { p.refusal=SleepRefused(reason,target:target); }
    if(plan.draftGeneration!=SleepDraftFence.shared.generationOf(plan.dayId)) {
      refuse(SleepRefusalReason.staleDraft); return p;
    }
    for(final e in plan.expectedRevisions.entries) {
      final r=await tx.query('sleep_edit_job',columns:['revision'],where:'day_id = ?',whereArgs:[e.key]);
      if(r.firstOrNull?['revision']!=e.value) { refuse(SleepRefusalReason.staleEntry); return p; }
    }
    Future<_SleepWork?> bind(SleepBlockRef ref) async {
      if(ref is StoredBlockRef) {
        final cached=p.work[ref.id];
        if(cached!=null) {
          if(cached.original?['revision']!=ref.expectedRevision) refuse(SleepRefusalReason.staleEntry,ref);
          return p.refusal==null?cached:null;
        }
        final rows=await tx.query('sleep_block',where:'id = ?',whereArgs:[ref.id]);
        if(rows.isEmpty || rows.single['revision']!=ref.expectedRevision) { refuse(SleepRefusalReason.staleEntry,ref); return null; }
        return p.work[ref.id]=_SleepWork(Map.of(rows.single),Map.of(rows.single),beforeKey:ref.id);
      }
      final String day;
      final int start,end;
      final SleepBlockKind kind;
      switch(ref) {
        case DetectedMainRef(): day=ref.day;start=ref.expectedStartTs;end=ref.expectedEndTs;kind=SleepBlockKind.main;
        case DetectedNapRef(): day=ref.day;start=ref.expectedStartTs;end=ref.expectedEndTs;kind=SleepBlockKind.nap;
        case NoDetectionMainRef():
          day=ref.day;start=localDayStartSec(day)!;end=start+1;kind=SleepBlockKind.main;
        default: refuse(SleepRefusalReason.staleEntry,ref);return null;
      }
      final key='${kind.name}:$day:$start';
      final fresh=p.work.values.where((w)=>w.original==null && w.row['owner_day']==day &&
          w.row['kind']==kind.name && w.row['start_ts']==start && w.row['end_ts']==end).firstOrNull;
      if(fresh!=null) return fresh;
      final asserted=await tx.query('sleep_block',where:kind==SleepBlockKind.main?
        "kind = 'main' AND owner_day = ?":"kind = 'nap' AND start_ts < ? AND end_ts > ?",
        whereArgs:kind==SleepBlockKind.main?[day]:[end,start]);
      if(asserted.isNotEmpty) { refuse(SleepRefusalReason.staleEntry,ref);return null; }
      String? payload;
      if(kind==SleepBlockKind.main) {
        final windows=await detectedMainWindows(tx,day,day);
        final match=windows.where((r)=>r['on_ms']==start*1000 && r['off_ms']==end*1000).isNotEmpty;
        final any=windows.any((r)=>r['on_ms'] is num && r['off_ms'] is num && (r['off_ms'] as num)>(r['on_ms'] as num));
        if(ref is NoDetectionMainRef ? any : !match) { refuse(SleepRefusalReason.staleEntry,ref);return null; }
      } else {
        final rows=await tx.rawQuery('SELECT r.payload_json FROM day_result r ${LocalDb.servedDayJoinSql} WHERE r.day_id = ? AND r.skipped = 0',[day]);
        final bundle=await _payload(rows.firstOrNull?['payload_json']);
        final nap=((bundle?['naps'] as Map?)?['value'] as List?)?.whereType<Map>().where((n)=>n['start']==start && n['end']==end).firstOrNull;
        if(nap==null) { refuse(SleepRefusalReason.staleEntry,ref);return null; }
        payload=await JsonPayloadLane.shared.encode(nap);
      }
      final row=encodeBlock(SleepBlock(id:'new:$key',kind:kind,day:day,startTs:start,endTs:end),
        source:SleepBlockSource.detected,state:SleepBlockState.live,createdAt:0,payload:payload,
        history:ref is NoDetectionMainRef?const DetectedAbsent():DetectedKnown(startTs:start,endTs:end,sourceDay:day));
      return p.work['new:$key']=_SleepWork(row,null,beforeKey:kind==SleepBlockKind.main && ref is! NoDetectionMainRef?'main:$day':null);
    }
    Future<_SleepWork> add(SleepBlockKind kind,String day,int start,int end,String source,{String? payload}) async {
      final id='new:${kind.name}:$day:$start:${p.work.length}';
      final row=encodeBlock(SleepBlock(id:id,kind:kind,day:day,startTs:start,endTs:end),
        source:SleepBlockSource.values.byName(source),state:SleepBlockState.live,createdAt:0,payload:payload,
        history:source=='confirmed'?DetectedKnown(startTs:start,endTs:end,sourceDay:day):const DetectedAbsent());
      return p.work[id]=_SleepWork(row,null);
    }
    for(final c in plan.commands) {
      if(p.refusal!=null) break;
      switch(c) {
        case AddMain(:final day,:final startTs,:final endTs):
          if((await tx.query('sleep_block',columns:['id'],where:"kind = 'main' AND owner_day = ?",whereArgs:[day])).isNotEmpty ||
              p.work.values.any((w)=>w.row['kind']=='main' && w.row['owner_day']==day)) {
            refuse(SleepRefusalReason.mainExists);break;
          }
          await add(SleepBlockKind.main,day,startTs,endTs,'manual');
        case ConfirmMain(:final day,:final startTs,:final endTs):
          final existing=(await read(tx,day)).entries.where((e)=>e.kind==SleepBlockKind.main && !e.removed).firstOrNull;
          if(existing==null || existing.ref is DetectedMainRef &&
              (existing.startTs!=startTs || existing.endTs!=endTs)) {
            refuse(SleepRefusalReason.staleEntry);break;
          }
          final w=await bind(existing.ref);
          if(w!=null) { w.row['start_ts']=startTs;w.row['end_ts']=endTs;w.row['source']='confirmed';w.row['state']='live'; }
        case AddNap():
          if(!{'manual','confirmed'}.contains(c.source)) { refuse(SleepRefusalReason.unsupportedSource);break; }
          if(!manualNapWindowIsValid(c.startTs,c.endTs)) { refuse(SleepRefusalReason.invalidInterval);break; }
          final suggestion=c.suggestionId==null?null:(await tx.query('activity_suggestions',
            where:"id = ? AND kind = 'nap' AND status = 'pending'",whereArgs:[c.suggestionId])).firstOrNull;
          if(c.suggestionId!=null && suggestion==null) { refuse(SleepRefusalReason.staleEntry);break; }
          final w=await add(SleepBlockKind.nap,SleepOwnership.dayOf(SleepBlockKind.nap,c.startTs,c.endTs),c.startTs,c.endTs,c.source,payload:c.payload);
          // An edited Keep still owns the original detected interval's suppression.
          if(suggestion!=null) {
            w.row['history']='known';w.row['detected_start']=suggestion['start_ts'];
            w.row['detected_end']=suggestion['end_ts'];w.row['detected_day']=suggestion['day_id'];
            p.mergedNapDays.add(suggestion['day_id'] as String);
          }
        case ClearMain(:final day): p.deleted.add(day);
        case MergeBlocks(): break;
        case SetIntervals(:final target,:final startTs,:final endTs):
          final w=await bind(target);if(w==null) break;
          final r=w.row;
          if(r['start_ts']==startTs && r['end_ts']==endTs && r['state']=='live') break;
          r['start_ts']=startTs;r['end_ts']=endTs;
          if(r['kind']=='nap') {
            r['owner_day']=SleepOwnership.dayOf(SleepBlockKind.nap,startTs,endTs);
            r['owner_rule']=SleepOwnership.currentRule;
            r['payload_json']=null;r['source']='manual';
          } else if(r['state']!='live') { r['source']='manual'; }
          r['state']='live';r['merged_into']=null;
        case RemoveBlock(:final target):
          final w=await bind(target);if(w==null) break;
          if(w.original==null && w.row['source']!='detected') { p.work.removeWhere((k,v)=>identical(v,w));break; }
          if(w.row['state']=='live') w.row['state']='removed';
        case RestoreRemoved(:final target):
          final w=await bind(target);if(w==null) break;
          if(w.row['state']=='merged') {
            final survivor=w.row['merged_into'];
            if((await tx.query('sleep_block',columns:['id'],where:'id = ?',whereArgs:[survivor])).isNotEmpty) {
              refuse(SleepRefusalReason.staleEntry,target);break;
            }
          } else if(w.row['state']!='removed') { refuse(SleepRefusalReason.staleEntry,target);break; }
          w.row['state']='live';w.row['merged_into']=null;
          // Restore is an explicit acceptance; keep the measured snapshot.
          if(w.row['kind']=='nap' && {'legacy','detected'}.contains(w.row['source'])) {
            w.row['source']='confirmed';
            final payload=await _payload(w.row['payload_json']);
            if(payload!=null) w.row['payload_json']=await JsonPayloadLane.shared.encode({...payload,'source':'confirmed'});
          }
        case ResetToDetected(:final target):
          final w=await bind(target);if(w==null) break;
          if(_StoredBlock(w.row).history case DetectedKnown(:final startTs,:final endTs)) {
            w.row['start_ts']=startTs;w.row['end_ts']=endTs;
            if(w.row['kind']=='nap') { w.row['owner_day']=SleepOwnership.dayOf(SleepBlockKind.nap,startTs,endTs);w.row['owner_rule']=SleepOwnership.currentRule; }
          } else { refuse(SleepRefusalReason.missingHistory,target); }
        case ResetBoundary(:final target,:final boundary):
          final w=await bind(target);if(w==null) break;
          if(_StoredBlock(w.row).history case DetectedKnown(:final startTs,:final endTs)) {
            w.row[boundary==SleepBoundary.start?'start_ts':'end_ts']=boundary==SleepBoundary.start?startTs:endTs;
            if(w.row['kind']=='nap') { w.row['owner_day']=SleepOwnership.dayOf(SleepBlockKind.nap,w.row['start_ts'] as int,w.row['end_ts'] as int);w.row['owner_rule']=SleepOwnership.currentRule; }
          } else { refuse(SleepRefusalReason.missingHistory,target); }
        case CalculateStages(:final target):
          final w=await bind(target);if(w!=null) { p.stageDays.add(w.row['owner_day'] as String);
            if(w.row['kind']=='main') p.stageMainDays.add(w.row['owner_day'] as String); }
      }
    }
    if(p.refusal!=null) return p;
    final dirty=p.work.values.where((w)=>w.dirty).toList();
    for(final w in dirty) {
      if((w.row['end_ts'] as int)<=(w.row['start_ts'] as int)) { refuse(SleepRefusalReason.invalidInterval);return p; }
    }
    final mains=<String,String>{};
    for(final r in await tx.query('sleep_block',where:"kind = 'main' AND state = 'live'")) {
      if(!p.deleted.contains(r['owner_day'])) mains[r['owner_day'] as String]=r['id'] as String;
    }
    for(final w in dirty.where((w)=>w.row['kind']=='main')) {
      if(w.row['state']!='live') { mains.remove(w.row['owner_day']);continue; }
      final day=w.row['owner_day'] as String,id=w.row['id'] as String;
      if(mains.containsKey(day) && mains[day]!=id) { refuse(SleepRefusalReason.mainExists);return p; }
      mains[day]=id;
    }
    final afters=dirty.where((w)=>w.row['state']=='live').toList();
    if(afters.isEmpty) return p;
    var lo=afters.map((w)=>w.row['start_ts'] as int).reduce((a,b)=>a<b?a:b);
    var hi=afters.map((w)=>w.row['end_ts'] as int).reduce((a,b)=>a>b?a:b);
    List<SleepBlock> stored;
    while(true) {
      stored=await live(tx,lo-kMinSleepGapSec,hi+kMinSleepGapSec);
      var nextLo=lo,nextHi=hi;
      for(final b in stored) { if(b.startTs<nextLo) nextLo=b.startTs;if(b.endTs>nextHi) nextHi=b.endTs; }
      if(nextLo==lo && nextHi==hi) break;lo=nextLo;hi=nextHi;
    }
    p.merge=SleepSpacing.evaluate(stored:stored,editingDay:plan.dayId,changes:[
      for(final w in dirty) BlockChange(beforeKey:w.beforeKey,
        after:w.row['state']=='live'?_StoredBlock(w.row).block:null),
      for(final b in stored) if(p.deleted.contains(b.day) && b.kind==SleepBlockKind.main) BlockChange(beforeKey:b.key),
    ]);
    return p;
  }

  static Future<void> _mergeRows(DatabaseExecutor tx,_PreparedSleep p,SleepMergeProposal proposal) async {
    final participants=<_SleepWork>[];
    for(final b in proposal.participants) {
      var w=p.work[b.key] ?? p.work.values.where((w)=>w.beforeKey==b.key).firstOrNull;
      if(w==null) {
        final stored=b.id==null?null:(await tx.query('sleep_block',where:'id = ?',whereArgs:[b.id])).firstOrNull;
        final row=stored==null?encodeBlock(SleepBlock(id:'new:${b.key}',kind:b.kind,day:b.day,startTs:b.startTs,endTs:b.endTs),
          source:SleepBlockSource.detected,state:SleepBlockState.live,createdAt:0,
          history:DetectedKnown(startTs:b.startTs,endTs:b.endTs,sourceDay:b.day)):Map<String,Object?>.from(stored);
        w=_SleepWork(row,stored==null?null:Map.of(stored),beforeKey:b.key);p.work[b.key]=w;
      }
      participants.add(w);
    }
    final survivor=participants.first;
    // Include new nap ranges: they carry an explicit absence of measured history.
    final incoming=p.work.values.where((w)=>w.original==null && !participants.contains(w) &&
      w.row['state']=='live' && (w.row['start_ts'] as int)>=proposal.startTs && (w.row['end_ts'] as int)<=proposal.endTs).toList();
    final measures=participants.map((w)=>w.original??w.row).toList()..sort((a,b)=>(a['start_ts'] as int).compareTo(b['start_ts'] as int));
    final known=participants.every((w)=>w.row['history']=='known') && incoming.every((w)=>w.row['history']=='known');
    final r=survivor.row;
    if(known) {
      r['history']='known';
      r['detected_start']=participants.map((w)=>w.row['detected_start'] as int).reduce((a,b)=>a<b?a:b);
      r['detected_end']=participants.map((w)=>w.row['detected_end'] as int).reduce((a,b)=>a>b?a:b);
      r['detected_day']=r['owner_day'];
    } else { r['history']='unavailable';r['detected_start']=null;r['detected_end']=null;r['detected_day']=null; }
    var disjoint=true;
    for(var i=1;i<measures.length;i++) { if((measures[i-1]['end_ts'] as int)>(measures[i]['start_ts'] as int)) disjoint=false; }
    final payloads=[for(final m in measures) await _payload(m['payload_json'])];
    num? sum(String key)=>known && disjoint && incoming.isEmpty && payloads.every((m)=>m?[key] is num)
      ? payloads.fold<num>(0,(v,m)=>v+(m![key] as num)):null;
    r['payload_json']=await JsonPayloadLane.shared.encode({'duration_min':sum('duration_min'),
      'in_bed_min':sum('in_bed_min'),'source':'manual','confidence':null});
    r['start_ts']=proposal.startTs;r['end_ts']=proposal.endTs;r['state']='live';r['source']='manual';r['merged_into']=null;
    if(r['kind']=='nap') { r['owner_day']=SleepOwnership.dayOf(SleepBlockKind.nap,proposal.startTs,proposal.endTs);r['owner_rule']=SleepOwnership.currentRule; }
    for(final w in participants.skip(1)) { w.row['state']='merged';w.row['merged_into']=r['id']; }
    for(final w in incoming) { p.mergedNapDays.add(w.row['owner_day'] as String);p.work.removeWhere((k,v)=>identical(v,w)); }
    // A materialized automatic survivor needs its new id before participants link.
    if((r['id'] as String).startsWith('new:')) {
      r['id']=const Uuid().v4();
      for(final w in participants.skip(1)) { w.row['merged_into']=r['id']; }
    }
  }

  /// Shared row codec for absorption and new assertions. Callers choose the
  /// owner day through SleepOwnership; an existing block retains its rule.
  /// CLAIM(sleep-block-owner-rule): new assertions use rule 1; absorption
  /// preserves legacy rule 0 [owner decision 2026-11-18; B17].
  static Map<String, Object?> encodeBlock(SleepBlock block, {
    required SleepBlockSource source,
    required SleepBlockState state,
    required int createdAt,
    int? updatedAt,
    DetectedHistory history = const DetectedUnavailable('no retained detection'),
    String? mergedInto,
    String? payload,
  }) {
    if (block.id == null) throw ArgumentError('a stored block needs an id');
    return {
      'id': block.id, 'kind': block.kind.name, 'owner_day': block.day,
      'owner_rule': block.ownerRule ?? SleepOwnership.currentRule,
      'start_ts': block.startTs, 'end_ts': block.endTs,
      'source': source.name, 'state': state.name, 'merged_into': mergedInto,
      'history': switch (history) {
        DetectedKnown() => 'known', DetectedAbsent() => 'absent',
        DetectedUnavailable() => 'unavailable',
      },
      'detected_start': history is DetectedKnown ? history.startTs : null,
      'detected_end': history is DetectedKnown ? history.endTs : null,
      'detected_day': history is DetectedKnown ? history.sourceDay : null,
      'payload_json': payload, 'revision': block.revision,
      'created_at': createdAt, 'updated_at': updatedAt ?? createdAt,
    };
  }

  static Future<Map<String, dynamic>?> _payload(Object? value) async {
    if (value is! String || value.trim().isEmpty) return null;
    try {
      final decoded = await JsonPayloadLane.shared.decodeUncached(value);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// Absorbs release/upstream shapes only. It never interprets pilot envelopes.
  /// Backfill writes blocks, plus missing pre-review legacy-nap projections;
  /// it never enqueues or rewrites existing projections [spec §2.2; B5/B6/B15].
  static Future<List<SleepImportEntry>> absorb(DatabaseExecutor tx, {
    required List<Map<String, Object?>> overrides,
    required List<Map<String, Object?>> naps,
    Iterable<Map<String, Object?>> servedDayResults = const [],
    List<Map<String, Object?>> blocks = const [],
    required AbsorbMode mode,
  }) async {
    if (mode != AbsorbMode.backfill) {
      throw UnsupportedError('Import absorption requires the slice-C transport stage');
    }
    final report = <SleepImportEntry>[];
    void note(String kind, String table, String day, int start, int end) {
      report.add(SleepImportEntry(kind: kind, table: table, day: day,
        startTs: start, endTs: end));
    }
    Map<String, Object?> row(String id, String kind, String day, int start,
        int end, String source, String state, int created, {
        String history = 'unavailable', int? detectedStart, int? detectedEnd,
        String? payload}) => encodeBlock(SleepBlock(id: id,
          kind: SleepBlockKind.values.byName(kind), day: day,
          ownerRule: SleepOwnership.legacyRule, startTs: start, endTs: end),
        source: SleepBlockSource.values.byName(source),
        state: SleepBlockState.values.byName(state), createdAt: created,
        history: history == 'known'
          ? DetectedKnown(startTs: detectedStart!, endTs: detectedEnd!, sourceDay: day)
          : const DetectedUnavailable('legacy detection unavailable'),
        payload: payload);
    Future<bool> insertBlock(Map<String, Object?> block) async {
      if ((await tx.query('sleep_block', columns: ['id'], where: 'id = ?',
          whereArgs: [block['id']])).isNotEmpty) {
        return false;
      }
      // An explicit pre-check reports uniqueness refusal; OR IGNORE would hide it.
      if (block['kind'] == 'main' && block['state'] == 'live' &&
          (await tx.query('sleep_block', columns: ['id'],
            where: "kind = 'main' AND state = 'live' AND owner_day = ?",
            whereArgs: [block['owner_day']])).isNotEmpty) {
        note('refused', 'sleep_block', block['owner_day'] as String,
          block['start_ts'] as int, block['end_ts'] as int);
        return false;
      }
      await tx.insert('sleep_block', block);
      return true;
    }
    for (final legacy in overrides) {
      final day = legacy['day_id'] as String, start = legacy['onset_ts'] as int;
      final end = legacy['offset_ts'] as int, source = legacy['source'];
      final known = source == 'manual' || source == 'confirmed';
      if (!known && source != 'rejected') note('unknown_source', 'sleep_override', day, start, end);
      if (source == 'rejected' && end - start == 1) note('placeholder_bounds', 'sleep_override', day, start, end);
      await insertBlock(row('legacy:main:$day', 'main', day, start, end,
        known ? source as String : 'detected', known ? 'live' : 'removed', legacy['created_at'] as int));
    }
    for (final legacy in naps) {
      final day = legacy['day_id'] as String, start = legacy['start_ts'] as int;
      final end = legacy['end_ts'] as int, source = legacy['source'];
      final raw = legacy['payload_json'] as String?;
      final payload = await _payload(raw);
      if (raw != null && raw.trim().isNotEmpty && payload == null) note('malformed_payload', 'sleep_nap', day, start, end);
      final a = payload?['start'], b = payload?['end'];
      final snapshot = a is num && b is num && b > a;
      final knownSource = const {'manual', 'confirmed', 'legacy', 'rejected'}.contains(source);
      if (!knownSource) note('unknown_source', 'sleep_nap', day, start, end);
      final known = source == 'legacy' || (source == 'confirmed' || source == 'rejected') && snapshot;
      await insertBlock(row('legacy:nap:$day:$start', 'nap', day, start, end,
        knownSource && source != 'rejected' ? source as String : 'detected',
        knownSource && source != 'rejected' ? 'live' : 'removed', legacy['created_at'] as int,
        history: known ? 'known' : 'unavailable',
        detectedStart: known ? source == 'legacy' ? start : (a as num).toInt() : null,
        detectedEnd: known ? source == 'legacy' ? end : (b as num).toInt() : null,
        payload: raw));
    }
    final meta = await tx.query('activity_review_meta', columns: ['activated_at']);
    final cutoff = meta.firstOrNull?['activated_at'];
    if (cutoff is! int) return report;
    for (final served in servedDayResults) {
      final day = served['day_id'] as String;
      Object? values;
      try { values = await JsonPayloadLane.shared.decodeUncached(served['naps_json']); }
      catch (_) { continue; }
      if (values is! List) continue;
      for (final nap in values.whereType<Map>()) {
        final a = nap['start'], b = nap['end'];
        if (a is! num || b is! num || b <= a || a >= cutoff ||
            nap['source'] == 'manual' || nap['source'] == 'confirmed') {
          continue;
        }
        final start = a.toInt(), end = b.toInt();
        if ((await tx.query('sleep_block', columns: ['id'],
            where: "(kind = 'nap' OR state <> 'live') AND start_ts < ? AND end_ts > ?", whereArgs: [end, start])).isNotEmpty) {
          continue;
        }
        final payload = await JsonPayloadLane.shared.encode({...nap, 'source': 'legacy'});
        if (payload == null) throw StateError('legacy nap payload could not be encoded');
        if (await insertBlock(row('legacy:nap:$day:$start', 'nap', day, start, end,
            'legacy', 'live', cutoff, history: 'known', detectedStart: start,
            detectedEnd: end, payload: payload))) {
          // The sole projection write in backfill. Existing source rows are kept.
          await tx.rawInsert('INSERT INTO sleep_nap(day_id,start_ts,end_ts,source,created_at,payload_json) '
            "SELECT ?,?,?,'legacy',?,? WHERE NOT EXISTS (SELECT 1 FROM sleep_nap WHERE day_id = ? AND start_ts = ?)",
            [day, start, end, cutoff, payload, day, start]);
        }
      }
    }
    return report;
  }

  /// The SQL projection reads only naps.value, never the whole day bundle.
  static Future<void> backfill(DatabaseExecutor tx) async {
    await absorb(tx, overrides: await tx.query('sleep_override'),
      naps: await tx.query('sleep_nap'), mode: AbsorbMode.backfill,
      servedDayResults: await tx.rawQuery('''SELECT r.day_id,
        CASE WHEN json_valid(r.payload_json) THEN json_extract(r.payload_json, '\$.naps.value') END AS naps_json
        FROM day_result r ${LocalDb.servedDayJoinSql} WHERE r.skipped = 0'''));
  }

  /// Both stored window shapes, through the screens' served-version rule.
  static Future<List<Map<String, Object?>>> detectedMainWindows(
      DatabaseExecutor tx, String first, String last) => tx.rawQuery('''SELECT r.day_id AS day_id,
      CASE WHEN json_valid(r.window_json) THEN COALESCE(
        json_extract(r.window_json, '\$.value.onset_ms'), json_extract(r.window_json, '\$.onset_ms')) END AS on_ms,
      CASE WHEN json_valid(r.window_json) THEN COALESCE(
        json_extract(r.window_json, '\$.value.offset_ms'), json_extract(r.window_json, '\$.offset_ms')) END AS off_ms
      FROM day_result r ${LocalDb.servedDayJoinSql}
      WHERE r.skipped = 0 AND r.day_id BETWEEN ? AND ?''', [first, last]);

  // CLAIM(sleep-block-live-read): a main assertion in ANY state replaces the
  // automatic window [spec §3.3; sleep_block_store_test S1-S7].
  static Future<List<SleepBlock>> live(DatabaseExecutor tx, int fromSec, int toSec) async {
    if (toSec < fromSec) return [];
    final stored = (await tx.query('sleep_block', where:
      "state = 'live' AND start_ts <= ? AND end_ts >= ?", whereArgs: [toSec, fromSec]))
        .map(_StoredBlock.new);
    final out = [for (final r in stored) if (r.state == SleepBlockState.live) r.block];
    final days = SleepOwnership.daysOf(fromSec, toSec).toList();
    final first = dayLabelBefore(days.first, 1)!, last = dayLabelBefore(days.last, -1)!;
    final asserted = {for (final r in await tx.query('sleep_block', columns: ['owner_day'],
      where: "kind = 'main' AND owner_day BETWEEN ? AND ?", whereArgs: [first,last])) r['owner_day']};
    for (final r in await detectedMainWindows(tx, first, last)) {
      if (asserted.contains(r['day_id'])) continue;
      final on = r['on_ms'], off = r['off_ms'];
      if (on is! num || off is! num || off <= on) continue;
      final start = on.toInt() ~/ 1000, end = off.toInt() ~/ 1000;
      if (start > toSec || end < fromSec) continue;
      out.add(SleepBlock(kind: SleepBlockKind.main, day: r['day_id'] as String,
        startTs: start, endTs: end));
    }
    out.sort((a,b) => a.startTs != b.startTs ? a.startTs.compareTo(b.startTs) : (a.id ?? '').compareTo(b.id ?? ''));
    return out;
  }

  static Future<SleepEditorRead> read(DatabaseExecutor tx, String day) async {
    final rows = (await tx.query('sleep_block', where: 'owner_day = ?',
      whereArgs: [day], orderBy: 'start_ts, id')).map(_StoredBlock.new).toList();
    final entries = <SleepEditorEntry>[];
    for (final r in rows) {
      final b = r.block;
      final survivor = r.row['merged_into'];
      final attached = survivor is String && survivor.isNotEmpty &&
        (await tx.query('sleep_block', columns: ['id'], where: 'id = ?', whereArgs: [survivor])).isNotEmpty;
      entries.add(SleepEditorEntry(kind:b.kind,day:day,id: b.id, revision: b.revision, ownerRule: b.ownerRule,
        mergedInto: attached ? survivor : null,
        ref: StoredBlockRef(b.id!,b.revision),
        startTs: b.startTs, endTs: b.endTs, provenance: b.provenance,
        history: r.history, removed: r.state != SleepBlockState.live));
    }
    if (!rows.any((r) => r.block.kind == SleepBlockKind.main)) {
      for (final r in await detectedMainWindows(tx, day, day)) {
        final on = r['on_ms'], off = r['off_ms'];
        if (on is! num || off is! num || off <= on) continue;
        final start = on.toInt() ~/ 1000, end = off.toInt() ~/ 1000;
        entries.add(SleepEditorEntry(kind:SleepBlockKind.main,day:day,ref: DetectedMainRef(day,start,end), startTs: start, endTs: end,
          provenance: SleepEntryProvenance.automatic,
          history: DetectedKnown(startTs: start,endTs: end,sourceDay: day),removed: false));
      }
    }
    final byId={for(final r in rows) r.block.id:r.row};
    const priority={'live':0,'removed':1,'merged':2};
    entries.sort((a,b) {
      final start=a.startTs.compareTo(b.startTs);if(start!=0) return start;
      final ra=byId[a.id],rb=byId[b.id];
      final state=(priority[ra?['state']]??0).compareTo(priority[rb?['state']]??0);
      if(state!=0) return state;
      final updated=((rb?['updated_at'] as int?)??0).compareTo((ra?['updated_at'] as int?)??0);
      return updated!=0?updated:(a.id??'').compareTo(b.id??'');
    });
    final main = entries.where((e) => e.kind == SleepBlockKind.main).firstOrNull;
    final span = SleepOwnership.framingSpan(day,main: main == null ? null : (start:main.startTs,end:main.endTs),
      entries:[for (final e in entries) (start:e.startTs,end:e.endTs)]);
    final jobs = await tx.query('sleep_edit_job', columns:['revision'],where:'day_id = ?',whereArgs:[day]);
    return SleepEditorRead(dayId: day, entries: entries,
      revision: jobs.firstOrNull?['revision'] as int?, draftGeneration: SleepDraftFence.shared.generationOf(day),
      neighbors: [for (final b in await live(tx,span.start,span.end)) if (b.day != day) b]);
  }

  static Future<List<NapEdit>> napEdits(DatabaseExecutor tx, String day) async {
    InputReads.note('sleep_nap', day);
    final rows = await tx.query('sleep_block',where: "kind = 'nap' AND (owner_day = ? OR history = 'known' AND detected_day = ? AND owner_day <> ?)",
      whereArgs:[day,day,day],orderBy:'start_ts, id');
    final out = <NapEdit>[];
    for (final row in rows) {
      final r = _StoredBlock(row), b = r.block;
      if (b.day == day) {
        final payload = await _payload(row['payload_json']);
        out.add(NapEdit(kind: r.state == SleepBlockState.live ? NapEditKind.added : NapEditKind.rejected,
          startSec:b.startTs,endSec:b.endTs,snapshot:payload == null || payload.isEmpty ? null : payload));
      } else if (r.history case DetectedKnown(:final startTs,:final endTs)) {
        out.add(NapEdit(kind:NapEditKind.rejected,startSec:startTs,endSec:endTs));
      }
    }
    return out;
  }

  // CLAIM(sleep-block-projection): stable total order handles the one lossy
  // natural-key collision [spec §1.3; B5/S9/S10]. Payload bytes are copied.
  static Future<void> _project(DatabaseExecutor tx, Set<String> ownerDays) async {
    const priority = {'live':0,'removed':1,'merged':2};
    for (final day in ownerDays) {
      final rows = List<Map<String, Object?>>.of(await tx.query(
        'sleep_block', where: 'owner_day = ?', whereArgs: [day]));
      rows.sort((a,b) {
        final state = (priority[a['state']] ?? 1).compareTo(priority[b['state']] ?? 1);
        if (state != 0) return state;
        final updated = (b['updated_at'] as int).compareTo(a['updated_at'] as int);
        return updated != 0 ? updated : (a['id'] as String).compareTo(b['id'] as String);
      });
      await tx.delete('sleep_nap',where:'day_id = ?',whereArgs:[day]);
      final previousMain=await tx.query('sleep_override',where:'day_id = ?',whereArgs:[day]);
      Map<String,Object?>? nextMain;
      final naps = <int>{};
      var main = false;
      for (final row in rows) {
        final r = _StoredBlock(row), b = r.block;
        final source = r.state != SleepBlockState.live ? 'rejected'
            : row['source'] == 'detected' ? 'confirmed' : row['source'];
        if (b.kind == SleepBlockKind.nap && naps.add(b.startTs)) {
          await tx.insert('sleep_nap',{'day_id':day,'start_ts':b.startTs,'end_ts':b.endTs,
            'source':source,'created_at':row['created_at'],'payload_json':row['payload_json']});
        } else if (b.kind == SleepBlockKind.main && !main) {
          main = true;
          nextMain={'day_id':day,'onset_ts':b.startTs,'offset_ts':b.endTs,
            'source':source,'created_at':row['created_at'],'payload_json':null};
        }
      }
      // Nap work must not move the prepared main's input stamp. Rewriting an
      // identical main projection would fire sleep_override's night trigger.
      if(!mapEquals(previousMain.firstOrNull,nextMain)) {
        await tx.delete('sleep_override',where:'day_id = ?',whereArgs:[day]);
        if(nextMain!=null) await tx.insert('sleep_override',nextMain);
      }
    }
  }

  @visibleForTesting
  static Future<void> projectForTest(DatabaseExecutor tx, Set<String> ownerDays) => _project(tx,ownerDays);
}
