import 'recorded_stages.dart';
import 'alarm_readout.dart';
import 'package:intl/intl.dart';
import 'pilot_theme.dart';
// Owner: alarm list State owns its saved snapshot; editor State owns one detached draft.
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../notify/buzz_sequence.dart';
import '../haptics/pattern_store.dart';
import '../haptics/example_playback.dart' show HapticCancel;
import '../ui2/screens/home_screen.dart' show repoOf;
import '../state/app_state.dart';
import '../state/clock_format.dart' show formatClock,formatClockOf;
import '../ui2/chart_annotations.dart';
import '../ui2/charts.dart' show SleepStage;
import '../ui2/day_timeline/day_graph.dart';
import '../ui2/day_timeline/timeline_controller.dart';
import '../ui2/screens/day_timeline.dart' show dayGraph;
import '../ui2/profile/haptics_settings.dart';
import '../ui2/theme.dart';
import 'alarm_pilot.dart';
import 'pilot_flags.dart';
import 'timeline_chart.dart';
import 'timeline_policy.dart';

class PilotAlarmScreen extends StatefulWidget {
  const PilotAlarmScreen({super.key,this.alarms,this.onSave,this.now,this.graph=const DayGraph(),this.stages=const [],this.reference});
  final Future<PilotAlarmReference?> Function(DateTime)? reference;
  final List<PilotAlarm>? alarms;final Future<void> Function(List<PilotAlarm>)? onSave;
  final DateTime? now;final DayGraph graph;final List<SleepStage?> stages;
  @override State<PilotAlarmScreen> createState()=>_AlarmListState();
}
class _AlarmListState extends State<PilotAlarmScreen>{
  List<PilotAlarm> _alarms=[];String? _error;bool _loading=true,_saving=false;
  AppLocalizations get l=>AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
  @override void initState(){super.initState();if(widget.alarms!=null){_alarms=widget.alarms!.map((a)=>a.copy()).toList();_loading=false;}else{_load();}}
  Future<void> _load()async{try{final a=await PilotAlarmStore.load();if(mounted)setState((){_alarms=a;_loading=false;});}catch(e){if(mounted)setState((){_error=e.toString();_loading=false;});}}
  Future<void> _save(List<PilotAlarm> alarms)async{
    setState(()=>_saving=true);
    var saved=alarms;
    try{if(widget.onSave!=null)await widget.onSave!(alarms);else{await PilotAlarmStore.save(alarms);saved=await PilotAlarmStore.load();if(mounted)await context.read<AppState>().refreshPilotAlarms();}
      if(mounted)setState(()=>_alarms=saved.map((a)=>a.copy()).toList());
    }catch(e){if(mounted)setState(()=>_error=e.toString());rethrow;}
    finally{if(mounted)setState(()=>_saving=false);}
  }
  Future<void> _edit(PilotAlarm alarm,{bool adding=false})async{
    final result=await Navigator.of(context).push<PilotAlarm>(MaterialPageRoute(builder:(_)=>PilotAlarmEditor(alarm:alarm,now:widget.now,graph:widget.graph,stages:widget.stages,reference:widget.reference,
      onSave:(draft)async{final updated=[for(final a in _alarms)if(a.id!=draft.id)a.copy(),draft.copy()];await _save(updated);} )));
    if(result!=null&&mounted)setState((){});
  }
  Future<void> _add()async{
    final type=await showModalBottomSheet<PilotAlarmType>(context:context,builder:(c)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,children:[
      ListTile(minTileHeight:56,leading:const Icon(LucideIcons.moon),title:Text(l.pilotSleepAlarm),subtitle:Text(l.pilotSleepAlarmDescription),onTap:()=>Navigator.pop(c,PilotAlarmType.sleep)),
      ListTile(minTileHeight:56,leading:const Icon(LucideIcons.dumbbell),title:Text(l.pilotWorkoutAlarm),subtitle:Text(l.pilotWorkoutAlarmDescription),onTap:()=>Navigator.pop(c,PilotAlarmType.workout)),
    ])));
    if(type==null||!mounted)return;
    await _edit(PilotAlarm(id:DateTime.now().microsecondsSinceEpoch.toString(),label:type==PilotAlarmType.sleep?l.pilotSleepAlarm:l.pilotWorkoutAlarm,type:type,wakeMinute:type==PilotAlarmType.sleep?420:1140),adding:true);
  }
  Future<void> _wakeAction(Future<void> Function() action)async{
    setState(()=>_saving=true);try{await action();}catch(e){if(mounted)setState(()=>_error=e.toString());}finally{if(mounted)setState(()=>_saving=false);}
  }
  Widget _activeWake(AppState app)=>ListenableBuilder(listenable:Listenable.merge([app.pilotWake.effects,app.snooze.status]),builder:(context,_){
    final alarm=app.pilotWake.firedAlarm;if(alarm==null||app.pilotWake.acknowledged)return const SizedBox.shrink();
    final until=app.snooze.status.value.until;
    return Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(children:[Text(until==null?alarm.label:l.snoozeCardUntil(formatClockOf(until))),Row(children:[
      if(alarm.snooze)Expanded(child:TextButton(onPressed:_saving?null:()=>_wakeAction(app.snoozePilotAlarm),child:Text(l.pilotSnooze))),
      Expanded(child:TextButton(onPressed:_saving?null:()=>_wakeAction(()async{await app.wake.acknowledgeWake(cancelNative:true);}),child:Text(l.snoozeImUp))),
    ])])));
  });
  @override Widget build(BuildContext context){
    final p=P.of(context),now=widget.now??DateTime.now();
    final app=widget.onSave==null?context.watch<AppState>():null;
    final sorted=[..._alarms]..sort((a,b){final x=pilotNextAt(a,now),y=pilotNextAt(b,now);if(x==null)return y==null?0:1;if(y==null)return -1;return x.compareTo(y);});
    final next=sorted.where((a)=>a.enabled).firstOrNull?.id;
    return PilotTheme(child:Builder(builder:(context)=>Scaffold(backgroundColor:p.bg,appBar:AppBar(title:Text(l.pilotAlarms)),floatingActionButton:FloatingActionButton(onPressed:_saving?null:_add,tooltip:l.pilotAddAlarm,child:const Icon(LucideIcons.plus)),
      body:_loading?const Center(child:CircularProgressIndicator()):ListView(padding:const EdgeInsets.all(16),children:[
        if(app!=null)_activeWake(app),if(_error!=null)Text(_error!),if(_alarms.isEmpty)Text(l.pilotNoAlarms),
        for(final a in sorted)Padding(padding:const EdgeInsets.only(bottom:12),child:Container(key:ValueKey('pilot-alarm:${a.id}'),padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:p.card,border:Border.all(color:a.id==next?p.on(C.blue):p.line),borderRadius:BorderRadius.circular(16)),child:Column(children:[
          Row(children:[if(a.primary)Icon(LucideIcons.star,color:p.on(C.yellow),size:18),Expanded(child:TextButton(onPressed:()=>_edit(a),child:Align(alignment:Alignment.centerLeft,child:Text(a.label,maxLines:1,overflow:TextOverflow.ellipsis)))),Expanded(child:Text(_daysLabel(a,l),maxLines:1,overflow:TextOverflow.ellipsis,style:F.cap)),if(a.id==next)Text(l.pilotNext,style:F.cap.copyWith(color:p.on(C.blue))),Switch(value:a.enabled,onChanged:_saving?null:(v){final copies=_alarms.map((x)=>x.copy()).toList();copies.firstWhere((x)=>x.id==a.id).enabled=v;unawaited(_save(copies).catchError((_){ }));})]),
          Opacity(opacity:a.enabled?1:.35,child:IgnorePointer(child:_AlarmChart(alarm:a,now:now,graph:widget.graph,stages:widget.stages,reference:widget.reference))),
        ]))),
      ]))));
  }
}
String _daysLabel(PilotAlarm a,AppLocalizations l)=>a.days.isEmpty?l.pilotOnce:a.days.length==7?l.pilotEveryDay:a.days.length==5&&a.days.containsAll({1,2,3,4,5})?l.pilotWeekdays:a.days.length==2&&a.days.containsAll({6,7})?l.pilotWeekends:a.days.toList().sortedDays(l);
extension on List<int>{String sortedDays(AppLocalizations l){sort();final names=[l.pilotMonday,l.pilotTuesday,l.pilotWednesday,l.pilotThursday,l.pilotFriday,l.pilotSaturday,l.pilotSunday];return map((d)=>names[d-1]).join(', ');}}

