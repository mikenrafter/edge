// Owner: each PilotTimelineChart State owns pointer timers; its controller owns time.
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../l10n/app_localizations.dart';
import '../state/clock_format.dart' show formatClockOf;
import '../ui2/chart_annotations.dart';
import '../ui2/charts.dart' show SleepStage, Hypnogram;
import '../ui2/day_timeline/day_graph.dart';
import '../ui2/day_timeline/timeline_controller.dart';
import '../ui2/theme.dart';
import 'timeline_policy.dart';

String pilotClock(double sec) => formatClockOf(DateTime.fromMillisecondsSinceEpoch(sec.round()*1000));

/// A read-only overview removes the long middle of the recorded night.
class PilotTimelineCut {
  const PilotTimelineCut({required this.leftEnd,required this.rightStart});
  final double leftEnd,rightStart;
  double leftWidth(double width)=>(width-28)*.32;
  double x(double at,TimelineView view,double width){
    final left=leftWidth(width);
    if(at<=leftEnd)return (at-view.start)/(leftEnd-view.start)*left;
    if(at>=rightStart)return left+28+(at-rightStart)/(view.end-rightStart)*(width-left-28);
    return left+14;
  }
}

Color _pilotAnnotationColor(ChartAnnotation a)=>switch(a.id){
  'bed'=>C.indigo,'early'=>C.teal,'gradual'=>C.yellow,'sunrise'=>C.orange,
  'wake'||'expected'=>C.orange,'sound'||'vibration'||'flash'=>C.pink,'backup'=>C.blue,
  final id when id.startsWith('snooze:')=>C.n500,
  _=>annotationColor(a.kind),
};

class PilotHandle {
  const PilotHandle(this.id,this.at,this.color,{this.active=true});
  final String id;
  final double at;
  final Color color;final bool active;
}

class PilotTimelineChart extends StatefulWidget {
  const PilotTimelineChart({super.key,required this.controller,required this.graph,
    required this.interaction,this.annotations=const [],this.stages=const [],
    this.handles=const [],this.onHandle,this.onSelect,this.onScrub,this.onPan,
    this.onTapTime,this.height=112,this.dimHrInsideSleep=true,this.overview=false,this.cut,this.selectedAnnotationId,this.showHeartRate=true,this.showHeader=true});
  final TimelineController controller;
  final DayGraph graph;
  final TimelineInteraction interaction;
  final List<ChartAnnotation> annotations;
  final List<SleepStage?> stages;
  final List<PilotHandle> handles;
  final void Function(String,double)? onHandle;
  final ValueChanged<String>? onSelect;
  final ValueChanged<double>? onScrub,onPan,onTapTime;
  final double height;
  final bool dimHrInsideSleep;final bool overview;final PilotTimelineCut? cut;final String? selectedAnnotationId;
  /// Alarm charts show a forecast night: stages and annotations only, no
  /// recorded heart rate or motion (alarm mock-ups v12-v22, m149/m167).
  final bool showHeartRate;
  /// The label/bpm row above the plot; the alarm editor labels in the chart.
  final bool showHeader;
  @override State<PilotTimelineChart> createState()=>_PilotChartState();
}

