import 'recorded_stages.dart';
import 'pilot_theme.dart';
// Owner: editor State owns detached interval drafts and undo; the canonical
// SleepBlockStore owns persistence through AppState.saveSleepEditor.
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/day_label.dart';
import '../data/local_repository.dart' show SleepPrimaryRead;
import '../wake/wake_timeline.dart' show WakeNightEvent;
import '../data/sleep_editor.dart';
import '../models/activity_suggestion.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../ui2/chart_annotations.dart';
import '../ui2/charts.dart' show SleepStage;
import '../ui2/day_timeline/day_graph.dart';
import '../ui2/day_timeline/timeline_controller.dart';
import '../ui2/screens/day_timeline.dart' show dayGraph;
import '../ui2/screens/home_screen.dart' show repoOf;
import '../ui2/theme.dart';
import '../ui2/grammar.dart' show BigButton,SubTabs,NavBar;
import '../ui2/profile/profile.dart' show SetRow;
import '../ui2/screens/home_screen.dart' show hm;
import '../l10n/date_text.dart' show prettyDay;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../wake/wake_outcome.dart';
import 'day_layout.dart' show PilotDayRow;
import 'pilot_readout.dart';
import 'timeline_chart.dart';
import 'timeline_policy.dart';

class SleepIntervalDraft {
  SleepIntervalDraft({required this.id,required this.start,required this.end,this.entry,this.removed=false,this.suggestionId});
  final String id;final String? suggestionId;final SleepEditorEntry? entry;int start,end;bool removed,calculate=false;
  final Map<bool,int> snapped={};
  SleepIntervalDraft copy()=>SleepIntervalDraft(id:id,start:start,end:end,entry:entry,removed:removed,suggestionId:suggestionId)..calculate=calculate..snapped.addAll(snapped);
  bool get moved=>entry==null||start!=entry!.startTs||end!=entry!.endTs;
  bool get changed=>moved||removed!=(entry?.removed??false)||calculate;
  bool get detected=>entry?.history is DetectedKnown;
}