class _AlarmChart extends StatefulWidget{
  const _AlarmChart({required this.alarm,required this.now,required this.graph,required this.stages,this.reference});
  final Future<PilotAlarmReference?> Function(DateTime)? reference;
  final PilotAlarm alarm;final DateTime now;final DayGraph graph;final List<SleepStage?> stages;
  @override State<_AlarmChart> createState()=>_AlarmChartState();
}
class _AlarmChartState extends State<_AlarmChart>{
  late final TimelineController c;final interaction=TimelineInteraction(retention:PilotScrub.temporary);
  late final int start;DayGraph? measured;List<SleepStage?>? recorded;int? bed,expected,usualSleepMinutes;
  @override void initState(){super.initState();final day=DateTime(widget.now.year,widget.now.month,widget.now.day);start=day.millisecondsSinceEpoch~/1000;
    c=TimelineController(glideDuration:const Duration(milliseconds:450),homeStartSec:DateTime(day.year,day.month,day.day-1,12).millisecondsSinceEpoch~/1000,homeEndSec:DateTime(day.year,day.month,day.day+1,18).millisecondsSinceEpoch~/1000);
    _range();if(widget.reference!=null||widget.graph.slots==0)WidgetsBinding.instance.addPostFrameCallback((_)=>_load());
  }
  void _range(){final a=widget.alarm;if(bed==null){c.selectRange(start+(a.type==PilotAlarmType.sleep?a.wakeMinute-a.earlyMinutes-150:a.workoutStartMinute-90)*60,start+(a.wakeMinute+math.max(60,a.maxSnoozes*a.snoozeMinutes).toInt())*60);}
    else{final ann=pilotAlarmAnnotations(a,lookupAppLocalizations(const Locale('en')),start,bedMinute:bed,expectedWake:expected).where((v)=>v.id!='bed');
      c.selectRange(start+(bed!-30)*60,(ann.map((v)=>v.at).reduce(math.max)+15*60).round());}}
  Future<void> _load()async{
    try{final day=pilotNextAt(widget.alarm,widget.now)??widget.now;
      final reading=widget.reference?.call(day)??loadPilotAlarmReference(context,start,day.weekday,sleep:widget.alarm.type==PilotAlarmType.sleep);
      final sample=await reading;
      if(mounted&&sample!=null){setState((){measured=sample.graph;recorded=widget.alarm.type==PilotAlarmType.sleep?sample.stages:const [];bed=widget.alarm.type==PilotAlarmType.sleep?sample.bedMinute:null;final wm=sample.wakeMinute;usualSleepMinutes=sample.usualSleepMinutes;expected=wm!=null&&wm>=widget.alarm.wakeMinute-widget.alarm.earlyMinutes&&wm<=widget.alarm.wakeMinute?wm:null;});_range();}
    }catch(_){/* The overview stays empty when no recorded night is available. */}
  }
  @override void didUpdateWidget(_AlarmChart old){super.didUpdateWidget(old);if(old.alarm.wakeMinute!=widget.alarm.wakeMinute||old.alarm.earlyMinutes!=widget.alarm.earlyMinutes)_range();}
  @override void dispose(){c.dispose();interaction.dispose();super.dispose();}
  @override Widget build(BuildContext context){
    final a=widget.alarm,l=AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
    final annotations=pilotAlarmAnnotations(a,l,start,bedMinute:bed,expectedWake:expected);
    final waking=annotations.where((v)=>v.id!='bed').map((v)=>v.at).toList();
    final left=bed==null?null:start+(bed!+50)*60.0,right=waking.isEmpty?null:waking.reduce(math.min)-600;
    final cut=left!=null&&right!=null&&right>left+1200?PilotTimelineCut(leftEnd:left,rightStart:right):null;
    Widget stat(String label,String value)=>Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,style:F.cap),Text(value,maxLines:1,overflow:TextOverflow.ellipsis)]));
    return Column(children:[PilotTimelineChart(controller:c,graph:measured??widget.graph,interaction:interaction,stages:a.type==PilotAlarmType.sleep?recorded??widget.stages:const [],height:114,overview:true,cut:cut,annotations:annotations),
      Row(children:[stat(a.type==PilotAlarmType.sleep?l.pilotWake:l.pilotWindow,formatClock(a.wakeMinute~/60,a.wakeMinute%60)),
        if(a.type==PilotAlarmType.sleep)stat(l.pilotExpected,expected==null?'—':formatClock(expected!~/60,expected!%60)),
        if(a.type==PilotAlarmType.sleep&&bed!=null)stat(l.pilotUsualSleep,usualSleepMinutes==null?'—':l.activityLengthMinutes(usualSleepMinutes!)),
      ]),
    ]);
  }
}

