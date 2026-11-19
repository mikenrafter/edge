import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../ui2/day_timeline/day_graph.dart';
import '../ui2/day_timeline/timeline_controller.dart';
import '../ui2/charts.dart' show SleepStage,SleepStageX;
import '../ui2/theme.dart';
import 'timeline_chart.dart' show pilotClock;

class PilotReadout extends StatelessWidget {
  const PilotReadout({super.key,required this.controller,required this.graph,this.title='',this.stages=const [],this.fallback,this.controls,this.titleWidget,this.fallbackTime,this.values,this.compact=false});
  /// Day timeline readout (mock-up v16 .ro): a blue caption, heart rate and
  /// movement only, the zoom/pin controls inside the card.
  final bool compact;
  final TimelineController controller;final DayGraph graph;final String title;
  final Widget? titleWidget;final double? fallbackTime;
  final List<SleepStage?> stages;final Widget? fallback,controls,values;
  @override Widget build(BuildContext context){
    final p=P.of(context),l=AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
    return ListenableBuilder(listenable:controller.scrubChanges,builder:(context,_){
      final time=controller.scrub,index=time==null?-1:((time-(graph.dayStart??0))/60).floor();
      final hr=index>=0&&index<graph.hr.length?graph.hr[index]:null;
      final motion=index>=0&&index<graph.movement.length?graph.movement[index]:null;
      final stageIndex=index<0?-1:index~/5;
      final stage=stageIndex>=0&&stageIndex<stages.length?stages[stageIndex]:null;
      Widget cell(String label,String value)=>Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,maxLines:1,overflow:TextOverflow.ellipsis,style:F.cap.copyWith(color:p.ink3)),Text(value,maxLines:1,overflow:TextOverflow.ellipsis,style:F.head.copyWith(color:p.ink,fontSize:15))]));
      if(compact)return Container(padding:const EdgeInsets.fromLTRB(12,10,12,0),decoration:BoxDecoration(color:p.card,borderRadius:BorderRadius.circular(12)),
        child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Text((time==null?l.pilotTapGraphOrRow:'${l.pilotSelected} · ${pilotClock(time)}').toUpperCase(),key:const ValueKey('pilot-readout-caption'),maxLines:1,overflow:TextOverflow.ellipsis,style:F.cap.copyWith(color:p.on(C.blue),fontSize:11,fontWeight:FontWeight.w700,letterSpacing:.2)),
          const SizedBox(height:4),
          Row(children:[cell(l.dayTimelineHeartRateTitle,hr==null?'—':'${hr.round()} bpm'),cell(l.homeMovement,motion==null?'—':'${(motion*100).round()}%')]),
          if(controls!=null)controls!,
        ]));
      return Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:p.card,borderRadius:BorderRadius.circular(12)),
        child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Row(children:[Expanded(child:titleWidget??Text(title,maxLines:1,overflow:TextOverflow.ellipsis,style:F.head.copyWith(color:p.ink))),Text(time==null?(fallbackTime==null?'—':pilotClock(fallbackTime!)):pilotClock(time),key:const ValueKey('pilot-readout-time'),style:F.head.copyWith(color:p.ink,fontSize:22))]),
          const SizedBox(height:8),
          if(values!=null)values! else if(time==null&&fallback!=null)fallback! else Row(children:[
            cell(l.pilotStage,stage?.label(l)??'—'),cell(l.dayTimelineHeartRateTitle,hr==null?'—':'${hr.round()} bpm'),cell(l.homeMovement,motion==null?'—':'${(motion*100).round()}%'),
          ]),
          if(controls!=null)controls!,
        ]));
    });
  }
}

/// Auto-pin keeps the original's layout slot. The duplicate is clipped to its
/// animated height, so slide-out has neither an empty box nor a height jump.
class AutomaticReadout extends StatelessWidget {
  const AutomaticReadout({super.key,required this.visible,required this.child});
  final bool visible;final Widget child;
  @override Widget build(BuildContext context)=>TweenAnimationBuilder<double>(
    tween:Tween(end:visible?1:0),duration:const Duration(milliseconds:800),curve:Curves.easeOutCubic,
    builder:(context,value,_)=>value==0?const SizedBox.shrink():ClipRect(child:Align(alignment:Alignment.topCenter,heightFactor:value,
      child:FractionalTranslation(translation:Offset(0,value-1),child:child))));
}