class PilotSleepEditor extends StatefulWidget {
  const PilotSleepEditor({super.key,required this.day,this.initialTime,this.read,this.graph,this.stages=const [],this.onSave,this.proposal});
  final ActivitySuggestion? proposal;
  final String day;final int? initialTime;final SleepEditorRead? read;final DayGraph? graph;
  final List<SleepStage?> stages;final Future<SleepEditorOutcome> Function(SleepEditorPlan)? onSave;
  @override State<PilotSleepEditor> createState()=>_SleepEditorState();
}
class _SleepEditorState extends State<PilotSleepEditor>{
  late String day;SleepEditorRead? read;DayGraph graph=const DayGraph();
  List<SleepStage?> stages=[];List<ChartAnnotation> wakeEvents=[];
  List<SleepIntervalDraft> blocks=[];List<SleepIntervalDraft>? undo;
  TimelineController? c;final interaction=TimelineInteraction(retention:PilotScrub.temporary);
  String? selected,error;bool endSelected=true,loading=true,saving=false,adding=false;
  bool _allowPop=false;
  int? addedStart;bool? dream,originalDream;int? dreamEpoch;
  AppLocalizations get l=>AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
  SleepIntervalDraft? get block=>blocks.where((b)=>b.id==selected).firstOrNull;
  bool get dirty=>blocks.any((b)=>b.changed)||dream!=originalDream;
  @override void initState(){super.initState();day=widget.day;if(widget.read!=null){_bind(widget.read!,widget.graph??const DayGraph(),widget.stages);}else{WidgetsBinding.instance.addPostFrameCallback((_)=>_load());}}
  void _bind(SleepEditorRead r,DayGraph g,List<SleepStage?> stage){
    read=r;graph=g;stages=stage;
    blocks=[for(var i=0;i<r.entries.length;i++)SleepIntervalDraft(id:r.entries[i].id??'detected:$i',start:r.entries[i].startTs,end:r.entries[i].endTs,entry:r.entries[i],removed:r.entries[i].removed)]..sort((a,b)=>a.start.compareTo(b.start));
    if(widget.proposal case final proposal?)blocks.add(SleepIntervalDraft(id:'proposal:${proposal.id}',start:proposal.startTs,end:proposal.endTs,suggestionId:proposal.id));
    selected=widget.proposal!=null?'proposal:${widget.proposal!.id}':blocks.where((b)=>widget.initialTime!=null&&widget.initialTime!>=b.start&&widget.initialTime!<=b.end).firstOrNull?.id??blocks.firstOrNull?.id;
    final local=DateTime.parse(day);var lo=DateTime(local.year,local.month,local.day-1,12).millisecondsSinceEpoch~/1000;
    var hi=DateTime(local.year,local.month,local.day+1,12).millisecondsSinceEpoch~/1000;
    for(final b in blocks){lo=math.min(lo,b.start-3600);hi=math.max(hi,b.end+3600);}
    final old=c;c=TimelineController(homeStartSec:lo,homeEndSec:hi);if(old!=null)WidgetsBinding.instance.addPostFrameCallback((_)=>old.dispose());
    if(block!=null)c!.selectRange(block!.start-5400,block!.end+5400);
    loading=false;undo=null;
  }
  Future<void> _load()async{
    try{final repo=repoOf(context);if(repo==null)throw StateError('No repository');
      final r=await repo.readSleepEditor(day);
      final local=DateTime.parse(day),parts=<DayGraph>[];
      for(var delta=-1;delta<=1;delta++){final d=dayLabelOf(DateTime(local.year,local.month,local.day+delta));parts.add(dayGraph(await repo.getDayTimeline(d)));}
      final valid=parts.where((p)=>p.dayStart!=null).toList();
      final lo=valid.isEmpty?DateTime(local.year,local.month,local.day-1).millisecondsSinceEpoch~/1000:valid.map((p)=>p.dayStart!).reduce(math.min);
      final hi=valid.isEmpty?lo:valid.map((p)=>p.dayStart!+p.slots*60).reduce(math.max);
      final hrs=List<double?>.filled((hi-lo)~/60,null),motion=List<double?>.filled((hi-lo)~/60,null);
      final rest=<(int,int,Color)>[];
      for(final p in valid){final offset=(p.dayStart!-lo)~/60;for(var i=0;i<p.hr.length;i++)hrs[offset+i]=p.hr[i];for(var i=0;i<p.movement.length;i++)motion[offset+i]=p.movement[i];for(final s in p.rest)rest.add((s.$1+offset,s.$2+offset,s.$3));}
      final SleepPrimaryRead? primary=await repo.getSleepDetailPrimary(day);final night=primary?.bundle.night;
      final stage=recordedStages(night??{},origin:lo,slots:hrs.length);
      final List<WakeNightEvent> observed=primary?.wake.collapsedEvents??const <WakeNightEvent>[];
      if(!mounted)return;
      final events=[for(final WakeNightEvent e in observed)ChartAnnotation(id:'wake:${e.kind.name}:${e.at.millisecondsSinceEpoch}',kind:AnnotationKind.wake,at:e.at.millisecondsSinceEpoch/1000,label:wakeEventLabel(e,l),icon:wakeEventIcon(e.kind))];
      if(!mounted)return;setState((){_bind(r,DayGraph(hr:hrs,movement:motion,rest:rest,dayStart:lo),stage);wakeEvents=events;dream=primary?.wake.dream?.answer==DreamAnswer.dream?true:primary?.wake.dream?.answer==DreamAnswer.normal?false:null;originalDream=dream;dreamEpoch=primary?.wake.events.where((e)=>e.wakeEpochSec!=null).firstOrNull?.wakeEpochSec;});
    }catch(e){if(mounted)setState((){error=e.toString();loading=false;});}
  }
  @override void dispose(){c?.dispose();interaction.dispose();super.dispose();}
  void _checkpoint(){undo=blocks.map((b)=>b.copy()).toList();}
  void _move(String id,double at){
    final b=block;if(b==null||b.removed)return;
    setState((){endSelected=id=='end';final value=at.round();if(endSelected)b.end=math.max(b.start+600,value);else b.start=math.min(b.end-600,value);b.calculate=false;});
  }
  Future<void> _select(SleepIntervalDraft b)async{
    if(b.removed){final restore=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:Text(l.pilotRestoreBlock),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:Text(l.pilotKeepRemoved)),TextButton(onPressed:()=>Navigator.pop(c,true),child:Text(l.pilotRestore))]));if(restore!=true||!mounted)return;setState(()=>b.removed=false);}
    setState(()=>selected=b.id);c!.reveal((endSelected?b.end:b.start).toDouble());
  }
  Future<void> _tap(double at)async{
    if(adding){setState((){if(addedStart==null)addedStart=at.round();else{final start=math.min(addedStart!,at.round()),end=math.max(addedStart!,at.round());if(end-start>=600){final b=SleepIntervalDraft(id:'added:${DateTime.now().microsecondsSinceEpoch}',start:start,end:end);blocks.add(b);selected=b.id;adding=false;addedStart=null;}}});return;}
    final overlaps=blocks.where((b)=>at>=b.start&&at<=b.end).toList();
    if(overlaps.length>1){final id=await showDialog<String>(context:context,builder:(c)=>SimpleDialog(title:Text(l.pilotChooseBlock),children:[for(final b in overlaps)SimpleDialogOption(onPressed:()=>Navigator.pop(c,b.id),child:Text('${b.entry?.kind==SleepBlockKind.main?l.tabSleep:l.dayTimelineNap} ${pilotClock(b.start.toDouble())}'))]));if(id!=null&&mounted)await _select(overlaps.firstWhere((b)=>b.id==id));}
    else if(overlaps.length==1)await _select(overlaps.single);
  }
  List<({int at,String label})> _targets(SleepIntervalDraft b){
    final out=<({int at,String label})>[];
    for(final other in blocks){if(other.id==b.id||other.removed)continue;final label=other.entry?.kind==SleepBlockKind.main?l.tabSleep:l.dayTimelineNap;out.add((at:other.start,label:label));out.add((at:other.end,label:label));}
    for(var i=1;i<stages.length;i++){
      if(stages[i]==SleepStage.rem&&stages[i-1]!=SleepStage.rem)out.add((at:(graph.dayStart??0)+i*300,label:'REM'));
      if(stages[i-1]==SleepStage.rem&&stages[i]==SleepStage.awake)out.add((at:(graph.dayStart??0)+i*300,label:l.pilotWake));
    }
    return out;
  }
  Widget _timeRow(SleepIntervalDraft b,bool end){
    final at=end?b.end:b.start,h=b.entry?.history;
    final detected=h is DetectedKnown?(end?h.endTs:h.startTs):null;
    final candidates=_targets(b).where((t)=>(t.at-at).abs()>0&&(t.at-at).abs()<=1800).toList()..sort((a,b)=>(a.at-at).abs().compareTo((b.at-at).abs()));
    final snapped=b.snapped[end];
    final offer=detected!=at&&(snapped==null||(at-snapped).abs()>1200)?candidates.firstOrNull:null;
    // Mock-up v11 .item: glyph, name, snap/reset chip right after it, the time
    // with "detected" under it; the selected time has the .item.sel card.
    final main=b.entry?.kind!=SleepBlockKind.nap;
    Widget chip(String label,VoidCallback tap)=>PilotRowChip(label,onTap:tap);
    return PilotItemRow(icon:main?(end?LucideIcons.sunrise:LucideIcons.moon):LucideIcons.bedDouble,color:main?(end?C.orange:C.indigo):C.teal,
      title:main?(end?l.pilotWokeUp:l.pilotFellAsleep):(end?l.pilotNapEnds:l.pilotNapStarts),selected:end==endSelected,
      onTap:(){setState(()=>endSelected=end);c!.reveal(at.toDouble());},
      action:offer!=null?chip('${offer.label} ${pilotClock(offer.at.toDouble())}',(){_checkpoint();setState((){if(end)b.end=math.max(b.start+600,offer.at);else b.start=math.min(b.end-600,offer.at);b.snapped[end]=offer.at;});})
        :detected!=null&&at!=detected?chip(l.pilotResetDetected,(){_checkpoint();setState((){if(end)b.end=detected;else b.start=detected;b.snapped.remove(end);});}):null,
      time:pilotClock(at.toDouble()),timeSub:detected==null?l.pilotAddedByYou:at==detected?l.pilotDetected:l.pilotDetectedAt(pilotClock(detected.toDouble())));
  }
  String _label(SleepIntervalDraft b)=>b.entry?.kind==SleepBlockKind.nap||b.entry==null?l.pilotNapAt(pilotClock(b.start.toDouble())):l.pilotMainSleep;
  Future<void> _save({SleepMergeProposal? merge})async{
    final r=read;if(r==null)return;final save=widget.onSave??context.read<AppState>().saveSleepEditor;setState(()=>saving=true);
    try{
      final commands=<SleepEditorCommand>[];
      for(final b in blocks){
        final entry=b.entry;
        if(entry==null){if(!b.removed)commands.add(AddNap(b.start,b.end,source:b.suggestionId==null?'manual':'confirmed',suggestionId:b.suggestionId));continue;}
        if(b.removed!=entry.removed){commands.add(b.removed?RemoveBlock(entry.ref):RestoreRemoved(entry.ref));}
        if(!b.removed&&b.moved)commands.add(SetIntervals(entry.ref,b.start,b.end));
        if(!b.removed&&b.calculate)commands.add(CalculateStages(entry.ref));
      }
      if(merge!=null)commands.add(MergeBlocks(merge));
      final plan=SleepEditorPlan(dayId:day,commands:commands,expectedRevisions:{day:r.revision},draftGeneration:r.draftGeneration);
      final result=await save(plan);
      if(!mounted)return;
      if(result is SleepRefused&&result.proposal!=null){
        final yes=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:Text(l.pilotOverlap),content:Text(l.pilotMerge),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:Text(l.pilotCancel)),TextButton(onPressed:()=>Navigator.pop(c,true),child:Text(l.pilotMerge))]));
        if(yes==true&&mounted){await _save(merge:result.proposal);return;}
      }else if(result is SleepSaved||result is SleepNoChange){
        if(!mounted)return;
        if(dream!=originalDream&&dreamEpoch!=null&&widget.onSave==null)await this.context.read<AppState>().wake.answerDream(dreamEpoch!,dream==null?null:dream!?DreamAnswer.dream:DreamAnswer.normal);
        if(mounted){setState(()=>_allowPop=true);await WidgetsBinding.instance.endOfFrame;if(mounted)Navigator.pop(context,true);}return;
      }
      if(mounted)setState(()=>error=result is SleepFailed?result.error.toString():l.pilotSourceFailed);
    }catch(e){if(mounted)setState(()=>error=e.toString());}finally{if(mounted)setState(()=>saving=false);}
  }
  Future<void> _go(int days)async{final d=DateTime.parse(day);setState((){day=dayLabelOf(DateTime(d.year,d.month,d.day+days));loading=true;error=null;});await _load();}
  @override Widget build(BuildContext context){
    final p=P.of(context),b=block,controller=c;
    return PilotTheme(child:Builder(builder:(context)=>PopScope(canPop:_allowPop||(!dirty&&!saving),onPopInvokedWithResult:(didPop,result)async{
      if(didPop||saving)return;final leave=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:Text(l.pilotCancel),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:Text(l.pilotCancel)),TextButton(onPressed:()=>Navigator.pop(c,true),child:Text(l.dayReviewDiscard))]));
      if(leave==true&&mounted){setState(()=>_allowPop=true);await WidgetsBinding.instance.endOfFrame;if(mounted)Navigator.pop(this.context);}
    },child:Scaffold(backgroundColor:p.bg,appBar:PreferredSize(preferredSize:const Size.fromHeight(52),child:SafeArea(bottom:false,child:NavBar(l.pilotSleepEditor))),body:SafeArea(child:loading?const Center(child:CircularProgressIndicator()):controller==null?Center(child:Text(error??l.pilotSourceFailed)):Column(children:[
      Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:Column(children:[
        PilotDayRow(day:prettyDay(day,l),dirty:dirty,busy:saving,onPrevious:()=>_go(-1),onNext:()=>_go(1),onCancel:(){setState(()=>_bind(read!,graph,stages));},onSave:_save),
        if(adding)SizedBox(height:24,child:Text(addedStart==null?l.pilotTapStart:l.pilotTapEnd)),
        PilotTimelineChart(controller:controller,graph:graph,interaction:interaction,stages:stages,dimHrInsideSleep:false,focusId:selected,showHeader:false,onTapTime:_tap,
          handles:b==null||b.removed?[]:[PilotHandle('start',b.start.toDouble(),p.on(C.blue),active:!endSelected),PilotHandle('end',b.end.toDouble(),p.on(C.blue),active:endSelected)],onHandle:_move,
          annotations:[...wakeEvents,for(final row in blocks)ChartAnnotation(id:row.id,kind:row.entry?.kind==SleepBlockKind.main?AnnotationKind.mainSleep:AnnotationKind.nap,at:row.start.toDouble(),until:row.end.toDouble(),label:row.entry?.kind==SleepBlockKind.main?l.tabSleep:l.dayTimelineNap)],
          onSelect:(id){if(id=='start'||id=='end'){setState(()=>endSelected=id=='end');return;}final match=blocks.where((b)=>b.id==id).firstOrNull;if(match!=null)_select(match);}),
        Builder(builder:(context){final ordered=[...blocks]..sort((a,b)=>a.start.compareTo(b.start));
          // Mock-up v11 .tabs, one per block in time order; a removed block is struck through.
          return Padding(padding:const EdgeInsets.only(top:6),child:SubTabs([for(final row in ordered)_label(row)],math.max(0,ordered.indexWhere((r)=>r.id==selected)),(i)=>_select(ordered[i]),color:C.blue,
            struck:{for(var i=0;i<ordered.length;i++)if(ordered[i].removed)i}));}),
      ])),
      Expanded(child:ListView(padding:const EdgeInsets.fromLTRB(16,8,16,32),children:[
        if(error!=null)Text(error!,style:TextStyle(color:p.on(C.red))),
        if(b!=null)PilotReadout(controller:controller,graph:graph,stages:stages,fallbackTime:(endSelected?b.end:b.start).toDouble(),
          titleWidget:Row(children:[Flexible(child:Text(_label(b),maxLines:1,overflow:TextOverflow.ellipsis,style:F.body.copyWith(color:p.ink,fontWeight:FontWeight.w600))),
            if(b.entry==null||b.moved)Padding(padding:const EdgeInsets.only(left:6),child:Text((b.entry==null?l.pilotAdded:l.pilotEdited).toUpperCase(),style:F.cap.copyWith(color:p.on(C.orange),fontSize:11,fontWeight:FontWeight.w700)))]),
          fallback:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            // Mock-up v11 .key: heart rate, motion, stages Actual (green) / Preview (orange).
            Wrap(spacing:12,runSpacing:2,crossAxisAlignment:WrapCrossAlignment.center,children:[
              _key(p.on(C.red),l.pilotHeartRateBpm),_key(p.on(C.purple),l.pilotMotion),
              Text.rich(TextSpan(children:[TextSpan(text:'${l.pilotSleepStages} · '),TextSpan(text:b.moved?l.pilotPreview:l.pilotActual,style:TextStyle(color:p.on(b.moved?C.orange:C.green),fontWeight:FontWeight.w700))]),style:F.cap.copyWith(color:p.ink3,fontSize:11)),
            ]),
            const SizedBox(height:6),
            Row(children:[for(final cell in [(l.pilotAsleep,_asleep(b)??'—'),(l.pilotSleepWindow,hm((b.end-b.start)~/60)),(l.pilotWindow,'${pilotClock(b.start.toDouble())}–${pilotClock(b.end.toDouble())}')])
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(cell.$1,maxLines:1,overflow:TextOverflow.ellipsis,style:F.cap.copyWith(color:p.ink3)),Text(cell.$2,maxLines:1,overflow:TextOverflow.ellipsis,style:F.head.copyWith(color:p.ink,fontSize:15))]))]),
          ]),
          controls:PilotZoomControls(controller:controller,onZoom:interaction.zoom,trailing:Align(alignment:Alignment.centerRight,child:TextButton.icon(onPressed:()=>setState((){adding=!adding;addedStart=null;}),icon:Icon(adding?LucideIcons.x:LucideIcons.plus,size:16),label:FittedBox(fit:BoxFit.scaleDown,child:Text(l.pilotAddBlock,maxLines:1)))))),
        if(b!=null)Padding(padding:const EdgeInsets.fromLTRB(2,12,2,4),child:Text(l.pilotDragHint.toUpperCase(),style:F.cap.copyWith(color:p.ink3,fontSize:11,letterSpacing:.4))),
        if(b!=null&&!b.removed)...[
          _timeRow(b,false),_timeRow(b,true),
          // Owner m169: the whole dream row is the toggle (app SetRow + Switch).
          if(b.entry?.kind==SleepBlockKind.main)...[Divider(height:1,color:p.line),Padding(padding:const EdgeInsets.symmetric(horizontal:10),child:SetRow(dream==true?LucideIcons.cloudMoon:LucideIcons.sun,dream==true?C.indigo:C.n500,l.pilotWokeDream,chevron:false,enabled:dreamEpoch!=null,
            onTap:dreamEpoch==null?null:()=>setState(()=>dream=!(dream??false)),trailing:Switch(value:dream==true,onChanged:dreamEpoch==null?null:(v)=>setState(()=>dream=v))))],
          Padding(padding:const EdgeInsets.fromLTRB(4,22,4,14),child:Divider(height:1,color:p.line)),
          // Mock-up v11 .btn.full: full-width icon buttons; Remove in the warning colour.
          BigButton(l.pilotCalculateThisBlock,dense:true,soft:true,color:C.blue,icon:LucideIcons.sparkles,onTap:()=>setState(()=>b.calculate=true)),
          const SizedBox(height:8),
          BigButton(l.pilotRemoveThisBlock,dense:true,soft:true,color:C.red,icon:LucideIcons.trash2,onTap:(){_checkpoint();setState((){if(b.entry==null){blocks.remove(b);selected=blocks.firstOrNull?.id;}else b.removed=true;});}),
        ],
        if(undo!=null)Row(children:[Expanded(child:Text(l.pilotUndo)),TextButton(onPressed:()=>setState((){blocks=undo!;undo=null;selected=blocks.firstOrNull?.id;}),child:Text(l.pilotUndo))]),
      ])),
    ]))))));
  }
  Widget _key(Color color,String label)=>Row(mainAxisSize:MainAxisSize.min,children:[Container(width:14,height:3,decoration:BoxDecoration(color:color,borderRadius:BorderRadius.circular(2))),const SizedBox(width:5),Text(label,style:F.cap.copyWith(color:P.of(context).ink3,fontSize:11))]);
  String? _asleep(SleepIntervalDraft b){
    if(b.moved)return null;
    final h=b.entry?.history;if(h is! DetectedKnown)return null;
    final minutes=h.measures['asleep_min'];return minutes is num?hm(minutes):null;
  }
}
