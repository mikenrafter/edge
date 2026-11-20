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
import '../ui2/grammar.dart' show BigButton,SubTabs,NavBar;
import '../ui2/skeleton/async_section.dart';
import '../ui2/day_navigation.dart' show DayStepBar;
import '../ui2/profile/profile.dart' show SetRow;
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
  const PilotAlarmScreen({super.key,this.alarms,this.loadAlarms,this.onSave,this.now,this.graph=const DayGraph(),this.stages=const [],this.reference});
  final Future<PilotAlarmReference?> Function(DateTime)? reference;
  final Future<List<PilotAlarm>> Function()? loadAlarms;
  final List<PilotAlarm>? alarms;final Future<void> Function(List<PilotAlarm>)? onSave;
  final DateTime? now;final DayGraph graph;final List<SleepStage?> stages;
  @override State<PilotAlarmScreen> createState()=>_AlarmListState();
}
class _AlarmListState extends State<PilotAlarmScreen>{
  List<PilotAlarm> _alarms=[];String? _error;bool _loading=true,_saving=false;
  AppLocalizations get l=>AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
  @override void initState(){super.initState();if(widget.alarms!=null){_alarms=widget.alarms!.map((a)=>a.copy()).toList();_loading=false;}else{_load();}}
  Future<void> _load()async{try{final a=await (widget.loadAlarms?.call()??PilotAlarmStore.load());if(mounted)setState((){_alarms=a;_loading=false;});}catch(e){if(mounted)setState((){_error=e.toString();_loading=false;});}}
  Future<void> _save(List<PilotAlarm> alarms)async{
    setState(()=>_saving=true);
    var saved=alarms;
    try{if(widget.onSave!=null)await widget.onSave!(alarms);else{await PilotAlarmStore.save(alarms);saved=await PilotAlarmStore.load();if(mounted)await context.read<AppState>().refreshPilotAlarms();}
      if(mounted)setState(()=>_alarms=saved.map((a)=>a.copy()).toList());
    }catch(e){if(mounted)setState(()=>_error=e.toString());rethrow;}
    finally{if(mounted)setState(()=>_saving=false);}
  }
  Future<void> _edit(PilotAlarm alarm,{bool adding=false})async{
    final result=await Navigator.of(context).push<PilotAlarm>(MaterialPageRoute(builder:(_)=>PilotAlarmEditor(alarm:alarm,isNew:adding,now:widget.now,graph:widget.graph,stages:widget.stages,reference:widget.reference,
      onSave:(draft)async{final updated=[for(final a in _alarms)if(a.id!=draft.id)a.copy(),draft.copy()];await _save(updated);} )));
    if(result!=null&&mounted)setState((){});
  }
  Future<void> _add()async{
    // Owner m273: the Material sheet as before, in the mock-up palette (v22
    // .sheet #20283a, text #e8ecf3 / #9aa6b8, pressed row #2a3344).
    final type=await showModalBottomSheet<PilotAlarmType>(context:context,backgroundColor:const Color(0xFF20283A),builder:(c)=>Theme(
      data:Theme.of(c).copyWith(highlightColor:const Color(0xFF2A3344),splashColor:Colors.transparent),
      child:SafeArea(child:Column(mainAxisSize:MainAxisSize.min,children:[
        ListTile(key:const ValueKey('pilot-add:sleep'),minTileHeight:56,leading:Icon(LucideIcons.moon,color:P.of(c).on(C.indigo)),title:Text(l.pilotSleepAlarm,style:const TextStyle(color:Color(0xFFE8ECF3))),subtitle:Text(l.pilotSleepAlarmDescription,style:const TextStyle(color:Color(0xFF9AA6B8))),onTap:()=>Navigator.pop(c,PilotAlarmType.sleep)),
        ListTile(key:const ValueKey('pilot-add:workout'),minTileHeight:56,leading:Icon(LucideIcons.dumbbell,color:P.of(c).on(C.red)),title:Text(l.pilotWorkoutAlarm,style:const TextStyle(color:Color(0xFFE8ECF3))),subtitle:Text(l.pilotWorkoutAlarmDescription,style:const TextStyle(color:Color(0xFF9AA6B8))),onTap:()=>Navigator.pop(c,PilotAlarmType.workout)),
      ]))));
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
    final sorted=[...(_loading?[PilotAlarm(id:'pending',label:l.pilotSleepAlarm)]:_alarms)]..sort((a,b){final x=pilotNextAt(a,now),y=pilotNextAt(b,now);if(x==null)return y==null?0:1;if(y==null)return -1;return x.compareTo(y);});
    final next=sorted.where((a)=>a.enabled).firstOrNull?.id;
    return PilotTheme(child:Builder(builder:(context)=>Scaffold(backgroundColor:p.bg,appBar:PreferredSize(preferredSize:const Size.fromHeight(52),child:SafeArea(bottom:false,child:NavBar(l.pilotAlarms))),floatingActionButton:FloatingActionButton(onPressed:_saving||_loading?null:_add,tooltip:l.pilotAddAlarm,child:const Icon(LucideIcons.plus)),
      body:ListView(padding:const EdgeInsets.all(16),children:[
        if(app!=null)_activeWake(app),if(_error!=null)Text(_error!),if(!_loading&&_alarms.isEmpty)Text(l.pilotNoAlarms),
        for(final a in sorted)PendingContent(pending:_loading,child:Padding(padding:const EdgeInsets.only(bottom:12),child:GestureDetector(onTap:()=>_edit(a),behavior:HitTestBehavior.opaque,child:Container(key:ValueKey('pilot-alarm:${a.id}'),padding:const EdgeInsets.fromLTRB(16,12,12,14),decoration:BoxDecoration(color:p.card,border:Border.all(color:a.id==next?p.on(C.blue):p.line),borderRadius:BorderRadius.circular(16)),child:Column(children:[
          // Mock-up v22 .acard .head: star, label, "next" on the left; the repeat
          // days and the switch on the right (m261). The whole card opens the editor.
          // The name is capped, not Flexible: a Flexible beside the Expanded days
          // would split the free space and leave a gap after the switch.
          LayoutBuilder(builder:(context,box)=>Row(children:[if(a.primary)...[Icon(LucideIcons.star,color:p.on(C.yellow),size:14),const SizedBox(width:6)],
            ConstrainedBox(constraints:BoxConstraints(maxWidth:box.maxWidth*.45),child:Text(a.label,maxLines:1,overflow:TextOverflow.ellipsis,style:F.body.copyWith(color:p.ink,fontWeight:FontWeight.w600))),
            if(a.id==next)...[const SizedBox(width:4),Text(l.pilotNext.toLowerCase(),style:F.cap.copyWith(color:p.on(C.blue),fontSize:11))],
            const SizedBox(width:8),
            Expanded(child:Row(mainAxisAlignment:MainAxisAlignment.end,children:[Icon(LucideIcons.repeat,size:12,color:p.ink3),const SizedBox(width:3),
              Flexible(child:Text(_daysLabel(a,l),key:ValueKey('pilot-alarm-days:${a.id}'),maxLines:1,overflow:TextOverflow.ellipsis,textAlign:TextAlign.right,style:F.cap.copyWith(color:p.ink3)))])),
            const SizedBox(width:8),
            Switch(value:a.enabled,onChanged:_saving?null:(v){final copies=_alarms.map((x)=>x.copy()).toList();copies.firstWhere((x)=>x.id==a.id).enabled=v;unawaited(_save(copies).catchError((_){ }));})])),
          const SizedBox(height:10),
          // v22 .acard.off.dim: an off alarm's graph keeps every mark and range, at .35.
          Opacity(opacity:a.enabled?1:.35,child:IgnorePointer(child:_AlarmChart(alarm:a,now:now,graph:widget.graph,stages:widget.stages,reference:widget.reference,pending:_loading))),
        ]))))),
      ]))));
  }
}
String _wakeText(PilotAlarm a){final w=formatClock(a.wakeMinute~/60,a.wakeMinute%60);if(a.earlyMinutes<=0)return w;final e=a.wakeMinute-a.earlyMinutes;return '${formatClock(((e%1440)+1440)%1440~/60,((e%60)+60)%60)}–$w';}
String _daysLabel(PilotAlarm a,AppLocalizations l)=>a.days.isEmpty?l.pilotOnce:a.days.length==7?l.pilotEveryDay:a.days.length==5&&a.days.containsAll({1,2,3,4,5})?l.pilotWeekdays:a.days.length==2&&a.days.containsAll({6,7})?l.pilotWeekends:a.days.toList().sortedDays(l);
// Mock-up v22 daysText: three or more days in a row read as a range (Mon–Wed, Fri).
extension on List<int>{String sortedDays(AppLocalizations l){sort();final names=[l.pilotMonday,l.pilotTuesday,l.pilotWednesday,l.pilotThursday,l.pilotFriday,l.pilotSaturday,l.pilotSunday];
  final runs=<List<int>>[];for(final d in this){if(runs.isNotEmpty&&runs.last.last==d-1){runs.last.add(d);}else{runs.add([d]);}}
  return [for(final r in runs)r.length>=3?'${names[r.first-1]}–${names[r.last-1]}':r.map((d)=>names[d-1]).join(', ')].join(', ');}}

