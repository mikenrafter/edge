import 'recorded_stages.dart';
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
  const PilotAlarmScreen({super.key,this.alarms,this.onSave,this.now,this.graph=const DayGraph(),this.stages=const []});
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
    final result=await Navigator.of(context).push<PilotAlarm>(MaterialPageRoute(builder:(_)=>PilotAlarmEditor(alarm:alarm,now:widget.now,graph:widget.graph,stages:widget.stages,
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
          Row(children:[if(a.primary)Icon(LucideIcons.star,color:p.on(C.yellow),size:18),Expanded(child:TextButton(onPressed:()=>_edit(a),child:Align(alignment:Alignment.centerLeft,child:Text(a.label,maxLines:1,overflow:TextOverflow.ellipsis)))),if(a.id==next)Text(l.pilotNext,style:F.cap.copyWith(color:p.on(C.blue))),Switch(value:a.enabled,onChanged:_saving?null:(v){final copies=_alarms.map((x)=>x.copy()).toList();copies.firstWhere((x)=>x.id==a.id).enabled=v;unawaited(_save(copies).catchError((_){ }));})]),
          Opacity(opacity:a.enabled?1:.35,child:IgnorePointer(child:_AlarmChart(alarm:a,now:now,graph:widget.graph,stages:widget.stages))),
          Row(children:[Expanded(child:Text(_daysLabel(a,l),maxLines:1,overflow:TextOverflow.ellipsis)),Text(formatClock(a.wakeMinute~/60,a.wakeMinute%60),style:F.head.copyWith(color:p.ink,fontSize:22))]),
        ]))),
      ]))));
  }
}
String _daysLabel(PilotAlarm a,AppLocalizations l)=>a.days.isEmpty?l.pilotOnce:a.days.length==7?l.pilotEveryDay:a.days.length==5&&a.days.containsAll({1,2,3,4,5})?l.pilotWeekdays:a.days.length==2&&a.days.containsAll({6,7})?l.pilotWeekends:a.days.toList().sortedDays(l);
extension on List<int>{String sortedDays(AppLocalizations l){sort();final names=[l.pilotMonday,l.pilotTuesday,l.pilotWednesday,l.pilotThursday,l.pilotFriday,l.pilotSaturday,l.pilotSunday];return map((d)=>names[d-1]).join(', ');}}