class PilotAlarmReference {
  const PilotAlarmReference({required this.graph,this.stages=const [],this.bedMinute,this.wakeMinute,this.usualSleepMinutes});
  final DayGraph graph;final List<SleepStage?> stages;final int? bedMinute,wakeMinute,usualSleepMinutes;
}
Future<PilotAlarmReference?> loadPilotAlarmReference(BuildContext context,int start,int weekday,{bool sleep=true})async{
  final repo=repoOf(context);if(repo==null)return null;final days=await repo.availableDays();
  final matching=days.where((d)=>DateTime.parse(d).weekday==weekday).take(4);
  for(final day in matching){final raw=await repo.getDayTimeline(day);final g=dayGraph(raw);
    if(!sleep)return PilotAlarmReference(graph:DayGraph(hr:g.hr,movement:g.movement,rest:g.rest,work:g.work,dayStart:start));
    if(g.rest.isEmpty)continue;
    final rest=g.rest.first,base=g.dayStart;if(base==null)continue;
    final wake=DateTime.fromMillisecondsSinceEpoch((base+rest.$2*60)*1000);
    final wm=wake.hour*60+wake.minute,offset=start+wm*60-(base+rest.$2*60);
    final detail=await repo.getSleepDetailPrimary(day);
    return PilotAlarmReference(graph:DayGraph(hr:g.hr,movement:g.movement,rest:g.rest,work:g.work,dayStart:base+offset),
      stages:recordedStages(detail?.bundle.night??{},origin:base+offset,slots:g.slots,shiftSeconds:offset),
      bedMinute:((base+rest.$1*60+offset-start)/60).round(),wakeMinute:wm,usualSleepMinutes:(detail?.bundle.night['duration_min'] as num?)?.round());
  }
  return null;
}
List<ChartAnnotation> pilotAlarmAnnotations(PilotAlarm a,AppLocalizations l,int start,{int? bedMinute,int? expectedWake}){
  final expected=expectedWake??a.referenceWakeMinute??a.wakeMinute,methods=PilotFlag.wakeMethods.enabled;
  ChartAnnotation mark(String id,int minute,String label,IconData icon,{int? until,AnnotationKind kind=AnnotationKind.wake})=>ChartAnnotation(id:id,kind:kind,at:start+minute*60.0,until:until==null?null:start+until*60.0,label:label,icon:icon);
  if(a.type==PilotAlarmType.workout)return [mark('window',a.workoutStartMinute,l.pilotWindow,LucideIcons.dumbbell,until:a.wakeMinute,kind:AnnotationKind.workout),mark('wake',a.wakeMinute,l.pilotWindowEnd,LucideIcons.alarmClock)];
  return [
    if(bedMinute!=null)mark('bed',bedMinute,l.pilotFallAsleep,LucideIcons.moon,kind:AnnotationKind.mainSleep),
    if(a.earlyMinutes>0)mark('early',a.wakeMinute-a.earlyMinutes,l.pilotEarlyWake,LucideIcons.sunrise,until:a.wakeMinute),
    if(methods&&a.gradual&&a.band)mark('gradual',expected-a.gradualMinutes,l.pilotGradual,LucideIcons.vibrate,until:expected),
    if(methods&&a.sunrise)mark('sunrise',expected-a.sunriseMinutes,l.pilotSunrise,LucideIcons.sun,until:expected),
    if(expectedWake!=null&&a.earlyMinutes>0)mark('expected',expected,l.pilotExpected,LucideIcons.alarmClock),
    mark('wake',a.wakeMinute,l.pilotWake,LucideIcons.alarmClock),
    mark('backup',a.wakeMinute+(methods&&!a.band?1:0),a.band?l.pilotBandAlarm:l.pilotBandBackup,a.band?LucideIcons.watch:LucideIcons.shieldCheck),
    if(methods&&a.phoneSound)mark('sound',expected+a.soundDelayMinutes,l.pilotPhoneSound,LucideIcons.volume2),
    if(methods&&a.phoneVibration)mark('vibration',expected+a.vibrationDelayMinutes,l.pilotPhoneVibration,LucideIcons.smartphone),
    if(methods&&a.phoneFlash)mark('flash',expected+a.flashDelayMinutes,l.pilotPhoneFlash,LucideIcons.flashlight),
    if(methods&&a.snooze)for(var n=1;n<=a.maxSnoozes;n++)mark('snooze:$n',expected+n*a.snoozeMinutes,l.pilotSnooze,LucideIcons.alarmClock),
  ];
}