class _AlarmChart extends StatefulWidget{
  const _AlarmChart({required this.alarm,required this.now,required this.graph,required this.stages,this.reference,this.pending=false});
  final Future<PilotAlarmReference?> Function(DateTime)? reference;
  final bool pending;
  final PilotAlarm alarm;final DateTime now;final DayGraph graph;final List<SleepStage?> stages;
  @override State<_AlarmChart> createState()=>_AlarmChartState();
}
class _AlarmChartState extends State<_AlarmChart>{
  late final TimelineController c;final interaction=TimelineInteraction(retention:PilotScrub.temporary);
  bool _reading=false;
  late final int start;DayGraph? measured;List<SleepStage?>? recorded;int? bed,expected,usualSleepMinutes;
  @override void initState(){super.initState();final day=DateTime(widget.now.year,widget.now.month,widget.now.day);start=day.millisecondsSinceEpoch~/1000;
    c=TimelineController(glideDuration:const Duration(milliseconds:450),homeStartSec:DateTime(day.year,day.month,day.day-1,12).millisecondsSinceEpoch~/1000,homeEndSec:DateTime(day.year,day.month,day.day+1,18).millisecondsSinceEpoch~/1000);
    _reading=!widget.pending&&(widget.reference!=null||widget.graph.slots==0);
    _range();if(!widget.pending&&(widget.reference!=null||widget.graph.slots==0))WidgetsBinding.instance.addPostFrameCallback((_)=>_load());
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
    finally{if(mounted)setState(()=>_reading=false);}
  }
  @override void didUpdateWidget(_AlarmChart old){super.didUpdateWidget(old);if(old.alarm.wakeMinute!=widget.alarm.wakeMinute||old.alarm.earlyMinutes!=widget.alarm.earlyMinutes)_range();}
  @override void dispose(){c.dispose();interaction.dispose();super.dispose();}
  @override Widget build(BuildContext context){
    final a=widget.alarm,l=AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
    final annotations=pilotAlarmAnnotations(a,l,start,bedMinute:bed,expectedWake:expected);
    final waking=annotations.where((v)=>v.id!='bed').map((v)=>v.at).toList();
    final left=bed==null?null:start+(bed!+50)*60.0,right=waking.isEmpty?null:waking.reduce(math.min)-600;
    final cut=left!=null&&right!=null&&right>left+1200?PilotTimelineCut(leftEnd:left,rightStart:right):null;
    final p=P.of(context);
    // m261: the three stats are right-aligned.
    Widget stat(String label,String value)=>Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.end,children:[Text(label,textAlign:TextAlign.right,style:F.cap.copyWith(color:p.ink3)),Text(value,maxLines:1,overflow:TextOverflow.ellipsis,textAlign:TextAlign.right,style:F.body.copyWith(color:p.ink,fontWeight:FontWeight.w500))]));
    // v22 .mchart: a 72 px graph (it grows only if stacked icons need it).
    return PendingContent(pending:widget.pending||_reading,child:Column(children:[PilotTimelineChart(controller:c,graph:measured??widget.graph,interaction:interaction,stages:a.type==PilotAlarmType.sleep?recorded??widget.stages:const [],height:72,overview:true,cut:cut,annotations:annotations,showHeartRate:a.type==PilotAlarmType.workout),
      const SizedBox(height:10),
      // Mock-up v22 statsOf(): Wake (a range with early wake), Expected,
      // Usual sleep; workout: Window, Zone, Buzzes at.
      Row(children:a.type==PilotAlarmType.sleep?[
        stat(l.pilotWakeShort,_wakeText(a)),
        stat(l.pilotExpectedShort,expected==null?'—':formatClock(expected!~/60,expected!%60)),
        if(bed!=null||widget.pending||_reading)stat(l.pilotUsualSleep,usualSleepMinutes==null?'—':pilotForecastText(l,usualSleepMinutes!)),
      ]:[
        stat(l.pilotWindow,'${formatClock(a.workoutStartMinute~/60,a.workoutStartMinute%60)}–${formatClock(a.wakeMinute~/60,a.wakeMinute%60)}'),
        stat(l.pilotZone,l.pilotZoneAtLeast(a.zone)),
        stat(l.pilotBuzzesAt,formatClock(a.wakeMinute~/60,a.wakeMinute%60)),
      ]),
    ]));
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
  const PilotAlarmEditor({super.key,required this.alarm,required this.onSave,this.now,this.graph=const DayGraph(),this.stages=const [],this.reference,this.isNew=false});
  /// Opened from + (v22 open(nw)): titled "New … alarm" until it is saved.
  final bool isNew;
  final Future<PilotAlarmReference?> Function(DateTime)? reference;
  final PilotAlarm alarm;final Future<void> Function(PilotAlarm) onSave;final DateTime? now;final DayGraph graph;final List<SleepStage?> stages;
  @override State<PilotAlarmEditor> createState()=>_AlarmEditorState();
}
class _AlarmEditorState extends State<PilotAlarmEditor> with TickerProviderStateMixin {
  late PilotAlarm a;late TimelineController c;late int start;int tab=0;String focus='wake';bool repeat=false,saving=false,playing=false;double progress=0;String? error;
  bool _referencePending=false;
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
    _referencePending=widget.reference!=null||widget.graph.slots==0;
    if(_referencePending)WidgetsBinding.instance.addPostFrameCallback((_)=>_loadReference());
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
    setState(()=>_referencePending=true);
    try{
      PilotAlarmReference? sample;
      if(widget.reference!=null){sample=await widget.reference!(selected);}else{
        sample=await loadPilotAlarmReference(context,start,selected.weekday,sleep:a.type==PilotAlarmType.sleep);
      }
      if(mounted&&epoch==_referenceEpoch)setState((){stages=sample?.stages??widget.stages;measured=sample?.graph;usualBed=previewBed=sample?.bedMinute;
        final wm=sample?.wakeMinute;expectedWake=wm!=null&&wm>=a.wakeMinute-a.earlyMinutes&&wm<=a.wakeMinute?wm:null;if(night==0)_runtimeExpectedWake=expectedWake;});
    }catch(_){/* Missing reference data stays absent. */}
    finally{if(mounted&&epoch==_referenceEpoch)setState(()=>_referencePending=false);}
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
  // The app's settings row (SetRow + Switch, as in profile/alarm.dart), with
  // the hairline the mock-up's .opt rows carry. The whole row toggles.
  Widget toggle(String title,bool value,ValueChanged<bool> change,{String? sub,IconData icon=LucideIcons.toggleRight,Color color=C.blue})=>Column(children:[
    Divider(height:1,color:P.of(context).line),
    SetRow(icon,color,title,sub:sub??'',chevron:false,enabled:methods,onTap:()=>change(!value),trailing:Switch(value:value,onChanged:methods?change:null)),
  ]);
  Widget section(String text)=>Padding(padding:const EdgeInsets.fromLTRB(2,16,2,4),child:Text(text.toUpperCase(),style:F.cap.copyWith(color:P.of(context).ink3,fontSize:11,letterSpacing:.4)));
  static const _timing={'bed':(LucideIcons.moon,C.indigo),'early':(LucideIcons.sunrise,C.teal),'gradual':(LucideIcons.vibrate,C.yellow),'sunrise':(LucideIcons.sun,C.orange),
    'wake':(LucideIcons.alarmClock,C.orange),'sound':(LucideIcons.volume2,C.pink),'vibration':(LucideIcons.smartphone,C.pink),'flash':(LucideIcons.flashlight,C.pink),'window':(LucideIcons.dumbbell,C.red)};
  Widget timeRow(String id,String title,int value,{String? sub,Widget? trailing,Color? timeColor,bool showTime=true})=>GestureDetector(
    key:ValueKey('pilot-time:$id'),dragStartBehavior:DragStartBehavior.down,onHorizontalDragStart:(_){_rowStart=_minuteFor(id);_rowDrag=0;select(id,start+_rowStart*60.0);},
    onHorizontalDragUpdate:(d){_rowDrag+=d.delta.dx;final moved=(_rowDrag/10).round()*5;_handle(id,start+(_rowStart+moved)*60.0);},
    child:Builder(builder:(context){final p=P.of(context),look=_timing[id]??(LucideIcons.clock,C.blue);
      final glow=_glowingTimings.contains(id)&&_rowGlow.isAnimating?p.on(C.blue).withValues(alpha:.3*math.sin(math.pi*_rowGlow.value)):null;
      return PilotItemRow(icon:look.$1,color:look.$2,title:title,selected:focus==id,glow:glow,action:trailing,timeColor:timeColor,onTap:()=>select(id,start+value*60.0),
        time:showTime?formatClock(((value%1440)+1440)%1440~/60,((value%60)+60)%60):'—',timeSub:sub);}));