class _AlarmChart extends StatefulWidget{
  const _AlarmChart({required this.alarm,required this.now,required this.graph,required this.stages});
  final PilotAlarm alarm;final DateTime now;final DayGraph graph;final List<SleepStage?> stages;
  @override State<_AlarmChart> createState()=>_AlarmChartState();
}
class _AlarmChartState extends State<_AlarmChart>{
  late final TimelineController c;final interaction=TimelineInteraction(retention:PilotScrub.temporary);
  late final DateTime day;
  @override void initState(){super.initState();day=DateTime(widget.now.year,widget.now.month,widget.now.day);final s=day.millisecondsSinceEpoch~/1000;c=TimelineController(homeStartSec:s,homeEndSec:DateTime(day.year,day.month,day.day+1).millisecondsSinceEpoch~/1000);final at=s+widget.alarm.wakeMinute*60;c.selectRange(at-9000,at+3600);}
  @override void dispose(){c.dispose();interaction.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>PilotTimelineChart(controller:c,graph:widget.graph,interaction:interaction,stages:widget.stages,height:70,
    annotations:[ChartAnnotation(id:widget.alarm.id,kind:widget.alarm.type==PilotAlarmType.sleep?AnnotationKind.wake:AnnotationKind.workout,at:day.millisecondsSinceEpoch/1000+widget.alarm.wakeMinute*60,label:widget.alarm.label)]);
}

class PilotAlarmEditor extends StatefulWidget{
  const PilotAlarmEditor({super.key,required this.alarm,required this.onSave,this.now,this.graph=const DayGraph(),this.stages=const []});
  final PilotAlarm alarm;final Future<void> Function(PilotAlarm) onSave;final DateTime? now;final DayGraph graph;final List<SleepStage?> stages;
  @override State<PilotAlarmEditor> createState()=>_AlarmEditorState();
}
class _AlarmEditorState extends State<PilotAlarmEditor> with TickerProviderStateMixin {
  late PilotAlarm a;late TimelineController c;late int start;int tab=0;String focus='wake';bool repeat=false,saving=false,playing=false;double progress=0;String? error;
  DayGraph? measured;List<SleepStage?> stages=[];int? usualBed,expectedWake;
  final interaction=TimelineInteraction(retention:PilotScrub.temporary);
  HapticCancel? _playback;
  late final AnimationController _tabFlash=AnimationController(vsync:this,duration:const Duration(seconds:1))..addListener(_animate);
  late final AnimationController _rowGlow=AnimationController(vsync:this,duration:const Duration(milliseconds:900))..addListener(_animate);
  String? _freshTiming,_glowingTiming;double _rowDrag=0;int _rowStart=0;
  void _animate(){if(mounted)setState((){});}
  void _openTab(int value){setState(()=>tab=value);if(value==0&&_freshTiming!=null){_glowingTiming=_freshTiming;_freshTiming=null;_rowGlow.forward(from:0);}}
  AppLocalizations get l=>AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
  bool get methods=>PilotFlag.wakeMethods.enabled;
  @override void initState(){super.initState();a=widget.alarm.copy();final now=widget.now??DateTime.now();final day=DateTime(now.year,now.month,now.day);start=day.millisecondsSinceEpoch~/1000;
    c=TimelineController(homeStartSec:DateTime(day.year,day.month,day.day-1,18).millisecondsSinceEpoch~/1000,homeEndSec:DateTime(day.year,day.month,day.day+1,18).millisecondsSinceEpoch~/1000);
    c.selectRange(start+a.wakeMinute*60-9000,start+a.wakeMinute*60+3600);stages=widget.stages;
    if(widget.graph.slots==0)WidgetsBinding.instance.addPostFrameCallback((_)=>_loadReference());
  }
  Future<void> _loadReference()async{
    try{
      final repo=repoOf(context);if(repo==null)return;final days=await repo.availableDays();
      final matching=days.where((d)=>a.days.contains(DateTime.parse(d).weekday)).take(4);
      for(final day in matching){final raw=await repo.getDayTimeline(day);final g=dayGraph(raw);if(g.rest.isEmpty)continue;
        final rest=g.rest.first,base=g.dayStart;if(base==null)continue;
        final wake=DateTime.fromMillisecondsSinceEpoch((base+rest.$2*60)*1000),bed=DateTime.fromMillisecondsSinceEpoch((base+rest.$1*60)*1000);
        final wm=wake.hour*60+wake.minute;
        final offset=start+wm*60-(base+rest.$2*60);
        final reference=await repo.getSleepDetailPrimary(day);
        final actualStages=recordedStages(reference?.bundle.night??{},origin:base+offset,slots:g.slots,shiftSeconds:offset);
        if(mounted)setState((){stages=actualStages;measured=DayGraph(hr:g.hr,movement:g.movement,rest:g.rest,work:g.work,dayStart:base+offset);usualBed=bed.hour*60+bed.minute;expectedWake=wm>=a.wakeMinute-a.earlyMinutes&&wm<=a.wakeMinute?wm:null;});break;
      }
    }catch(_){/* Missing reference data stays absent. */}
  }
  @override void dispose(){_tabFlash.dispose();_rowGlow.dispose();_playback?.cancel();interaction.dispose();c.dispose();super.dispose();}
  int minute(double at)=>((at-start)/60).round();
  int get expectedMinute=>expectedWake??a.wakeMinute;
  int _minuteFor(String id)=>switch(id){'early'=>a.wakeMinute-a.earlyMinutes,'gradual'=>expectedMinute-a.gradualMinutes,'sunrise'=>expectedMinute-a.sunriseMinutes,'sound'=>expectedMinute+a.soundDelayMinutes,'vibration'=>expectedMinute+a.vibrationDelayMinutes,'window'=>a.workoutStartMinute,_=>a.wakeMinute};
  void _handle(String id,double at){setState((){tab=0;focus=id;final m=minute(at);
    switch(id){
      case 'wake':final next=m.clamp(0,1439),delta=next-a.wakeMinute;a.wakeMinute=next;if(expectedWake!=null)expectedWake=(expectedWake!+delta).clamp(0,1439);
      case 'early':a.earlyMinutes=(a.wakeMinute-m).clamp(0,720);
      case 'gradual':a.gradualMinutes=(expectedMinute-m).clamp(0,180);
      case 'sunrise':a.sunriseMinutes=(expectedMinute-m).clamp(5,60);
      case 'sound':a.soundDelayMinutes=(m-expectedMinute).clamp(0,30);
      case 'vibration':a.vibrationDelayMinutes=(m-expectedMinute).clamp(0,30);
      case 'window':a.workoutStartMinute=m.clamp(0,1439);
    }
  });}
  void _showNewTiming(String id){_freshTiming=id;_tabFlash.forward(from:0);}
  void select(String id,double at){setState(()=>focus=id);c.reveal(at);}
  Future<void> _save()async{a.referenceWakeMinute=expectedWake;setState(()=>saving=true);try{await widget.onSave(a);if(mounted)Navigator.pop(context,a);}catch(e){if(mounted)setState(()=>error=e.toString());}finally{if(mounted)setState(()=>saving=false);}}
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
  Widget timeRow(String id,String title,int value,{String? sub,Widget? trailing})=>GestureDetector(
    key:ValueKey('pilot-time:$id'),dragStartBehavior:DragStartBehavior.down,onHorizontalDragStart:(_){_rowStart=_minuteFor(id);_rowDrag=0;select(id,start+_rowStart*60.0);},
    onHorizontalDragUpdate:(d){_rowDrag+=d.delta.dx;final moved=(_rowDrag/10).round()*5;_handle(id,start+(_rowStart+moved)*60.0);},
    child:ColoredBox(color:_glowingTiming==id&&_rowGlow.isAnimating?P.of(context).on(C.blue).withValues(alpha:.3*math.sin(math.pi*_rowGlow.value)):Colors.transparent,child:ListTile(contentPadding:EdgeInsets.zero,minTileHeight:56,selected:focus==id,title:Text(title),subtitle:sub==null?null:Text(sub),trailing:trailing??Text(formatClock(((value%1440)+1440)%1440~/60,((value%60)+60)%60),style:F.head.copyWith(fontSize:19)),onTap:()=>select(id,start+value*60.0))));

