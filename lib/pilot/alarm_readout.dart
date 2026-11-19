// Owner: this widget displays one editor draft; it never writes a forecast metric.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../l10n/app_localizations.dart';
import '../ui2/charts.dart' show SleepStage,SleepStageX;
import '../ui2/day_timeline/day_graph.dart';
import '../ui2/day_timeline/timeline_controller.dart';
import '../ui2/theme.dart';
import 'alarm_pilot.dart';
import 'pilot_flags.dart';
import 'pilot_readout.dart';

class PilotAlarmReadout extends StatelessWidget {
  const PilotAlarmReadout({super.key,required this.controller,required this.graph,required this.stages,
    required this.alarm,required this.dayStart,required this.expectedMinute,required this.selectedMinute,
    required this.title,this.bedtimeMinute,this.rest});
  /// At-rest cells (mock-up v22 statsOf): shown while nothing is scrubbed, in
  /// the same cell slots as the scrub values so nothing shifts (m214).
  final List<(String,String)>? rest;
  final TimelineController controller;final DayGraph graph;final List<SleepStage?> stages;
  final PilotAlarm alarm;final int dayStart,expectedMinute,selectedMinute;final int? bedtimeMinute;final Widget title;
  @override Widget build(BuildContext context){
    final p=P.of(context),l=AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
    return ListenableBuilder(listenable:controller.scrubChanges,builder:(context,_){
      final at=controller.scrub??dayStart+selectedMinute*60.0,minute=(at-dayStart)/60;
      final stageIndex=((at-(graph.dayStart??dayStart))/300).floor();
      final stage=stageIndex>=0&&stageIndex<stages.length?stages[stageIndex]:null;
      final elapsed=bedtimeMinute==null||minute<bedtimeMinute!?null:(minute-bedtimeMinute!).floor();
      final estimate=elapsed==null?'—':pilotForecastText(l,elapsed);
      final events=<({IconData icon,String label})>[];
      final methods=PilotFlag.wakeMethods.enabled,expected=PilotFlag.wakeMethods.enabled?expectedMinute:alarm.wakeMinute;
      bool during(int from,[int length=1])=>minute>=from&&minute<from+length;
      if(methods&&alarm.sunrise&&during(expected-alarm.sunriseMinutes,alarm.sunriseMinutes))events.add((icon:LucideIcons.sun,label:l.pilotSunrise));
      if(methods&&alarm.band&&alarm.gradual&&during(expected-alarm.gradualMinutes,alarm.gradualMinutes))events.add((icon:LucideIcons.vibrate,label:l.pilotGradual));
      if(during(expected))events.add((icon:LucideIcons.alarmClock,label:l.pilotAlarmEvent));
      if(methods&&alarm.phoneSound&&during(expected+alarm.soundDelayMinutes))events.add((icon:LucideIcons.volume2,label:l.pilotPhoneSound));
      if(methods&&alarm.phoneVibration&&during(expected+alarm.vibrationDelayMinutes))events.add((icon:LucideIcons.smartphone,label:l.pilotPhoneVibration));
      if(methods&&alarm.phoneFlash&&during(expected+alarm.flashDelayMinutes))events.add((icon:LucideIcons.flashlight,label:l.pilotPhoneFlash));
      if(during(alarm.wakeMinute+(methods&&!alarm.band?1:0)))events.add((icon:alarm.band?LucideIcons.watch:LucideIcons.shieldCheck,label:alarm.band?l.pilotBandAlarm:l.pilotBandBackup));
      Widget value(String text)=>Text(text,maxLines:1,overflow:TextOverflow.ellipsis,style:F.head.copyWith(color:p.ink,fontSize:15));
      Widget cell(String label,Widget content)=>Expanded(child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(label,maxLines:1,overflow:TextOverflow.ellipsis,style:F.cap.copyWith(color:p.ink3)),
        SizedBox(height:24,child:Align(alignment:Alignment.centerLeft,child:content)),
      ]));
      final happening=events.isEmpty?value('—'):Semantics(label:events.map((e)=>e.label).join(', '),excludeSemantics:true,
        child:FittedBox(fit:BoxFit.scaleDown,alignment:Alignment.centerLeft,child:Row(mainAxisSize:MainAxisSize.min,children:[for(final event in events)Padding(padding:const EdgeInsets.only(right:3),child:Icon(event.icon,size:17,color:p.ink))])));
      return PilotReadout(controller:controller,graph:graph,stages:stages,titleWidget:title,fallbackTime:dayStart+selectedMinute*60.0,
        values:controller.scrub==null&&rest!=null?Row(children:[for(final r in rest!)cell(r.$1,value(r.$2))])
          :Row(children:[cell(l.pilotStage,value(stage?.label(l)??'—')),cell(l.pilotAsleepFor,value(estimate)),cell(l.pilotHappening,happening)]));
    });
  }
}

/// The signed forecast duration copy ("~50 min", "~7 h", "~6 h 10 min").
String pilotForecastText(AppLocalizations l,int minutes)=>minutes<60?l.pilotForecastMinutes(minutes):minutes%60==0?l.pilotForecastHours(minutes~/60):l.pilotForecastHoursMinutes(minutes~/60,minutes%60);