class _PilotChartState extends State<PilotTimelineChart> with TickerProviderStateMixin {
  Timer? _hold,_fineTimer,_edge;
  Offset? _down,_position;
  TimelineView? _panStart;
  bool _scrub=false,_fine=false,_moved=false;
  String? _handle;
  double _width=1;
  final _annotationTargets=<({Offset center,String id})>[];
  double? _zoomStart;int _edgeDirection=0,_edgeTicks=0;
  TimelineController get c=>widget.controller;
  TimelineInteraction get interaction=>widget.interaction;
  double _time(double dx)=>c.view.at((dx/_width).clamp(0,1));
  @override void didChangeDependencies(){super.didChangeDependencies();c.attach(this,reducedMotion:!Motion.enabled(context));}
  @override void didUpdateWidget(PilotTimelineChart old){super.didUpdateWidget(old);if(old.controller!=c){old.controller.detach(this);c.attach(this,reducedMotion:!Motion.enabled(context));}}
  @override void dispose(){_hold?.cancel();_fineTimer?.cancel();_edge?.cancel();c.detach(this);super.dispose();}
  void _start(PointerDownEvent e){
    _down=_position=e.localPosition;_panStart=c.view;_moved=false;_fine=false;_scrub=false;_handle=null;
    if(c.selection!=null){_zoomStart=_time(e.localPosition.dx);return;}
    var nearest=25.0;for(final h in widget.handles){final distance=(c.view.fraction(h.at)*_width-e.localPosition.dx).abs();if(distance<nearest){_handle=h.id;nearest=distance;}}
    if(widget.selectedAnnotationId!=null){
      ({Offset center,String id})? hit;var distance=double.infinity;
      for(final target in _annotationTargets){final delta=e.localPosition-target.center;if(delta.dx.abs()<=24&&delta.dy.abs()<=24&&delta.distance<distance){hit=target;distance=delta.distance;}}
      if(hit!=null){_handle=hit.id;widget.onSelect?.call(hit.id);}
    }
    _hold=Timer(const Duration(milliseconds:300),(){
      if(!mounted||_down==null||_moved)return;
      if(_handle==null){_scrub=true;_setCursor(_time(_position!.dx));}
      HapticFeedback.selectionClick();setState((){});
    });
    _fineTimer=Timer(const Duration(milliseconds:600),(){
      if(!mounted||_down==null||_moved)return;
      _fine=true;HapticFeedback.mediumImpact();setState((){});
    });
    _edge=Timer.periodic(const Duration(milliseconds:16),(_){
      if(_down==null||(!_scrub&&_handle==null)||_position==null)return;
      final x=_position!.dx;
      final depth=x<40?-(40-x)/40:x>_width-40?(x-(_width-40))/40:0.0;
      if(depth.sign.toInt()!=_edgeDirection){_edgeDirection=depth.sign.toInt();_edgeTicks=0;}
      if(depth==0)return;
      final held=++_edgeTicks*16;if(held<300)return;
      _fine=false;_fineTimer?.cancel();
      c.panBy(depth.sign*depth.abs().clamp(0,1)*depth.abs().clamp(0,1)*c.view.span*.5*.016*((held-300)/400).clamp(0,1));
      _edit(_time(x));
    });
  }
  void _setCursor(double at){
    final step=_fine?60:300;
    final snapped=(at/step).round()*step.toDouble();
    if(c.scrub!=snapped)HapticFeedback.selectionClick();
    interaction.startScrub(snapped);c.setScrub(snapped);widget.onScrub?.call(snapped);
  }
  void _edit(double at){
    if(_handle!=null){
      final step=_fine?60:300;
      widget.onHandle?.call(_handle!,(at/step).round()*step.toDouble());
    } else if(_scrub){_setCursor(at);}
  }
  void _move(PointerMoveEvent e){
    if(_down==null)return;_position=e.localPosition;
    if(c.selection!=null&&_zoomStart!=null){c.updatePilotSelection(_zoomStart!,_time(e.localPosition.dx));return;}
    final delta=e.localPosition-_down!;
    if(delta.distance>6){_moved=true;_hold?.cancel();}
    if(_scrub||_handle!=null){_edit(_time(e.localPosition.dx));}
    else if(_moved){
      c.panTo(_panStart!.start-delta.dx/_width*_panStart!.span);
      widget.onPan?.call(c.view.center);
    }
  }
  void _end(PointerEvent e){
    _hold?.cancel();_fineTimer?.cancel();_edge?.cancel();
    if(e is! PointerCancelEvent){
      if(_zoomStart!=null){c.finishPilotSelection();interaction.zoom();}
      else if(!_moved&&_handle!=null){widget.onSelect?.call(_handle!);}
      else if(!_moved&&!_scrub&&_handle==null){
        final at=_time(e.localPosition.dx);widget.onTapTime?.call(at);
        ChartAnnotation? nearest;
        for(final a in widget.annotations){if(nearest==null||(a.at-at).abs()<(nearest.at-at).abs())nearest=a;}
        if(nearest!=null&&(nearest.at-at).abs()<c.view.span*.05){widget.onSelect?.call(nearest.id);}
        // m241: on a persistent-scrub chart (the day timeline) a tap that
        // focuses nothing places the cursor, as a hold would. It fires on the
        // trailing edge (no move past the slop, before the hold timer), so a
        // pan never scrubs. Temporary-scrub charts keep tap = nothing.
        else if(interaction.retention==PilotScrub.permanent){
          final snapped=(at/300).round()*300.0;
          c.setScrub(snapped);interaction.focus(snapped);widget.onScrub?.call(snapped);
        }
      }
    }
    interaction.lift();
    if(interaction.retention==PilotScrub.temporary)c.clearScrub();
    _down=null;_handle=null;_zoomStart=null;_scrub=false;_fine=false;
    if(mounted)setState((){});
  }
  @override Widget build(BuildContext context){
    final p=P.of(context),l=AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
    return RepaintBoundary(child:ListenableBuilder(
      listenable:Listenable.merge([c.range,c.scrubChanges,c.zoomChanges,interaction]),
      builder:(context,_)=>LayoutBuilder(builder:(context,box){
        _width=box.maxWidth;
        final visible=widget.annotations.where((a)=>a.at<=c.view.end&&(a.until??a.at)>=c.view.start).toList();
        final lanes=<double>[];final marks=<({ChartAnnotation annotation,double x,int lane})>[];
        // Mock-up v22: snoozes are dashed grey lines only, never icons.
        bool iconless(ChartAnnotation a)=>a.id.startsWith('snooze:');
        for(final a in visible.where((a)=>!iconless(a))){
          final x=(widget.cut?.x(a.at,c.view,_width)??c.view.fraction(a.at)*_width).clamp(12.0,math.max(12.0,_width-12)).toDouble();
          var lane=0;while(lane<lanes.length&&(lanes[lane]-x).abs()<24)lane++;
          if(lane==lanes.length)lanes.add(x);else lanes[lane]=x;
          marks.add((annotation:a,x:x,lane:lane));
        }
        _annotationTargets.clear();
        for(final mark in marks){_annotationTargets.add((center:Offset(mark.x,mark.lane*22.0+9),id:mark.annotation.id));}
        ChartAnnotation? nearest;
        for(final a in visible){if(nearest==null||(a.at-(c.scrub??c.view.center)).abs()<(nearest.at-(c.scrub??c.view.center)).abs())nearest=a;}
        if(widget.selectedAnnotationId!=null&&c.scrub==null){nearest=widget.annotations.where((a)=>a.id==widget.selectedAnnotationId).firstOrNull??nearest;}
        final annotationStep=math.max(18.0,MediaQuery.textScalerOf(context).scale(13.0)+2);
        final overviewGroups=<({double at,List<ChartAnnotation> items,double left,int lane})>[];
        if(widget.overview){
          final groups=<double,List<ChartAnnotation>>{};
          for(final a in visible.where((a)=>!iconless(a))){(groups[(a.at/60).round()*60.0]??=[]).add(a);}
          final ends=<double>[];
          for(final at in groups.keys.toList()..sort()){
            final items=groups[at]!,sx=widget.cut?.x(at,c.view,_width)??c.view.fraction(at)*_width;
            final labelSize=TextPainter(text:TextSpan(text:pilotClock(at),style:F.cap.copyWith(fontSize:11)),textDirection:TextDirection.ltr,textScaler:MediaQuery.textScalerOf(context))..layout();
            final width=22+labelSize.width;labelSize.dispose();
            final left=(sx-8).clamp(0.0,math.max(0.0,_width-width)).toDouble();
            var lane=0;
            bool free(int row){for(var j=row;j<row+items.length;j++){if(j<ends.length&&left<ends[j]+3)return false;}return true;}
            while(!free(lane)){lane++;}
            for(var j=lane;j<lane+items.length;j++){while(ends.length<=j){ends.add(-100);}ends[j]=left+width;}
            overviewGroups.add((at:at,items:items,left:left,lane:lane));
          }
        }
        final selectedLane=marks.where((m)=>m.annotation.id==widget.selectedAnnotationId).firstOrNull?.lane??0;
        Widget chip(IconData icon,Color color,{bool on=false,bool small=false})=>Container(width:small?16:22,height:small?15:20,alignment:Alignment.center,
          decoration:BoxDecoration(color:on?p.ink:p.bg,borderRadius:BorderRadius.circular(small?5:6),border:Border.all(color:on?p.ink:p.line)),
          child:Icon(icon,size:small?10:13,color:on?p.bg:color));
        final plotHeight=widget.overview?math.max(widget.height,overviewGroups.fold<double>(0,(h,g)=>math.max(h,(g.lane+g.items.length)*annotationStep+8))):widget.height;
        return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          if(!widget.overview&&widget.showHeader)SizedBox(height:26,child:Row(children:[Expanded(child:Text(nearest?.label??'',maxLines:1,overflow:TextOverflow.ellipsis,style:F.cap.copyWith(color:p.ink2))),Text('bpm',style:F.cap.copyWith(color:p.on(C.red)))])),
          Listener(onPointerDown:_start,onPointerMove:_move,onPointerUp:_end,onPointerCancel:_end,
            child:GestureDetector(onPanUpdate:(_){},behavior:HitTestBehavior.opaque,
              child:SizedBox(key:const ValueKey('pilot-timeline-plot'),height:plotHeight+24,
                child:ClipRect(child:Stack(children:[
                  Positioned.fill(child:CustomPaint(painter:_PilotPainter(p:p,view:c.view,graph:widget.graph,stages:widget.stages,
                    annotations:visible,scrub:c.scrub,selection:c.selection,height:plotHeight,dimHrInsideSleep:widget.dimHrInsideSleep,cut:widget.cut,showHeartRate:widget.showHeartRate,bpmInPlot:!widget.showHeader))),
                  if(c.selection==null)for(final h in widget.handles)if(h.at>=c.view.start&&h.at<=c.view.end)
                    Positioned(left:c.view.fraction(h.at)*_width-24,top:22,width:48,height:math.max(48,widget.height-24),
                      child:IgnorePointer(child:Center(child:Container(width:h.active?6:2,height:widget.height-28,decoration:BoxDecoration(color:h.color.withValues(alpha:h.active?1:.35),borderRadius:BorderRadius.circular(3))))),),
                  if(!widget.overview)for(final mark in marks)Positioned(left:mark.x-11,top:2+mark.lane*22.0,child:Tooltip(message:mark.annotation.label,
                    child:chip(mark.annotation.icon??annotationIcon(mark.annotation.kind),p.on(_pilotAnnotationColor(mark.annotation)),on:c.scrub==null&&mark.annotation.id==widget.selectedAnnotationId))),
                  for(final group in overviewGroups)Positioned(left:group.left,top:group.lane*annotationStep,child:DecoratedBox(decoration:BoxDecoration(color:p.card.withValues(alpha:.9),borderRadius:BorderRadius.circular(4)),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
                    Column(children:[for(final a in group.items)Padding(padding:const EdgeInsets.only(bottom:1),child:Tooltip(message:a.label,child:chip(a.icon??annotationIcon(a.kind),p.on(_pilotAnnotationColor(a)),small:true)))]),
                    Text(pilotClock(group.at),key:ValueKey('pilot-overview-time:${group.at.round()}'),style:F.cap.copyWith(color:p.ink,fontSize:11)),
                  ]))),
                  if(widget.selectedAnnotationId!=null&&!widget.overview)Builder(builder:(context){final at=(c.scrub??widget.handles.firstOrNull?.at??c.view.center),x=widget.cut?.x(at,c.view,_width)??c.view.fraction(at)*_width;var left=x+14;if(left>_width-52)left=x-58;
                    return Positioned(left:left.clamp(0.0,math.max(0.0,_width-52)),top:4+(c.scrub==null?selectedLane*22.0:0),child:DecoratedBox(decoration:BoxDecoration(color:p.card2,borderRadius:BorderRadius.circular(6)),child:Padding(padding:const EdgeInsets.symmetric(horizontal:6,vertical:1),child:Text(pilotClock(at),style:F.cap.copyWith(color:p.ink,fontSize:11,fontWeight:FontWeight.w600)))));}),
                  if(widget.cut!=null)Positioned(left:widget.cut!.leftWidth(_width)-3,top:plotHeight/2-10,width:34,child:Text('…',key:const ValueKey('pilot-overview-cut'),textAlign:TextAlign.center,style:F.head.copyWith(color:p.ink3))),
                  // Mock-ups: a translucent pill in the bottom-left corner, clear of
                  // the heart-rate graduations on the right.
                  if(!widget.overview)Positioned(left:8,bottom:30,child:IgnorePointer(child:Opacity(opacity:_scrub||_fine?1:.6,child:DecoratedBox(decoration:BoxDecoration(color:p.bg.withValues(alpha:.85),borderRadius:BorderRadius.circular(6)),
                    child:Padding(padding:const EdgeInsets.symmetric(horizontal:8,vertical:1),child:Text(_fine?l.pilotFineSteps:_scrub?l.pilotScrubbing:l.pilotHoldScrub,style:F.cap.copyWith(color:p.ink,fontSize:11))))))),
                ]))))),
        ]);
      })));
  }
}