  Widget feelRow({bool chaos=false})=>Row(children:[TextButton.icon(onPressed:playing?null:()=>_feel(chaos:chaos),icon:const Icon(LucideIcons.vibrate,size:16),label:Text(l.pilotFeelIt)),const Spacer(),TextButton(onPressed:()=>Navigator.of(context).push(MaterialPageRoute(builder:(_)=>const HapticsSettings())),child:Text(l.pilotHaptics))]);
  Widget choices<T>(List<T> values,T selected,ValueChanged<T> change,String Function(T) label)=>Wrap(spacing:6,children:[for(final v in values)ChoiceChip(label:Text(label(v)),selected:v==selected,onSelected:methods?(_)=>setState(()=>change(v)):null,materialTapTargetSize:MaterialTapTargetSize.padded)]);
  @override Widget build(BuildContext context){
    final p=P.of(context),wake=start+a.wakeMinute*60.0,early=wake-a.earlyMinutes*60,gradual=start+((expectedWake??a.wakeMinute)-a.gradualMinutes)*60.0;
    final graph=measured??widget.graph;
    final tabs=a.type==PilotAlarmType.sleep?[l.pilotTimes,l.pilotWaking,l.pilotTonight]:[l.pilotWindow,l.pilotHeartRate];
    final handles=[PilotHandle(focus,start+_minuteFor(focus)*60.0,p.on(C.blue))];
    return PilotTheme(child:Builder(builder:(context)=>Scaffold(backgroundColor:p.bg,body:SafeArea(child:Column(children:[
      SizedBox(height:56,child:Row(children:[TextButton(onPressed:saving?null:()=>Navigator.pop(context),child:Text(l.pilotCancel)),Expanded(child:Text(l.pilotEditAlarm(a.label),maxLines:1,overflow:TextOverflow.ellipsis,textAlign:TextAlign.center,style:F.head.copyWith(color:p.ink))),TextButton(onPressed:saving?null:_save,child:Text(l.pilotSave))])),
      Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:PilotTimelineChart(controller:c,graph:graph,interaction:interaction,stages:stages,handles:handles,onHandle:_handle,onSelect:(id)=>select(id,start+_minuteFor(id)*60.0),
        annotations:[ChartAnnotation(id:'wake',kind:AnnotationKind.wake,at:wake,label:a.type==PilotAlarmType.sleep?l.pilotWake:l.pilotWindowEnd),if(a.type==PilotAlarmType.workout)ChartAnnotation(id:'window',kind:AnnotationKind.workout,at:start+a.workoutStartMinute*60.0,until:wake,label:l.pilotWindow),if(a.earlyMinutes>0)ChartAnnotation(id:'early',kind:AnnotationKind.mainSleep,at:early,until:wake,label:l.pilotEarlyWake),if(a.gradual)ChartAnnotation(id:'gradual',kind:AnnotationKind.wake,at:gradual,until:start+(expectedWake??a.wakeMinute)*60.0,label:l.pilotGradual),
          if(methods&&a.sunrise)ChartAnnotation(id:'sunrise',kind:AnnotationKind.wake,at:start+(expectedMinute-a.sunriseMinutes)*60.0,label:l.pilotSunrise),
          if(methods&&a.phoneSound)ChartAnnotation(id:'sound',kind:AnnotationKind.wake,at:start+(expectedMinute+a.soundDelayMinutes)*60.0,label:l.pilotPhoneSound),
          if(methods&&a.phoneVibration)ChartAnnotation(id:'vibration',kind:AnnotationKind.wake,at:start+(expectedMinute+a.vibrationDelayMinutes)*60.0,label:l.pilotPhoneVibration),
          ChartAnnotation(id:'backup',kind:AnnotationKind.wake,at:wake+(methods&&!a.band?60:0),label:a.band?l.pilotBandAlarm:l.pilotBandBackup)])),
      Row(children:[for(var i=0;i<tabs.length;i++)Expanded(child:TextButton(onPressed:()=>_openTab(i),style:TextButton.styleFrom(backgroundColor:i==0&&_tabFlash.isAnimating?p.on(C.blue).withValues(alpha:.6*math.pow(math.sin(2*math.pi*_tabFlash.value),2)):tab==i?p.card2:null,minimumSize:const Size(48,48)),child:Text(tabs[i])))]),
      Expanded(child:ListView(padding:const EdgeInsets.fromLTRB(16,8,16,32),children:[
        if(error!=null)Text(error!,style:TextStyle(color:p.on(C.red))),
        if(tab==0)...[
          SizedBox(height:repeat?200:200,child:Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:p.card,borderRadius:BorderRadius.circular(12)),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
            if(!repeat)Row(children:[Expanded(child:TextButton(onPressed:_rename,child:Align(alignment:Alignment.centerLeft,child:Text(a.label,maxLines:1,overflow:TextOverflow.ellipsis)))),Text(formatClock(a.wakeMinute~/60,a.wakeMinute%60),style:F.head.copyWith(fontSize:24,color:p.ink))]),
            if(repeat)...[
              SingleChildScrollView(scrollDirection:Axis.horizontal,child:Row(children:[
                for(var d=1;d<=7;d++)SizedBox(width:48,height:48,child:Semantics(
                  selected:a.days.contains(d),child:TextButton(
                    style:TextButton.styleFrom(padding:EdgeInsets.zero,minimumSize:const Size(48,48),backgroundColor:a.days.contains(d)?p.card2:null),
                    onPressed:()=>setState((){a.days.contains(d)?a.days.remove(d):a.days.add(d);}),
                    child:Text([l.pilotMonday,l.pilotTuesday,l.pilotWednesday,l.pilotThursday,l.pilotFriday,l.pilotSaturday,l.pilotSunday][d-1].substring(0,1)),
                  ),
                )),
              ])),
              Row(children:[for(final preset in [({1,2,3,4,5},l.pilotWeekdays),({6,7},l.pilotWeekends),({1,2,3,4,5,6,7},l.pilotEveryDay)])Expanded(child:TextButton(onPressed:()=>setState(()=>a.days={...preset.$1}),child:Text(preset.$2,maxLines:1,overflow:TextOverflow.ellipsis)))]),
            ]else if(a.type==PilotAlarmType.sleep)Row(children:[Expanded(child:Text('${l.pilotExpected}\n${expectedWake==null?'—':formatClock(expectedWake!~/60,expectedWake!%60)}')),Expanded(child:Text('${l.pilotUsualBedtime}\n${usualBed==null?'—':formatClock(usualBed!~/60,usualBed!%60)}'))])
            else Row(children:[Expanded(child:Text('${l.pilotWindowStart}\n${formatClock(a.workoutStartMinute~/60,a.workoutStartMinute%60)}')),Expanded(child:Text('${l.pilotWindowEnd}\n${formatClock(a.wakeMinute~/60,a.wakeMinute%60)}'))]),
            const Spacer(),
            PilotZoomControls(controller:c,onZoom:interaction.zoom,trailing:TextButton(onPressed:()=>setState(()=>repeat=!repeat),child:Text(repeat?l.pilotDone:_daysLabel(a,l),maxLines:1,overflow:TextOverflow.ellipsis))),
          ]))),
          timeRow('wake',a.type==PilotAlarmType.sleep?l.pilotWake:l.pilotWindowEnd,a.wakeMinute),
          if(a.type==PilotAlarmType.sleep)...[
            timeRow('early',l.pilotEarlyWake,a.wakeMinute-a.earlyMinutes,sub:a.earlyMinutes==0?null:l.pilotUpToEarlier(a.earlyMinutes),trailing:a.earlyMinutes==0?Text('—',style:F.head):TextButton(onPressed:()=>setState(()=>a.earlyMinutes=0),child:Text(l.pilotReset))),
            if(methods&&a.gradual)timeRow('gradual',l.pilotGradual,expectedMinute-a.gradualMinutes,sub:l.pilotBeforeFire(a.gradualMinutes)),
            if(methods&&a.sunrise)timeRow('sunrise',l.pilotSunrise,expectedMinute-a.sunriseMinutes,sub:l.pilotBeforeFire(a.sunriseMinutes)),
            if(methods&&a.phoneSound)timeRow('sound',l.pilotPhoneSound,expectedMinute+a.soundDelayMinutes,sub:l.pilotAfterFire(a.soundDelayMinutes)),
            if(methods&&a.phoneVibration)timeRow('vibration',l.pilotPhoneVibration,expectedMinute+a.vibrationDelayMinutes,sub:l.pilotAfterFire(a.vibrationDelayMinutes)),
            ListTile(key:const ValueKey('pilot-band-backup'),contentPadding:EdgeInsets.zero,minTileHeight:56,leading:const Icon(LucideIcons.shieldCheck),title:Text(a.band?l.pilotBandAlarm:l.pilotBandBackup),subtitle:Text(methods&&!a.band?l.pilotBackupAfterLatest:l.pilotBackupAtLatest),trailing:Text(formatClock((a.wakeMinute+(methods&&!a.band?1:0))%1440~/60,(a.wakeMinute+(methods&&!a.band?1:0))%60))),
            Text(l.pilotTimingPreview,style:F.cap.copyWith(color:p.ink2)),
          ]else timeRow('window',l.pilotWindowStart,a.workoutStartMinute),
          SwitchListTile(contentPadding:EdgeInsets.zero,title:Text(l.pilotPrimary),subtitle:Text(a.canBePrimary?l.pilotPrimaryDescription:l.pilotWorkoutNoPrimary),secondary:Icon(LucideIcons.star,color:a.primary?p.on(C.yellow):p.ink3),value:a.primary,onChanged:a.canBePrimary?(v)=>setState(()=>a.primary=v):null),
        ],
        if(tab==1&&a.type==PilotAlarmType.sleep)...[
          if(!methods)Text(l.pilotEnableWakeMethods),
          toggle(l.pilotSnooze,a.snooze,(v)=>setState(()=>a.snooze=v)),
          if(a.snooze)...[
            _IntChoice(label:l.pilotSnoozeLength,value:a.snoozeMinutes,values:const [3,5,9,10,15],onChanged:methods?(v)=>setState(()=>a.snoozeMinutes=v):null),
            _IntChoice(label:l.pilotMaxSnoozes,value:a.maxSnoozes,values:const [0,1,2,3,5,10],onChanged:methods?(v)=>setState(()=>a.maxSnoozes=v):null),
            choices(SnoozeChaos.values,a.chaos,(v)=>a.chaos=v,(v)=>switch(v){SnoozeChaos.steady=>l.pilotSteady,SnoozeChaos.little=>l.pilotLittleChaos,SnoozeChaos.lot=>l.pilotLotChaos,SnoozeChaos.wild=>l.pilotWildChaos}),feelRow(chaos:true),
          ],
          toggle(l.pilotSunrise,a.sunrise,(v){setState(()=>a.sunrise=v);if(v)_showNewTiming('sunrise');},sub:l.pilotPhoneLimit),
          toggle(l.pilotGradual,a.gradual,(v)=>setState(()=>a.gradual=v)),
          if(a.gradual)...[SizedBox(height:56,child:playing?Center(child:LinearProgressIndicator(value:progress)):choices(GradualPattern.values,a.pattern,(v)=>a.pattern=v,(v)=>switch(v){GradualPattern.ramp=>l.pilotRamp,GradualPattern.steady=>l.pilotSteady,GradualPattern.wave=>l.pilotWave})),feelRow()],
          toggle(l.pilotBandBuzz,a.band,(v)=>setState(()=>a.band=v),sub:a.band?null:l.pilotBackupLimit),
          if(a.band)...[choices(['default','custom'],a.customPatternId==null?'default':'custom',(v){if(v=='default'){a.customPatternId=null;}else{_pickPattern();}},(v)=>v=='default'?l.pilotBandDefault:l.pilotMyPattern),Text(l.pilotCustomTradeoff,style:F.cap.copyWith(color:p.ink2)),feelRow()],
          toggle(l.pilotPhoneVibration,a.phoneVibration,(v){setState(()=>a.phoneVibration=v);if(v)_showNewTiming('vibration');},sub:l.pilotPhoneLimit),
          toggle(l.pilotPhoneSound,a.phoneSound,(v){setState(()=>a.phoneSound=v);if(v)_showNewTiming('sound');}),
          Padding(padding:const EdgeInsets.symmetric(vertical:12),child:Text(l.pilotAwakeExplanation)),
        ],
        if(tab==1&&a.type==PilotAlarmType.workout)...[
          Text(l.pilotWorkoutFailSafe),_IntChoice(label:l.pilotHeartRateZone,value:a.zone,values:const [1,2,3,4,5],onChanged:methods?(v)=>setState(()=>a.zone=v):null),
          _IntChoice(label:l.pilotZoneMinutes,value:a.zoneMinutes,values:const [1,3,5,10,15],onChanged:methods?(v)=>setState(()=>a.zoneMinutes=v):null),
        ],
        if(tab==2)...[
          Text(l.pilotWakeWindowExplanation),const SizedBox(height:16),
          for(final event in [(usualBed,l.pilotUsualBedtime),(a.gradual?(expectedWake??a.wakeMinute)-a.gradualMinutes:null,l.pilotGradual),(a.earlyMinutes>0?a.wakeMinute-a.earlyMinutes:null,l.pilotEarlyWake),(expectedWake,l.pilotExpected),(a.wakeMinute,l.pilotWake)])
            if(event.$1!=null)ListTile(contentPadding:EdgeInsets.zero,leading:const Icon(LucideIcons.clock,size:18),title:Text(event.$2),trailing:Text(formatClock(((event.$1!%1440)+1440)%1440~/60,((event.$1!%60)+60)%60))),
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