  Widget _resetChip(VoidCallback tap)=>PilotRowChip(l.pilotReset,onTap:tap);
  Widget feelRow({bool chaos=false})=>Row(children:[TextButton.icon(onPressed:playing?null:()=>_feel(chaos:chaos),icon:const Icon(LucideIcons.vibrate,size:16),label:Text(l.pilotFeelIt)),const Spacer(),TextButton(onPressed:()=>Navigator.of(context).push(MaterialPageRoute(builder:(_)=>const HapticsSettings())),child:Text(l.pilotHaptics))]);
  Widget choices<T>(List<T> values,T selected,ValueChanged<T> change,String Function(T) label)=>Wrap(spacing:6,children:[for(final v in values)ChoiceChip(label:Text(label(v)),selected:v==selected,onSelected:methods?(_)=>setState(()=>change(v)):null,materialTapTargetSize:MaterialTapTargetSize.padded)]);
  @override Widget build(BuildContext context){
    final p=P.of(context);
    final graph=measured??widget.graph;
    final tabs=a.type==PilotAlarmType.sleep?[l.pilotTimes,l.pilotWaking]:[l.pilotWindow,l.pilotHeartRate];
    final handles=[PilotHandle(focus,start+_minuteFor(focus)*60.0,p.on(C.blue))];
    return PilotTheme(child:Builder(builder:(context)=>Scaffold(backgroundColor:p.bg,body:SafeArea(child:Column(children:[
      // Mock-up v22 .navx: filled Cancel / Save (the app's dense BigButton).
      Padding(padding:const EdgeInsets.fromLTRB(16,6,16,6),child:Row(children:[
        SizedBox(width:92,child:BigButton(l.pilotCancel,dense:true,soft:true,color:C.n500,onTap:saving?null:()=>Navigator.pop(context))),
        Expanded(child:Text(widget.isNew?(a.type==PilotAlarmType.sleep?l.pilotNewSleepAlarm:l.pilotNewWorkoutAlarm):l.pilotEditAlarm(a.label),maxLines:1,overflow:TextOverflow.ellipsis,textAlign:TextAlign.center,style:F.head.copyWith(color:p.ink))),
        SizedBox(width:92,child:BigButton(l.pilotSave,dense:true,color:C.indigo,busy:saving,onTap:saving?null:_save))])),
      // Owner m261: the app's one day switcher (DayStepBar), stepping nights.
      if(a.type==PilotAlarmType.sleep)Padding(padding:const EdgeInsets.fromLTRB(16,0,16,6),child:DayStepBar(key:const ValueKey('pilot-night-pager'),
        label:nights.isEmpty?l.pilotTonight:_nightLabel(nights[night.clamp(0,nights.length-1)]),previousLabel:l.pilotPreviousNight,nextLabel:l.pilotNextNight,
        previousKey:const ValueKey('pilot-night-previous'),nextKey:const ValueKey('pilot-night-next'),
        onPrevious:night>0?()=>_pageNight(night-1):null,onNext:night<nights.length-1?()=>_pageNight(night+1):null)),
      Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:PendingContent(pending:_referencePending,child:PilotTimelineChart(controller:c,graph:graph,interaction:interaction,stages:stages,handles:handles,selectedAnnotationId:focus,onHandle:_handle,onSelect:(id){if({'bed','wake','early','gradual','sunrise','sound','vibration','flash','window'}.contains(id))select(id,start+_minuteFor(id)*60.0);},
        showHeartRate:a.type==PilotAlarmType.workout,showHeader:false,annotations:pilotAlarmAnnotations(a,l,start,bedMinute:previewBed,expectedWake:expectedWake)))),
      // Mock-up v22 .tabs; a new phone timing flashes the Times tab (m206).
      Padding(padding:const EdgeInsets.fromLTRB(16,6,16,0),child:Stack(children:[
        SubTabs(tabs,tab,_openTab,color:C.blue,itemKeys:[for(final t in tabs)ValueKey('pilot-alarm-tab:$t')]),
        if(_tabFlash.isAnimating)Positioned.fill(child:IgnorePointer(child:FractionallySizedBox(alignment:Alignment.centerLeft,widthFactor:1/tabs.length,
          child:DecoratedBox(key:const ValueKey('pilot-times-flash'),decoration:BoxDecoration(color:p.on(C.blue).withValues(alpha:.6*math.pow(math.sin(2*math.pi*_tabFlash.value),2).toDouble()),borderRadius:BorderRadius.circular(10)))))),
      ])),
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
              rest:a.type==PilotAlarmType.sleep?[(l.pilotWakeShort,_wakeText(a)),(l.pilotExpectedShort,expectedWake==null?'—':formatClock(expectedWake!~/60,expectedWake!%60)),(l.pilotUsualSleep,previewBed==null?'—':pilotForecastText(l,(expectedMinute-previewBed!).clamp(0,1440)))]
                :[(l.pilotWindow,'${formatClock(a.workoutStartMinute~/60,a.workoutStartMinute%60)}–${formatClock(a.wakeMinute~/60,a.wakeMinute%60)}'),(l.pilotZone,l.pilotZoneAtLeast(a.zone)),(l.pilotBuzzesAt,formatClock(a.wakeMinute~/60,a.wakeMinute%60))],
              title:Align(alignment:Alignment.centerLeft,child:TextButton(onPressed:_rename,style:TextButton.styleFrom(padding:EdgeInsets.zero,foregroundColor:p.ink),child:Row(mainAxisSize:MainAxisSize.min,children:[Flexible(child:Text(a.label,maxLines:1,overflow:TextOverflow.ellipsis,style:F.body.copyWith(fontWeight:FontWeight.w600))),const SizedBox(width:6),Icon(LucideIcons.pencil,size:14,color:p.ink3)]))))),
            if(repeat)const Spacer(),
            PilotZoomControls(controller:c,onZoom:interaction.zoom,trailing:Align(alignment:Alignment.centerRight,child:TextButton.icon(onPressed:()=>setState(()=>repeat=!repeat),icon:Icon(repeat?LucideIcons.check:LucideIcons.repeat,size:16),label:Text(repeat?l.pilotDone:_daysLabel(a,l),maxLines:1,overflow:TextOverflow.ellipsis)))),
          ]))),
          section(a.type==PilotAlarmType.workout?l.pilotWindowHint:l.pilotTimesHint),
          if(a.type==PilotAlarmType.sleep&&previewBed!=null)timeRow('bed',l.pilotFallAsleep,previewBed!,sub:previewBed==usualBed?l.pilotYourUsual:l.pilotWhatIf,timeColor:previewBed==usualBed?null:const Color(0xFFF5A36B),trailing:previewBed==usualBed?null:_resetChip(()=>setState(()=>previewBed=usualBed))),
          if(a.type==PilotAlarmType.sleep)...[
            timeRow('early',l.pilotEarlyWake,a.wakeMinute-a.earlyMinutes,showTime:a.earlyMinutes>0,sub:a.earlyMinutes==0?null:l.pilotUpToEarlier(a.earlyMinutes).replaceFirst('U','u'),trailing:a.earlyMinutes==0?null:PilotRowChip(l.pilotDisable,onTap:()=>setState(()=>a.earlyMinutes=0))),
            if(methods&&a.gradual)Opacity(opacity:a.band?1:.4,child:IgnorePointer(ignoring:!a.band,child:timeRow('gradual',l.pilotGradualStarts,expectedMinute-a.gradualMinutes,sub:l.pilotBeforeFire(a.gradualMinutes)))),
            if(methods&&a.sunrise)timeRow('sunrise',l.pilotSunriseStarts,expectedMinute-a.sunriseMinutes,sub:l.pilotBeforeFire(a.sunriseMinutes)),
            timeRow('wake',l.pilotWake,a.wakeMinute),
            if(methods&&a.phoneSound)timeRow('sound',l.pilotPhoneSound,expectedMinute+a.soundDelayMinutes,sub:l.pilotAfterFire(a.soundDelayMinutes)),
            if(methods&&a.phoneVibration)timeRow('vibration',l.pilotPhoneVibration,expectedMinute+a.vibrationDelayMinutes,sub:l.pilotAfterFire(a.vibrationDelayMinutes)),
            if(methods&&a.phoneFlash)timeRow('flash',l.pilotPhoneFlash,expectedMinute+a.flashDelayMinutes,sub:l.pilotAfterFire(a.flashDelayMinutes)),
            // Mock-up v22 .item.ro: read-only at 85%, the time in #c9d2e0, "fixed" under it.
            Opacity(opacity:.85,child:PilotItemRow(key:const ValueKey('pilot-band-backup'),icon:a.band?LucideIcons.watch:LucideIcons.shieldCheck,color:C.blue,title:a.band?l.pilotBandAlarm:l.pilotBandBackup,
              titleSub:methods&&!a.band?l.pilotBackupAfterLatest:l.pilotBackupAtLatest,timeColor:const Color(0xFFC9D2E0),timeSub:l.pilotFixed,
              time:formatClock((a.wakeMinute+(methods&&!a.band?1:0))%1440~/60,(a.wakeMinute+(methods&&!a.band?1:0))%60))),
          ]else...[timeRow('window',l.pilotWindowStart,a.workoutStartMinute),timeRow('wake',l.pilotWindowEnd,a.wakeMinute)],
          Divider(height:1,color:p.line),
          // Mock-up v22 #primRow (m165, m254): the whole row is the switch; a
          // bare star (#f2c94c filled on, #7f8ba0 off), no tile and no Switch.
          // A workout alarm shows the row at .45, inert.
          Semantics(key:const ValueKey('pilot-primary'),toggled:a.canBePrimary&&a.primary,enabled:a.canBePrimary,onTap:a.canBePrimary?()=>setState(()=>a.primary=!a.primary):null,excludeSemantics:true,
            label:'${a.canBePrimary&&a.primary?l.pilotPrimaryOn:l.pilotPrimaryOff}. ${a.canBePrimary?'${a.primary?l.pilotPrimaryTapToStop:l.pilotPrimaryTapToMake} ${l.pilotPrimarySub}':l.pilotPrimaryWorkoutSub}',
            child:Opacity(opacity:a.canBePrimary?1:.45,child:GestureDetector(behavior:HitTestBehavior.opaque,onTap:a.canBePrimary?()=>setState(()=>a.primary=!a.primary):null,
              child:ConstrainedBox(constraints:const BoxConstraints(minHeight:44),child:Padding(padding:const EdgeInsets.symmetric(vertical:8),child:Row(children:[
                SizedBox(width:40,height:40,child:Icon(a.canBePrimary&&a.primary?Icons.star_rounded:LucideIcons.star,size:a.canBePrimary&&a.primary?23:20,color:a.canBePrimary&&a.primary?const Color(0xFFF2C94C):const Color(0xFF7F8BA0))),
                const SizedBox(width:10),
                Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Text(a.canBePrimary&&a.primary?l.pilotPrimaryOn:l.pilotPrimaryOff,style:F.body.copyWith(color:p.ink)),
                  Text(a.canBePrimary?'${a.primary?l.pilotPrimaryTapToStop:l.pilotPrimaryTapToMake} ${l.pilotPrimarySub}':l.pilotPrimaryWorkoutSub,style:F.cap.copyWith(color:const Color(0xFF9AA6B8),fontSize:12)),
                ])),
              ])))))),
        ],
        if(tab==1&&a.type==PilotAlarmType.sleep)...[
          if(!methods)Text(l.pilotEnableWakeMethods),
          section(l.pilotBeforeAlarm),
          toggle(l.pilotSunrise,a.sunrise,(v){setState(()=>a.sunrise=v);if(v)_showNewTiming('sunrise');},sub:a.sunrise?'${l.pilotBeforeOnTimes(a.sunriseMinutes)}\n${l.pilotPhoneLimit}':l.pilotPhoneLimit,icon:LucideIcons.sun,color:C.orange),
          toggle(l.pilotGradual,a.gradual,(v)=>setState(()=>a.gradual=v),sub:a.gradual?l.pilotBeforeOnTimes(a.gradualMinutes):null,icon:LucideIcons.vibrate,color:C.yellow),
          if(a.gradual)...[SizedBox(height:56,child:playing?const Center(child:PendingMark()):choices(GradualPattern.values,a.pattern,(v)=>a.pattern=v,(v)=>switch(v){GradualPattern.ramp=>l.pilotRamp,GradualPattern.steady=>l.pilotSteady,GradualPattern.wave=>l.pilotWave})),feelRow()],
          section(l.pilotWhenAlarm),
          toggle(l.pilotBandBuzz,a.band,(v){var added=false;setState((){a.band=v;if(!v&&!a.phoneSound&&!a.phoneVibration&&!a.phoneFlash){a.phoneSound=true;a.soundDelayMinutes=0;added=true;}});if(added)_showNewTiming('sound');},sub:a.band?null:l.pilotBackupLimit,icon:LucideIcons.watch,color:C.blue),
          if(a.band)...[choices(['default','custom'],a.customPatternId==null?'default':'custom',(v){if(v=='default'){a.customPatternId=null;}else{_pickPattern();}},(v)=>v=='default'?l.pilotBandsAlarm:l.pilotMyPattern),feelRow(),Text(l.pilotCustomTradeoff,style:F.cap.copyWith(color:p.ink2))],
          section(l.pilotStillAsleep),
          toggle(l.pilotPhoneSound,a.phoneSound,(v){setState(()=>a.phoneSound=v);if(v)_showNewTiming('sound');},sub:a.phoneSound?l.pilotAfterOnTimes(a.soundDelayMinutes):null,icon:LucideIcons.volume2,color:C.pink),
          toggle(l.pilotPhoneVibration,a.phoneVibration,(v){setState(()=>a.phoneVibration=v);if(v)_showNewTiming('vibration');},sub:a.phoneVibration?'${l.pilotAfterOnTimes(a.vibrationDelayMinutes)}\n${l.pilotPhoneLimit}':l.pilotPhoneLimit,icon:LucideIcons.smartphone,color:C.pink),
          toggle(l.pilotPhoneFlash,a.phoneFlash,(v){setState(()=>a.phoneFlash=v);if(v)_showNewTiming('flash');},sub:a.phoneFlash?'${l.pilotAfterOnTimes(a.flashDelayMinutes)}\n${l.pilotFlashLimit}':l.pilotFlashLimit,icon:LucideIcons.flashlight,color:C.pink),
          section(l.pilotSnooze),
          toggle(l.pilotSnooze,a.snooze,(v)=>setState(()=>a.snooze=v),icon:LucideIcons.alarmClockMinus,color:C.n500),
          if(a.snooze)...[
            // Mock-up v22: Length and At most as chips, like the chaos row.
            Row(children:[SizedBox(width:64,child:Text(l.pilotSnoozeLengthShort,style:F.cap.copyWith(color:p.ink3))),Expanded(child:choices([...{5,9,15,a.snoozeMinutes}]..sort(),a.snoozeMinutes,(v)=>a.snoozeMinutes=v,(v)=>l.activityLengthMinutes(v)))]),
            Row(children:[SizedBox(width:64,child:Text(l.pilotSnoozeAtMost,style:F.cap.copyWith(color:p.ink3))),Expanded(child:choices([...{1,3,5,a.maxSnoozes}]..sort(),a.maxSnoozes,(v)=>a.maxSnoozes=v,(v)=>'$v×'))]),
            choices(SnoozeChaos.values,a.chaos,(v)=>a.chaos=v,(v)=>switch(v){SnoozeChaos.steady=>l.pilotSteady,SnoozeChaos.little=>l.pilotLittleChaos,SnoozeChaos.lot=>l.pilotLotChaos,SnoozeChaos.wild=>l.pilotWildChaos}),feelRow(chaos:true),
          ],
          // Mock-up .awake: a tinted note with the hand icon.
          Container(margin:const EdgeInsets.only(top:12),padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:p.wash(C.blue),borderRadius:BorderRadius.circular(12)),
            child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Icon(LucideIcons.hand,size:18,color:p.on(C.blue)),const SizedBox(width:8),Expanded(child:Text(l.pilotAwakeExplanation,style:F.cap.copyWith(color:p.ink)))])),
        ],
        if(tab==1&&a.type==PilotAlarmType.workout)...[
          section(l.pilotHeartRateZone),choices([1,2,3,4,5],a.zone,(v)=>a.zone=v,(v)=>l.pilotZoneAtLeast(v).replaceAll('+','')),
          section(l.pilotZoneMinutes),choices([...{2,5,10,a.zoneMinutes}]..sort(),a.zoneMinutes,(v)=>a.zoneMinutes=v,(v)=>l.activityLengthMinutes(v)),
          Container(margin:const EdgeInsets.only(top:12),padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:p.wash(C.blue),borderRadius:BorderRadius.circular(12)),
            child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Icon(LucideIcons.shieldCheck,size:18,color:p.on(C.blue)),const SizedBox(width:8),Expanded(child:Text(l.pilotWorkoutFailSafe,style:F.cap.copyWith(color:p.ink)))])),
        ],
      ])),
    ])))));
  }
}
