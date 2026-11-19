import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../ui2/day_timeline/day_graph.dart';
import '../ui2/day_timeline/timeline_controller.dart';
import '../ui2/charts.dart' show SleepStage,SleepStageX;
import '../ui2/theme.dart';
import 'timeline_chart.dart' show pilotClock;

class PilotReadout extends StatelessWidget {
  const PilotReadout({super.key,required this.controller,required this.graph,this.title='',this.stages=const [],this.fallback,this.controls});
  final TimelineController controller;final DayGraph graph;final String title;
  final List<SleepStage?> stages;final Widget? fallback,controls;
  @override Widget build(BuildContext context){
    final p=P.of(context),l=AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
    return ListenableBuilder(listenable:controller.scrubChanges,builder:(context,_){
      final time=controller.scrub,index=time==null?-1:((time-(graph.dayStart??0))/60).floor();
      final hr=index>=0&&index<graph.hr.length?graph.hr[index]:null;
      final motion=index>=0&&index<graph.movement.length?graph.movement[index]:null;
      final stageIndex=index<0?-1:index~/5;
      final stage=stageIndex>=0&&stageIndex<stages.length?stages[stageIndex]:null;
      Widget cell(String label,String value)=>Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(label,maxLines:1,overflow:TextOverflow.ellipsis,style:F.cap.copyWith(color:p.ink3)),Text(value,maxLines:1,overflow:TextOverflow.ellipsis,style:F.head.copyWith(color:p.ink,fontSize:15))]));
      return Container(padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:p.card,borderRadius:BorderRadius.circular(12)),
        child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Row(children:[Expanded(child:Text(title,maxLines:1,overflow:TextOverflow.ellipsis,style:F.head.copyWith(color:p.ink))),Text(time==null?'—':pilotClock(time),style:F.head.copyWith(color:p.ink,fontSize:22))]),
          const SizedBox(height:8),
          if(time==null&&fallback!=null)fallback! else Row(children:[
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
    builder:(context,value,_)=>ClipRect(child:Align(alignment:Alignment.topCenter,heightFactor:value,
      child:FractionalTranslation(translation:Offset(0,value-1),child:child))));
}