class PilotAlarmEditor extends StatefulWidget{
  const PilotAlarmEditor({super.key,required this.alarm,required this.onSave,this.now,this.graph=const DayGraph(),this.stages=const [],this.reference});
  final Future<PilotAlarmReference?> Function(DateTime)? reference;
  final PilotAlarm alarm;final Future<void> Function(PilotAlarm) onSave;final DateTime? now;final DayGraph graph;final List<SleepStage?> stages;
  @override State<PilotAlarmEditor> createState()=>_AlarmEditorState();
}
class _AlarmEditorState extends State<PilotAlarmEditor> with TickerProviderStateMixin {
  late PilotAlarm a;late TimelineController c;late int start;int tab=0;String focus='wake';bool repeat=false,saving=false,playing=false;double progress=0;String? error;
  DayGraph? measured;List<SleepStage?> stages=[];int? usualBed,previewBed,expectedWake,_runtimeExpectedWake;int night=0,_referenceEpoch=0;
  final interaction=TimelineInteraction(retention:PilotScrub.temporary);
  HapticCancel? _playback;
  late final AnimationController _tabFlash=AnimationController(vsync:this,duration:const Duration(seconds:1))..addListener(_animate);
  late final AnimationController _rowGlow=AnimationController(vsync:this,duration:const Duration(milliseconds:900))..addListener(_animate);
  final _freshTimings=<String>{},_glowingTimings=<String>{};double _rowDrag=0;int _rowStart=0;
  void _animate(){if(mounted)setState((){});}
  void _openTab(int value){setState(()=>tab=value);if(value==0&&_freshTimings.isNotEmpty){_glowingTimings..clear()..addAll(_freshTimings);_freshTimings.clear();_rowGlow.forward(from:0);}}
  AppLocalizations get l=>AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
  bool get methods=>PilotFlag.wakeMethods.enabled;
  @override void initState(){super.initState();a=widget.alarm.copy();final now=widget.now??DateTime.now();final day=DateTime(now.year,now.month,now.day);start=day.millisecondsSinceEpoch~/1000;
    c=TimelineController(glideDuration:const Duration(milliseconds:450),homeStartSec:DateTime(day.year,day.month,day.day-(a.type==PilotAlarmType.sleep?1:0),a.type==PilotAlarmType.sleep?18:0).millisecondsSinceEpoch~/1000,homeEndSec:DateTime(day.year,day.month,day.day+(a.type==PilotAlarmType.sleep?0:1),a.type==PilotAlarmType.sleep?18:0).millisecondsSinceEpoch~/1000);
    c.selectRange(start+(a.type==PilotAlarmType.sleep?a.wakeMinute-a.earlyMinutes-20:a.workoutStartMinute-90)*60,start+(a.wakeMinute+(a.type==PilotAlarmType.sleep?20:60))*60);stages=widget.stages;expectedWake=_runtimeExpectedWake=a.referenceWakeMinute;
    if(widget.reference!=null||widget.graph.slots==0)WidgetsBinding.instance.addPostFrameCallback((_)=>_loadReference());
  }
  List<DateTime> get nights {
    final now=widget.now??DateTime.now(),out=<DateTime>[];
    for(var offset=0;offset<42&&out.length<6;offset++){
      final day=DateTime(now.year,now.month,now.day+offset);
      if(a.days.isEmpty?offset==0:a.days.contains(day.weekday))out.add(day);
    }
    return out;
  }
  String _nightLabel(DateTime day){
    final now=widget.now??DateTime.now();
    if(day==DateTime(now.year,now.month,now.day))return l.pilotTonight;
    if(day==DateTime(now.year,now.month,now.day+1))return l.pilotTomorrowNight;
    return DateFormat.MMMEd(Localizations.localeOf(context).toString()).format(day);
  }
  void _pageNight(int value){
    setState((){night=value;measured=null;stages=widget.stages;usualBed=previewBed=expectedWake=null;});
    c.clearScrub();interaction.zoom();unawaited(_loadReference());
  }
  void _repeatChanged(){night=0;_pageNight(0);}
  Future<void> _loadReference()async{
    final epoch=++_referenceEpoch,choices=nights;if(choices.isEmpty)return;
    final selected=choices[night.clamp(0,choices.length-1)];
    try{
      PilotAlarmReference? sample;
      if(widget.reference!=null){sample=await widget.reference!(selected);}else{
        sample=await loadPilotAlarmReference(context,start,selected.weekday,sleep:a.type==PilotAlarmType.sleep);
      }
      if(mounted&&epoch==_referenceEpoch)setState((){stages=sample?.stages??widget.stages;measured=sample?.graph;usualBed=previewBed=sample?.bedMinute;
        final wm=sample?.wakeMinute;expectedWake=wm!=null&&wm>=a.wakeMinute-a.earlyMinutes&&wm<=a.wakeMinute?wm:null;if(night==0)_runtimeExpectedWake=expectedWake;});
    }catch(_){/* Missing reference data stays absent. */}
  }
  @override void dispose(){_tabFlash.dispose();_rowGlow.dispose();_playback?.cancel();interaction.dispose();c.dispose();super.dispose();}
  int minute(double at)=>((at-start)/60).round();
  int get expectedMinute=>expectedWake??a.wakeMinute;
  int _minuteFor(String id)=>switch(id){'early'=>a.wakeMinute-a.earlyMinutes,'gradual'=>expectedMinute-a.gradualMinutes,'sunrise'=>expectedMinute-a.sunriseMinutes,'sound'=>expectedMinute+a.soundDelayMinutes,'vibration'=>expectedMinute+a.vibrationDelayMinutes,'flash'=>expectedMinute+a.flashDelayMinutes,'bed'=>previewBed??a.wakeMinute,'window'=>a.workoutStartMinute,_=>a.wakeMinute};
  void _handle(String id,double at){setState((){tab=0;focus=id;final m=minute(at);
    switch(id){
      case 'wake':final next=m.clamp(0,1439),delta=next-a.wakeMinute;a.wakeMinute=next;if(expectedWake!=null)expectedWake=(expectedWake!+delta).clamp(0,1439);if(_runtimeExpectedWake!=null)_runtimeExpectedWake=(_runtimeExpectedWake!+delta).clamp(0,1439);
      case 'early':a.earlyMinutes=(a.wakeMinute-m).clamp(0,720);
      case 'gradual':a.gradualMinutes=(expectedMinute-m).clamp(0,180);
      case 'sunrise':a.sunriseMinutes=(expectedMinute-m).clamp(5,60);
      case 'sound':a.soundDelayMinutes=(m-expectedMinute).clamp(0,30);
      case 'vibration':a.vibrationDelayMinutes=(m-expectedMinute).clamp(0,30);
      case 'flash':a.flashDelayMinutes=(m-expectedMinute).clamp(0,30);
      case 'bed':previewBed=m.clamp(-720,a.wakeMinute-a.earlyMinutes-60);
      case 'window':a.workoutStartMinute=m.clamp(0,1439);
    }
  });}
  void _showNewTiming(String id){_freshTimings.add(id);_tabFlash.forward(from:0);}
  void select(String id,double at){setState(()=>focus=id);c.reveal(at);c.clearScrub();}
  Future<void> _save()async{a.referenceWakeMinute=_runtimeExpectedWake;setState(()=>saving=true);try{await widget.onSave(a);if(mounted)Navigator.pop(context,a);}catch(e){if(mounted)setState(()=>error=e.toString());}finally{if(mounted)setState(()=>saving=false);}}
  Future<void> _rename()async{final text=TextEditingController(text:a.label);final value=await showDialog<String>(context:context,builder:(c)=>AlertDialog(title:Text(l.pilotAlarmName),content:TextField(controller:text,maxLength:60,autofocus:true),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:Text(l.pilotCancel)),TextButton(onPressed:()=>Navigator.pop(c,text.text.trim()),child:Text(l.pilotSave))]));text.dispose();if(value!=null&&value.isNotEmpty&&mounted)setState(()=>a.label=value);}
  Future<void> _pickPattern()async{
    final patterns=(await HapticPatternStore.load()).list;
    if(!mounted)return;
    final id=await showModalBottomSheet<String>(context:context,builder:(c)=>SafeArea(child:ListView(shrinkWrap:true,children:[for(final pattern in patterns)ListTile(minTileHeight:56,title:Text(pattern.name),onTap:()=>Navigator.pop(c,pattern.id))])));
    if(id!=null&&mounted)setState(()=>a.customPatternId=id);
  }
  Future<void> _feel({bool chaos=false})async{
    if(playing)return;setState((){playing=true;progress=0;});
    Timer? ticker;final watch=Stopwatch()..start();
    try{ticker=Timer.periodic(const Duration(milliseconds:80),(_){if(mounted)setState(()=>progress=(watch.elapsedMilliseconds/4500).clamp(0,1));});
      final app=context.read<AppState>();
      final owner=HapticCancel();_playback=owner;
      await owner.run(()=>app.previewBuzzSequenceExample(BuzzSequence(chaos?snoozeOffsets(a.chaos,3,math.Random()):gradualOffsets(a.pattern))));
    }catch(e){if(mounted)setState(()=>error=e.toString());}finally{ticker?.cancel();if(mounted)setState(()=>playing=false);}
  }
  Widget toggle(String title,bool value,ValueChanged<bool> change,{String? sub})=>SwitchListTile(contentPadding:EdgeInsets.zero,title:Text(title),subtitle:sub==null?null:Text(sub),value:value,onChanged:methods?change:null);
  Widget timeRow(String id,String title,int value,{String? sub,Widget? trailing,Color? timeColor,bool showTime=true})=>GestureDetector(
    key:ValueKey('pilot-time:$id'),dragStartBehavior:DragStartBehavior.down,onHorizontalDragStart:(_){_rowStart=_minuteFor(id);_rowDrag=0;select(id,start+_rowStart*60.0);},
    onHorizontalDragUpdate:(d){_rowDrag+=d.delta.dx;final moved=(_rowDrag/10).round()*5;_handle(id,start+(_rowStart+moved)*60.0);},
    child:ColoredBox(color:_glowingTimings.contains(id)&&_rowGlow.isAnimating?P.of(context).on(C.blue).withValues(alpha:.3*math.sin(math.pi*_rowGlow.value)):Colors.transparent,child:ListTile(contentPadding:EdgeInsets.zero,minTileHeight:56,selected:focus==id,title:Text(title,maxLines:1,overflow:TextOverflow.ellipsis),subtitle:sub==null?null:Text(sub,maxLines:1,overflow:TextOverflow.ellipsis),trailing:Row(mainAxisSize:MainAxisSize.min,children:[if(showTime)Text(formatClock(((value%1440)+1440)%1440~/60,((value%60)+60)%60),style:F.head.copyWith(fontSize:19,color:timeColor)),if(trailing!=null)trailing]),onTap:()=>select(id,start+value*60.0))));

  Widget feelRow({bool chaos=false})=>Row(children:[TextButton.icon(onPressed:playing?null:()=>_feel(chaos:chaos),icon:const Icon(LucideIcons.vibrate,size:16),label:Text(l.pilotFeelIt)),const Spacer(),TextButton(onPressed:()=>Navigator.of(context).push(MaterialPageRoute(builder:(_)=>const HapticsSettings())),child:Text(l.pilotHaptics))]);
  Widget choices<T>(List<T> values,T selected,ValueChanged<T> change,String Function(T) label)=>Wrap(spacing:6,children:[for(final v in values)ChoiceChip(label:Text(label(v)),selected:v==selected,onSelected:methods?(_)=>setState(()=>change(v)):null,materialTapTargetSize:MaterialTapTargetSize.padded)]);
  @override Widget build(BuildContext context){
    final p=P.of(context);
    final graph=measured??widget.graph;
    final tabs=a.type==PilotAlarmType.sleep?[l.pilotTimes,l.pilotWaking]:[l.pilotWindow,l.pilotHeartRate];
    final handles=[PilotHandle(focus,start+_minuteFor(focus)*60.0,p.on(C.blue))];
    return PilotTheme(child:Builder(builder:(context)=>Scaffold(backgroundColor:p.bg,body:SafeArea(child:Column(children:[
      SizedBox(height:56,child:Row(children:[TextButton(onPressed:saving?null:()=>Navigator.pop(context),child:Text(l.pilotCancel)),Expanded(child:Text(l.pilotEditAlarm(a.label),maxLines:1,overflow:TextOverflow.ellipsis,textAlign:TextAlign.center,style:F.head.copyWith(color:p.ink))),TextButton(onPressed:saving?null:_save,child:Text(l.pilotSave))])),
      if(a.type==PilotAlarmType.sleep)Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:Row(key:const ValueKey('pilot-night-pager'),children:[
        IconButton(tooltip:l.pilotPreviousNight,onPressed:night>0?()=>_pageNight(night-1):null,icon:const Icon(LucideIcons.chevronLeft)),
        Expanded(child:Text(nights.isEmpty?l.pilotTonight:_nightLabel(nights[night.clamp(0,nights.length-1)]),textAlign:TextAlign.center,style:F.head.copyWith(color:p.ink))),
        IconButton(tooltip:l.pilotNextNight,onPressed:night<nights.length-1?()=>_pageNight(night+1):null,icon:const Icon(LucideIcons.chevronRight)),
      ])),
      Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:PilotTimelineChart(controller:c,graph:graph,interaction:interaction,stages:stages,handles:handles,selectedAnnotationId:focus,onHandle:_handle,onSelect:(id){if({'bed','wake','early','gradual','sunrise','sound','vibration','flash','window'}.contains(id))select(id,start+_minuteFor(id)*60.0);},
        annotations:pilotAlarmAnnotations(a,l,start,bedMinute:previewBed,expectedWake:expectedWake))),
      Row(children:[for(var i=0;i<tabs.length;i++)Expanded(child:TextButton(onPressed:()=>_openTab(i),style:TextButton.styleFrom(backgroundColor:i==0&&_tabFlash.isAnimating?p.on(C.blue).withValues(alpha:.6*math.pow(math.sin(2*math.pi*_tabFlash.value),2)):tab==i?p.card2:null,minimumSize:const Size(48,48)),child:Text(tabs[i])))]),
      Expanded(child:ListView(padding:const EdgeInsets.fromLTRB(16,8,16,32),children:[
        if(error!=null)Text(error!,style:TextStyle(color:p.on(C.red))),
        if(tab==0)...[
          SizedBox(height:repeat?200:200,child:Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:p.card,borderRadius:BorderRadius.circular(12)),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[

            if(repeat)...[
              SingleChildScrollView(scrollDirection:Axis.horizontal,child:Row(children:[
                for(var d=1;d<=7;d++)SizedBox(width:48,height:48,child:Semantics(
                  selected:a.days.contains(d),child:TextButton(
                    style:TextButton.styleFrom(padding:EdgeInsets.zero,minimumSize:const Size(48,48),backgroundColor:a.days.contains(d)?p.card2:null),
                    onPressed:()=>setState((){a.days.contains(d)?a.days.remove(d):a.days.add(d);_repeatChanged();}),
                    child:Text([l.pilotMonday,l.pilotTuesday,l.pilotWednesday,l.pilotThursday,l.pilotFriday,l.pilotSaturday,l.pilotSunday][d-1].substring(0,1)),
                  ),
                )),
              ])),
              Row(children:[for(final preset in [({1,2,3,4,5},l.pilotWeekdays),({6,7},l.pilotWeekends),({1,2,3,4,5,6,7},l.pilotEveryDay),(<int>{},l.pilotOnce)])Expanded(child:TextButton(onPressed:()=>setState((){a.days={...preset.$1};_repeatChanged();}),child:Text(preset.$2,maxLines:1,overflow:TextOverflow.ellipsis)))]),
            ]else Expanded(child:PilotAlarmReadout(key:const ValueKey('pilot-alarm-readout'),controller:c,graph:graph,stages:stages,alarm:a,dayStart:start,expectedMinute:expectedMinute,selectedMinute:_minuteFor(focus),bedtimeMinute:previewBed,
              title:TextButton(onPressed:_rename,style:TextButton.styleFrom(padding:EdgeInsets.zero),child:Align(alignment:Alignment.centerLeft,child:Text(a.label,maxLines:1,overflow:TextOverflow.ellipsis))))),
            if(repeat)const Spacer(),
            PilotZoomControls(controller:c,onZoom:interaction.zoom,trailing:TextButton(onPressed:()=>setState(()=>repeat=!repeat),child:Text(repeat?l.pilotDone:_daysLabel(a,l),maxLines:1,overflow:TextOverflow.ellipsis))),
          ]))),
          if(a.type==PilotAlarmType.sleep&&previewBed!=null)timeRow('bed',l.pilotFallAsleep,previewBed!,sub:previewBed==usualBed?l.pilotYourUsual:l.pilotWhatIf,timeColor:previewBed==usualBed?null:const Color(0xFFF5A36B),trailing:previewBed==usualBed?null:TextButton(onPressed:()=>setState(()=>previewBed=usualBed),child:Text(l.pilotReset))),
          if(a.type==PilotAlarmType.sleep)...[
            timeRow('early',l.pilotEarlyWake,a.wakeMinute-a.earlyMinutes,showTime:a.earlyMinutes>0,sub:a.earlyMinutes==0?null:l.pilotUpToEarlier(a.earlyMinutes),trailing:a.earlyMinutes==0?Text('—',style:F.head):TextButton(onPressed:()=>setState(()=>a.earlyMinutes=0),child:Text(l.pilotReset))),
            if(methods&&a.gradual)Opacity(opacity:a.band?1:.4,child:IgnorePointer(ignoring:!a.band,child:timeRow('gradual',l.pilotGradual,expectedMinute-a.gradualMinutes,sub:l.pilotBeforeFire(a.gradualMinutes)))),
            if(methods&&a.sunrise)timeRow('sunrise',l.pilotSunrise,expectedMinute-a.sunriseMinutes,sub:l.pilotBeforeFire(a.sunriseMinutes)),
            timeRow('wake',l.pilotWake,a.wakeMinute),
            if(methods&&a.phoneSound)timeRow('sound',l.pilotPhoneSound,expectedMinute+a.soundDelayMinutes,sub:l.pilotAfterFire(a.soundDelayMinutes)),
            if(methods&&a.phoneVibration)timeRow('vibration',l.pilotPhoneVibration,expectedMinute+a.vibrationDelayMinutes,sub:l.pilotAfterFire(a.vibrationDelayMinutes)),
            if(methods&&a.phoneFlash)timeRow('flash',l.pilotPhoneFlash,expectedMinute+a.flashDelayMinutes,sub:l.pilotAfterFire(a.flashDelayMinutes)),
            ListTile(key:const ValueKey('pilot-band-backup'),contentPadding:EdgeInsets.zero,minTileHeight:56,leading:const Icon(LucideIcons.shieldCheck),title:Text(a.band?l.pilotBandAlarm:l.pilotBandBackup),subtitle:Text(methods&&!a.band?l.pilotBackupAfterLatest:l.pilotBackupAtLatest),trailing:Text(formatClock((a.wakeMinute+(methods&&!a.band?1:0))%1440~/60,(a.wakeMinute+(methods&&!a.band?1:0))%60))),
          ]else...[timeRow('window',l.pilotWindowStart,a.workoutStartMinute),timeRow('wake',l.pilotWindowEnd,a.wakeMinute)],
          SwitchListTile(contentPadding:EdgeInsets.zero,title:Text(l.pilotPrimary),subtitle:Text(a.canBePrimary?l.pilotPrimaryDescription:l.pilotWorkoutNoPrimary),secondary:Icon(LucideIcons.star,color:a.primary?p.on(C.yellow):p.ink3),value:a.primary,onChanged:a.canBePrimary?(v)=>setState(()=>a.primary=v):null),
        ],
        if(tab==1&&a.type==PilotAlarmType.sleep)...[
          if(!methods)Text(l.pilotEnableWakeMethods),
          Text(l.pilotBeforeAlarm,style:F.cap.copyWith(color:p.ink3)),
          toggle(l.pilotSunrise,a.sunrise,(v){setState(()=>a.sunrise=v);if(v)_showNewTiming('sunrise');},sub:a.sunrise?'${l.pilotBeforeOnTimes(a.sunriseMinutes)}\n${l.pilotPhoneLimit}':l.pilotPhoneLimit),
          toggle(l.pilotGradual,a.gradual,(v)=>setState(()=>a.gradual=v),sub:a.gradual?l.pilotBeforeOnTimes(a.gradualMinutes):null),
          if(a.gradual)...[SizedBox(height:56,child:playing?Center(child:LinearProgressIndicator(value:progress)):choices(GradualPattern.values,a.pattern,(v)=>a.pattern=v,(v)=>switch(v){GradualPattern.ramp=>l.pilotRamp,GradualPattern.steady=>l.pilotSteady,GradualPattern.wave=>l.pilotWave})),feelRow()],
          Text(l.pilotWhenAlarm,style:F.cap.copyWith(color:p.ink3)),
          toggle(l.pilotBandBuzz,a.band,(v){var added=false;setState((){a.band=v;if(!v&&!a.phoneSound&&!a.phoneVibration&&!a.phoneFlash){a.phoneSound=true;a.soundDelayMinutes=0;added=true;}});if(added)_showNewTiming('sound');},sub:a.band?null:l.pilotBackupLimit),
          if(a.band)...[choices(['default','custom'],a.customPatternId==null?'default':'custom',(v){if(v=='default'){a.customPatternId=null;}else{_pickPattern();}},(v)=>v=='default'?l.pilotBandDefault:l.pilotMyPattern),Text(l.pilotCustomTradeoff,style:F.cap.copyWith(color:p.ink2)),feelRow()],
          Text(l.pilotStillAsleep,style:F.cap.copyWith(color:p.ink3)),
          toggle(l.pilotPhoneVibration,a.phoneVibration,(v){setState(()=>a.phoneVibration=v);if(v)_showNewTiming('vibration');},sub:a.phoneVibration?'${l.pilotAfterOnTimes(a.vibrationDelayMinutes)}\n${l.pilotPhoneLimit}':l.pilotPhoneLimit),
          toggle(l.pilotPhoneSound,a.phoneSound,(v){setState(()=>a.phoneSound=v);if(v)_showNewTiming('sound');},sub:a.phoneSound?l.pilotAfterOnTimes(a.soundDelayMinutes):null),
          toggle(l.pilotPhoneFlash,a.phoneFlash,(v){setState(()=>a.phoneFlash=v);if(v)_showNewTiming('flash');},sub:a.phoneFlash?'${l.pilotAfterOnTimes(a.flashDelayMinutes)}\n${l.pilotFlashLimit}':l.pilotFlashLimit),
          Text(l.pilotSnooze,style:F.cap.copyWith(color:p.ink3)),
          toggle(l.pilotSnooze,a.snooze,(v)=>setState(()=>a.snooze=v)),
          if(a.snooze)...[
            _IntChoice(label:l.pilotSnoozeLength,value:a.snoozeMinutes,values:const [3,5,9,10,15],onChanged:methods?(v)=>setState(()=>a.snoozeMinutes=v):null),
            _IntChoice(label:l.pilotMaxSnoozes,value:a.maxSnoozes,values:const [0,1,2,3,5,10],onChanged:methods?(v)=>setState(()=>a.maxSnoozes=v):null),
            choices(SnoozeChaos.values,a.chaos,(v)=>a.chaos=v,(v)=>switch(v){SnoozeChaos.steady=>l.pilotSteady,SnoozeChaos.little=>l.pilotLittleChaos,SnoozeChaos.lot=>l.pilotLotChaos,SnoozeChaos.wild=>l.pilotWildChaos}),feelRow(chaos:true),
          ],
          Padding(padding:const EdgeInsets.symmetric(vertical:12),child:Text(l.pilotAwakeExplanation)),
        ],
        if(tab==1&&a.type==PilotAlarmType.workout)...[
          Text(l.pilotWorkoutFailSafe),_IntChoice(label:l.pilotHeartRateZone,value:a.zone,values:const [1,2,3,4,5],onChanged:methods?(v)=>setState(()=>a.zone=v):null),
          _IntChoice(label:l.pilotZoneMinutes,value:a.zoneMinutes,values:const [1,3,5,10,15],onChanged:methods?(v)=>setState(()=>a.zoneMinutes=v):null),
        ],
      ])),
    ])))));
  }
}
class _IntChoice extends StatelessWidget{
  const _IntChoice({required this.label,required this.value,required this.values,this.onChanged});
  final String label;final int value;final List<int> values;final ValueChanged<int>? onChanged;
  @override Widget build(BuildContext context)=>Row(children:[Expanded(child:Text(label)),DropdownButton<int>(value:value,items:[for(final v in {...values,value}.toList()..sort())DropdownMenuItem(value:v,child:Text('$v'))],onChanged:onChanged==null?null:(v)=>onChanged!(v!))]);
}
