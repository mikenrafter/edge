import 'pilot_theme.dart';
// Owner: the day screen supplies review state; this layout owns pin presentation.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../l10n/app_localizations.dart';
import '../ui2/chart_annotations.dart';
import '../ui2/day_timeline/day_graph.dart';
import '../ui2/day_timeline/timeline_controller.dart';
import '../ui2/theme.dart';
import '../ui2/charts.dart' show SleepStage;
import 'pilot_readout.dart';
import 'timeline_chart.dart';
import 'timeline_policy.dart';

class PilotDayLayout extends StatelessWidget {
  const PilotDayLayout({super.key,required this.title,required this.dayRow,required this.graph,
    required this.controller,required this.interaction,required this.tab,required this.onTab,
    required this.listController,required this.rows,required this.annotations,
    this.onScrub,this.onPan,this.onAnnotation,this.before=const [],this.after=const [],this.backToOpened,this.counts=const {},this.stages=const []});
  /// Recorded stages for the visible day, one per 5-min slot from the graph's
  /// start; drawn at half opacity inside sleep (signed-off day timeline).
  final List<SleepStage?> stages;
  final Map<PilotTimelineTab,int> counts;
  final String title;final Widget dayRow;final DayGraph graph;
  final TimelineController controller;final TimelineInteraction interaction;
  final PilotTimelineTab tab;final ValueChanged<PilotTimelineTab> onTab;
  final ScrollController listController;final List<Widget> rows,before,after;
  final List<ChartAnnotation> annotations;
  final ValueChanged<double>? onScrub,onPan;final ValueChanged<String>? onAnnotation;
  final Widget? backToOpened;
  @override Widget build(BuildContext context){
    final p=P.of(context),l=AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
    // Zoom and pin live inside the readout card (mock-up v16 .ro .ctl), so a
    // manual pin carries them into the pinned area with it.
    final readout=PilotReadout(controller:controller,graph:graph,compact:true,controls:PilotZoomControls(controller:controller,onZoom:(){interaction.zoom();controller.clearScrub();},trailing:TextButton.icon(
          key:const ValueKey('pilot-pin'),onPressed:interaction.togglePin,icon:Icon(interaction.userPinned?LucideIcons.pinOff:LucideIcons.pin,size:16),label:Text(interaction.userPinned?l.pilotUnpin:l.pilotPinShort,maxLines:1))));
    return PilotTheme(child:ListenableBuilder(listenable:interaction,builder:(context,_)=>Scaffold(backgroundColor:p.bg,body:SafeArea(child:Column(children:[
      SizedBox(height:52,child:Row(children:[IconButton(onPressed:()=>Navigator.maybePop(context),icon:const Icon(LucideIcons.chevronLeft)),Expanded(child:Text(title,textAlign:TextAlign.center,maxLines:1,overflow:TextOverflow.ellipsis,style:F.head.copyWith(color:p.ink))),const SizedBox(width:48)])),
      Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:Column(children:[
        dayRow,
        PilotTimelineChart(controller:controller,graph:graph,interaction:interaction,annotations:annotations,stages:stages,onScrub:onScrub,onPan:onPan,onSelect:onAnnotation),
        const SizedBox(height:6),
        // Mock-up v16 .etabs, with each tab's count as its badge (.cnt).
        PilotSegmented([for(final value in PilotTimelineTab.values)switch(value){PilotTimelineTab.pending=>l.dayActivitiesPending,PilotTimelineTab.saved=>l.dayActivitiesSaved,PilotTimelineTab.discarded=>l.dayActivitiesDiscarded}],
          PilotTimelineTab.values.indexOf(tab),(i)=>onTab(PilotTimelineTab.values[i]),
          itemKeys:[for(final value in PilotTimelineTab.values)ValueKey('pilot-tab:${value.name}')],
          badges:{for(var i=0;i<PilotTimelineTab.values.length;i++)i:_Count(counts[PilotTimelineTab.values[i]]??0)}),
        if(interaction.userPinned)Padding(padding:const EdgeInsets.only(top:6),child:readout)
        else AutomaticReadout(key:const ValueKey('pilot-automatic-pin'),visible:interaction.autoPinned,child:readout),
      ])),
      Expanded(child:NotificationListener<ScrollNotification>(onNotification:(n){
        // CLAIM(pilot-scrub-no-feedback): the entire scroll reaction is suspended
        // during hand scrubbing [timelines_test: scroll sync is suspended].
        if(interaction.handScrubbing)return false;
        if(n is ScrollStartNotification&&n.dragDetails!=null)interaction.scroll();
        return false;
      },child:SingleChildScrollView(controller:listController,key:const ValueKey('pilot-day-list'),padding:const EdgeInsets.fromLTRB(16,0,16,32),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        if(!interaction.userPinned)Visibility(visible:!interaction.autoPinned,maintainState:true,maintainAnimation:true,maintainSize:true,child:Padding(padding:const EdgeInsets.only(top:6,bottom:8),child:readout)),
        ...before,
        // One list card, as in the mock-up (.list) and the original day screen.
        if(rows.isNotEmpty)Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:4),decoration:BoxDecoration(color:p.card,borderRadius:BorderRadius.circular(16)),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:rows)),
        ...after,
      ])))),
      if(backToOpened!=null)backToOpened!,
    ])))));
  }
}

class PilotDayRow extends StatelessWidget {
  const PilotDayRow({super.key,required this.day,required this.dirty,required this.onPrevious,required this.onNext,required this.onCancel,required this.onSave,this.busy=false});
  final String day;final bool dirty,busy;final VoidCallback? onPrevious,onNext,onCancel,onSave;
  @override Widget build(BuildContext context){
    final l=AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
    // Mock-ups' .dayrow: a card2 strip, the date centred on the full width.
    return Container(height:48,margin:const EdgeInsets.only(bottom:8),decoration:BoxDecoration(color:P.of(context).card2,borderRadius:BorderRadius.circular(12)),child:Stack(alignment:Alignment.center,children:[
      Padding(padding:const EdgeInsets.symmetric(horizontal:80),child:Text(day,maxLines:1,overflow:TextOverflow.ellipsis,textAlign:TextAlign.center,style:F.body.copyWith(fontWeight:FontWeight.w600))),
      Align(alignment:Alignment.centerLeft,child:SizedBox(width:80,child:dirty?TextButton(onPressed:busy?null:onCancel,child:Text(l.pilotCancel,maxLines:1)):IconButton(onPressed:onPrevious,icon:const Icon(LucideIcons.chevronLeft)))),
      Align(alignment:Alignment.centerRight,child:SizedBox(width:80,child:dirty?TextButton(onPressed:busy?null:onSave,child:Text(l.pilotSave,maxLines:1)):IconButton(onPressed:onNext,icon:const Icon(LucideIcons.chevronRight)))),
    ]));
  }
}

class _Count extends StatelessWidget {
  const _Count(this.n);
  final int n;
  @override Widget build(BuildContext context){final p=P.of(context);
    return Container(constraints:const BoxConstraints(minWidth:18),height:18,padding:const EdgeInsets.symmetric(horizontal:4),alignment:Alignment.center,
      decoration:BoxDecoration(color:p.card2,borderRadius:BorderRadius.circular(9)),child:Text('$n',style:F.cap.copyWith(color:p.ink,fontSize:11)));}
}