class _PilotPainter extends CustomPainter {
  _PilotPainter({required this.p,required this.view,required this.graph,required this.stages,
    required this.annotations,required this.scrub,required this.selection,required this.height,required this.dimHrInsideSleep,this.cut,this.showHeartRate=true,this.bpmInPlot=false});
  final P p; final TimelineView view; final DayGraph graph; final List<SleepStage?> stages;
  final List<ChartAnnotation> annotations;final double? scrub;final TimelineView? selection;final double height;
  final bool dimHrInsideSleep;final PilotTimelineCut? cut;final bool showHeartRate,bpmInPlot;
  @override void paint(Canvas canvas,Size size){
    final w=size.width,base=(graph.dayStart??view.start).toDouble();
    double x(double at)=>cut?.x(at,view,w)??view.fraction(at)*w;
    void text(String s,double dx,double dy,Color color,{bool right=false}){
      final t=TextPainter(text:TextSpan(text:s,style:F.cap.copyWith(color:color,fontSize:10)),textDirection:TextDirection.ltr,maxLines:1)..layout();
      t.paint(canvas,Offset(right?dx-t.width:dx,dy));t.dispose();
    }
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0,0,w,height),const Radius.circular(10)),Paint()..color=p.card);
    for(final gap in graph.unmeasured){
      canvas.drawRect(Rect.fromLTRB(x(base+gap.$1*60),20,x(base+gap.$2*60),height),Paint()..color=p.card2);
    }
    final ticks=!showHeartRate?const <int>[]:visibleHeartRateTicks(graph.hr,start:((view.start-base)/60).floor(),end:((view.end-base)/60).ceil());
    final low=ticks.isEmpty?0:ticks.first,high=ticks.isEmpty?1:ticks.last;
    double y(num v)=>25+(1-(v-low)/(high-low))*(height-35);
    for(final t in ticks){
      for(var a=0.0;a<w;a+=8){canvas.drawLine(Offset(a,y(t)),Offset(math.min(a+3,w),y(t)),Paint()..color=p.on(C.red).withValues(alpha:.18));}

    }
    canvas.save();canvas.clipRect(Rect.fromLTWH(0,20,w,height-20));
    for(final a in annotations){
      final color=p.on(_pilotAnnotationColor(a));
      if(a.until!=null)canvas.drawRect(Rect.fromLTRB(x(a.at),20,x(a.until!),height),Paint()..color=color.withValues(alpha:.09));
      for(final at in [a.at,if(a.until!=null)a.until!])for(var top=22.0;top<height;top+=7){canvas.drawLine(Offset(x(at),top),Offset(x(at),top+3),Paint()..color=color.withValues(alpha:.4));}
    }
    // Stages go through the app's own Hypnogram painter, one call per
    // unbroken run, so runs merge and lanes have no per-slot seams (m233).
    int segment(int i){final at=base+i*300.0;return cut==null?0:at<=cut!.leftEnd?0:at>=cut!.rightStart?2:1;}
    void run(int from,int to){
      final left=x(base+from*300),right=x(base+to*300),top=26.0,box=Size(right-left,height-top-6);
      if(right<=0||left>=w||box.width<1)return;
      canvas.save();canvas.translate(left,top);
      canvas.saveLayer(Offset.zero&box,Paint()..color=Color.fromRGBO(0,0,0,showHeartRate ? .5 : 1.0));
      Hypnogram([for(var i=from;i<to;i++)stages[i]!],p).paint(canvas,box);
      canvas.restore();canvas.restore();
    }
    var from=-1;
    for(var i=0;i<=stages.length;i++){
      final open=i<stages.length&&stages[i]!=null&&segment(i)!=1;
      if(from>=0&&(!open||segment(i)!=segment(from))){run(from,i);from=-1;}
      if(open&&from<0)from=i;
    }
    Offset? previous;
    if(showHeartRate)for(var i=math.max(0,((view.start-base)/60).floor()-1);i<graph.hr.length&&base+i*60<=view.end+60;i++){
      final value=graph.hr[i];if(value==null||!value.isFinite||value<=0){previous=null;continue;}
      final point=Offset(x(base+i*60),y(value));
      final asleep=graph.rest.any((s)=>i>=s.$1&&i<s.$2);
      if(previous!=null)canvas.drawLine(previous,point,Paint()..color=p.on(C.red).withValues(alpha:dimHrInsideSleep ? (asleep ? .75 : 1.0) : .75)..strokeWidth=1.4);
      previous=point;
    }
    if(showHeartRate)for(var i=math.max(0,((view.start-base)/60).floor());i<graph.movement.length&&base+i*60<view.end;i++){
      final v=graph.movement[i];if(v==null||!v.isFinite)continue;
      canvas.drawRect(Rect.fromLTRB(x(base+i*60),height-v.clamp(0,1)*(height-25)*.32,x(base+(i+1)*60),height),Paint()..color=p.on(C.purple).withValues(alpha:.75));
    }
    if(selection!=null)canvas.drawRect(Rect.fromLTRB(x(selection!.start),0,x(selection!.end),height),Paint()..color=p.on(C.blue).withValues(alpha:.2));
    if(scrub!=null)canvas.drawLine(Offset(x(scrub!),0),Offset(x(scrub!),height),Paint()..color=p.ink..strokeWidth=1.5);
    canvas.restore();
    for(final t in ticks)text('$t',w-3,y(t)-11,p.on(C.red),right:true);
    if(bpmInPlot&&ticks.isNotEmpty)text('bpm',w-3,2,p.on(C.red),right:true);
    if(cut!=null){
      final left=cut!.leftWidth(w);
      canvas.drawRect(Rect.fromLTWH(left,0,28,height),Paint()..color=p.card);
      for(final segment in [(view.start,cut!.leftEnd),(cut!.rightStart,view.end)]){
        for(var at=(segment.$1/1800).ceil()*1800.0;at<segment.$2;at+=1800){final dx=x(at);if(dx>16&&dx<w-30)text(pilotClock(at),dx,height+5,p.ink3);}
      }
    }else{for(var i=0;i<=4;i++){text(pilotClock(view.at(i/4)),i==4?w:i*w/4,height+5,p.ink3,right:i==4);}}
  }
  @override bool shouldRepaint(_PilotPainter old)=>true;
}

class PilotZoomControls extends StatelessWidget {
  const PilotZoomControls({super.key,required this.controller,this.trailing,this.onZoom});
  final TimelineController controller;final Widget? trailing;final VoidCallback? onZoom;
  @override Widget build(BuildContext context){
    final l=AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
    final buttonStyle=TextButton.styleFrom(minimumSize:const Size(48,48),padding:const EdgeInsets.symmetric(horizontal:4));
    return ListenableBuilder(listenable:controller.zoomChanges,builder:(context,_)=>Row(children:[
      Expanded(child:TextButton.icon(style:buttonStyle,onPressed:(){controller.clearScrub();onZoom?.call();controller.beginPilotSelection();},icon:const Icon(LucideIcons.zoomIn,size:16),label:Text(l.timelineZoomIn,maxLines:1,overflow:TextOverflow.ellipsis))),
      Expanded(child:TextButton.icon(style:buttonStyle,onPressed:controller.zoomed||controller.selection!=null?(){controller.clearScrub();onZoom?.call();controller.resetZoom();}:null,icon:const Icon(LucideIcons.rotateCcw,size:16),label:Text(l.pilotZoomOut,maxLines:1,overflow:TextOverflow.ellipsis))),
      if(trailing!=null)Expanded(child:trailing!),
    ]));
  }
}
